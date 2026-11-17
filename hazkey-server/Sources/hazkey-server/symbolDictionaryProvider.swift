import Foundation

/// 記号候補の繰り上げ件数の区分
///
/// 補助記号辞書の読みごとに決まり、辞書に無い読みはBティアとする
enum SymbolTier: Sendable, Equatable {
    /// 記号名を明示した読み (やじるし・かぎかっこなど)
    /// 最大6件を繰り上げる
    case a
    /// 普通の語とも曖昧な読み (した・まるなど)
    /// 最大3件を繰り上げ、普通の語を更に保護する
    case b

    /// 補助記号辞書のtier列の値からtierを作る
    ///
    /// - Parameter column: tier列の文字列 ("A" または "B")
    /// - Returns: 対応するtier、それ以外の値はnil
    init?(column: Substring) {
        switch column {
        case "A": self = .a
        case "B": self = .b
        default: return nil
        }
    }
}

/// 読みから記号の一覧を引く補助記号辞書
///
/// 補助記号辞書 (symbol_dictionary.tsv) を1度だけ読み込み、以後は読み取り専用で照会する
///
/// TSVの各行は「読み<TAB>記号<TAB>tier」の3列で、同じ読みの行順が記号の優先順になる
final class SymbolDictionaryProvider {
    /// 1つの読みに対応する補助記号辞書の内容
    struct Entry: Equatable {
        /// 繰り上げ件数の区分
        let tier: SymbolTier
        /// 記号 (優先順)
        let symbols: [String]
    }

    /// 補助記号辞書の読み込み上限 (1MiB。ちょうど1MiBのファイルは受け付ける)
    static let maxFileSize = 1024 * 1024

    /// 読みごとの内容
    private let entries: [String: Entry]

    /// 有効な読みの数
    var readingCount: Int { entries.count }

    /// 補助記号辞書を読み込んでプロバイダを生成する
    ///
    /// 列数が3でない行・読みが不正な行・tierが不正な行・記号でない行 (SymbolCandidateClassifier.isSymbol(_:)がfalse) は読み飛ばし、最初の1件だけをログに出す
    ///
    /// 同じ読みでtierが食い違う場合は、辞書全体を不正として拒否する
    ///
    /// - Parameter tsvURL: 補助記号辞書 (symbol_dictionary.tsv) のパス
    /// - Returns: 有効な行が1つ以上ある場合はプロバイダ、読み込みに失敗した場合・tierが食い違う場合・有効な行が無い場合はnil
    /// - Note: 読み込みはwithValidatedFileData(at:limit:followFinalSymlink:_:)で行い、通常ファイル以外 (ディレクトリ・FIFO) と上限を超えるファイルを拒否する
    init?(tsvURL: URL) {
        let data: Data
        do {
            data = try readValidatedFileData(at: tsvURL, limit: Self.maxFileSize + 1, followFinalSymlink: true)
        } catch {
            hazkeyLog("[hazkey] Failed to read symbol dictionary \(tsvURL.path): \(error)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            hazkeyLog("[hazkey] Symbol dictionary is not valid UTF-8: \(tsvURL.path)")
            return nil
        }
        guard let parsed = Self.parse(text, path: tsvURL.path), !parsed.isEmpty else {
            hazkeyLog("[hazkey] Symbol dictionary has no usable rows: \(tsvURL.path)")
            return nil
        }
        entries = parsed
    }

    /// 読みに対応する補助記号辞書の内容を返す
    ///
    /// - Parameter reading: カーソルまでの読み (ひらがな)
    /// - Returns: 辞書にある読みの場合は内容、無い場合はnil (呼び出し側はBティアとして扱う)
    func entry(forReading reading: String) -> Entry? {
        entries[reading]
    }

    /// 読みが補助記号辞書の読みとして有効かどうかを返す
    ///
    /// ひらがな (U+3041〜U+3096) と長音符 (U+30FC) だけからなる2文字以上の読みを有効とする
    ///
    /// - Parameter reading: 読み
    /// - Returns: 有効な読みの場合はtrue
    static func isValidReading<S: StringProtocol>(_ reading: S) -> Bool {
        reading.count >= 2
            && reading.unicodeScalars.allSatisfy { scalar in
                (0x3041...0x3096).contains(scalar.value) || scalar.value == 0x30FC
            }
    }

    /// TSVの内容を解析して、読みごとの内容を作る
    ///
    /// - Parameters:
    ///   - text: 補助記号辞書の内容
    ///   - path: ログに出すパス
    /// - Returns: 読みごとの内容、同じ読みでtierが食い違う場合はnil
    private static func parse(_ text: String, path: String) -> [String: Entry]? {
        var tiers: [String: SymbolTier] = [:]
        var symbols: [String: [String]] = [:]
        var reportedInvalidRow = false
        // CRLFはStringでは1文字 ("\r\n") になるため、改行文字の判定で行に分ける (CRLFの行末も受け付ける)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (offset, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, isValidReading(columns[0]),
                let tier = SymbolTier(column: columns[2]),
                SymbolCandidateClassifier.isSymbol(String(columns[1]))
            else {
                if !reportedInvalidRow {
                    reportedInvalidRow = true
                    hazkeyLog("[hazkey] Skipped invalid symbol dictionary row \(offset + 1) in \(path)")
                }
                continue
            }
            let reading = String(columns[0])
            if let known = tiers[reading], known != tier {
                hazkeyLog("[hazkey] Symbol dictionary has conflicting tiers for one reading at row \(offset + 1): \(path)")
                return nil
            }
            tiers[reading] = tier
            let symbol = String(columns[1])
            // 表記はUnicodeスカラ列の完全一致で比べる (Stringの==は正準等価で比べるため使わない)
            if !(symbols[reading]?.contains(where: { $0.unicodeScalars.elementsEqual(symbol.unicodeScalars) }) ?? false) {
                symbols[reading, default: []].append(symbol)
            }
        }
        return tiers.reduce(into: [:]) { result, item in
            result[item.key] = Entry(tier: item.value, symbols: symbols[item.key] ?? [])
        }
    }
}

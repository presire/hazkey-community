import Foundation

/// 7桁の郵便番号から住所 (都道府県・市区町村・町域) を引く候補プロバイダ
///
/// 郵便番号辞書 (postal_codes.tsv) を1度だけ読み込み、以後は読み取り専用で照会する
///
/// TSVの各行は「7桁の郵便番号<TAB>住所」の2列で、同じ郵便番号に複数の町域がある場合は複数行になる
///
/// - Note: メモリ使用量を抑えるため、住所は1本のUTF-8バイト列へ連結し、行ごとの郵便番号 (UInt32) と開始位置 (UInt32) だけを配列で持つ
final class PostalCodeProvider {
    /// 1つの郵便番号について候補へ出す住所の上限
    static let maxAddressCandidates = 10
    /// 郵便番号辞書の読み込み上限 (16MiB)
    static let readLimit = 16 * 1024 * 1024

    /// 行ごとの郵便番号 (昇順。同じ郵便番号の行はデータの出現順を保つ)
    private let keys: [UInt32]
    /// 行ごとの住所の開始位置 (末尾に終端位置を1つ加えるため、要素数は行数+1)
    private let offsets: [UInt32]
    /// 全行の住所を連結したUTF-8バイト列
    private let addressBytes: [UInt8]

    /// 有効な行の数
    var entryCount: Int { keys.count }

    /// 郵便番号辞書を読み込んでプロバイダを生成する
    ///
    /// 列数が2でない行・郵便番号が7桁のASCII数字でない行・住所が空の行は読み飛ばし、最初の1件だけをログに出す
    ///
    /// - Parameter tsvURL: 郵便番号辞書 (postal_codes.tsv) のパス
    /// - Returns: 有効な行が1つ以上ある場合はプロバイダ、読み込みに失敗した場合や有効な行が無い場合はnil
    /// - Note: 読み込みはwithValidatedFileData(at:limit:followFinalSymlink:_:)で行い、通常ファイル以外 (ディレクトリ・FIFO) と上限以上のファイルを拒否する
    ///
    ///   最終成分のシンボリックリンクは、通常ファイルを指す場合に限り辿る
    init?(tsvURL: URL) {
        let data: Data
        do {
            data = try readValidatedFileData(at: tsvURL, limit: Self.readLimit, followFinalSymlink: true)
        } catch {
            hazkeyLog("[hazkey] Failed to read postal code dictionary \(tsvURL.path): \(error)")
            return nil
        }
        guard let parsed = Self.parse(data) else {
            hazkeyLog("[hazkey] Postal code dictionary has no valid rows: \(tsvURL.path)")
            return nil
        }
        keys = parsed.keys
        offsets = parsed.offsets
        addressBytes = parsed.bytes
    }

    /// 入力の読みを郵便番号の照会キー (7桁のASCII数字) へ正規化する
    ///
    /// ASCII数字と全角数字を受け付け、区切りは3桁目の後ろに1つだけ許す
    ///
    /// 区切りとして受け付けるのは、ハイフン (U+002D)・長音記号 (U+30FC)・全角ハイフン (U+FF0D)・ハイフン (U+2010)・マイナス (U+2212)・半角長音記号 (U+FF70)
    ///
    /// - Parameter text: 組成中の読み (ひらがな化した文字列)
    /// - Returns: 正規化した7桁の照会キー、郵便番号の形でない場合はnil
    static func normalize(_ text: String) -> String? {
        var digits: [Character] = []
        var separatorCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39:
                digits.append(Character(scalar))
            case 0xFF10...0xFF19:
                // 全角数字をASCII数字へ戻す
                digits.append(Character(Unicode.Scalar(UInt8(scalar.value - 0xFF10 + 0x30))))
            case 0x2D, 0x30FC, 0xFF0D, 0x2010, 0x2212, 0xFF70:
                // 区切りは3桁目の直後の1つだけを許す
                guard digits.count == 3, separatorCount == 0 else { return nil }
                separatorCount += 1
            default:
                return nil
            }
        }
        guard digits.count == 7 else { return nil }
        return String(digits)
    }

    /// 郵便番号に対応する住所を返す
    ///
    /// - Parameter key: 7桁のASCII数字からなる照会キー (normalize(_:)の戻り値)
    /// - Returns: 住所の配列 (データの出現順)、該当が無い場合や照会キーが不正な場合は空配列
    func addresses(forKey key: String) -> [String] {
        guard let numericKey = Self.numericKey(key.utf8) else { return [] }
        // 同じ郵便番号の先頭行を二分探索で求める
        var low = 0
        var high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < numericKey { low = mid + 1 } else { high = mid }
        }
        var results: [String] = []
        var row = low
        while row < keys.count && keys[row] == numericKey {
            let start = Int(offsets[row])
            let end = Int(offsets[row + 1])
            results.append(String(decoding: addressBytes[start..<end], as: UTF8.self))
            row += 1
        }
        return results
    }

    /// 7個のASCII数字を数値へ変換する
    ///
    /// - Parameter bytes: 郵便番号のUTF-8バイト列
    /// - Returns: 7桁のASCII数字の場合は数値、それ以外はnil
    private static func numericKey<C: Collection<UInt8>>(_ bytes: C) -> UInt32? {
        guard bytes.count == 7 else { return nil }
        var value: UInt32 = 0
        for byte in bytes {
            guard (0x30...0x39).contains(byte) else { return nil }
            value = value * 10 + UInt32(byte - 0x30)
        }
        return value
    }

    /// TSVの内容を解析して、郵便番号の昇順に並べた行データを作る
    ///
    /// - Parameter data: 郵便番号辞書の内容
    /// - Returns: 郵便番号・住所の開始位置・連結した住所のバイト列、有効な行が無い場合はnil
    private static func parse(_ data: Data) -> (keys: [UInt32], offsets: [UInt32], bytes: [UInt8])? {
        let source = [UInt8](data)
        var keys: [UInt32] = []
        var offsets: [UInt32] = [0]
        var bytes: [UInt8] = []
        keys.reserveCapacity(source.count / 40)
        offsets.reserveCapacity(source.count / 40 + 1)
        bytes.reserveCapacity(source.count)
        var reportedMalformedRow = false
        var lineNumber = 0
        var lineStart = 0
        while lineStart < source.count {
            lineNumber += 1
            var lineEnd = lineStart
            while lineEnd < source.count && source[lineEnd] != 0x0A { lineEnd += 1 }
            let nextLineStart = lineEnd + 1
            // CRLFの行末も受け付ける
            if lineEnd > lineStart && source[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            defer { lineStart = nextLineStart }
            guard lineEnd > lineStart else { continue }
            let line = source[lineStart..<lineEnd]
            guard let tab = line.firstIndex(of: 0x09),
                !line[(tab + 1)...].contains(0x09),
                let key = numericKey(line[..<tab]),
                tab + 1 < lineEnd,
                String(validating: line[(tab + 1)...], as: UTF8.self) != nil
            else {
                if !reportedMalformedRow {
                    reportedMalformedRow = true
                    hazkeyLog("[hazkey] Skipping malformed postal code rows (first at line \(lineNumber))")
                }
                continue
            }
            keys.append(key)
            bytes.append(contentsOf: line[(tab + 1)...])
            offsets.append(UInt32(bytes.count))
        }
        guard !keys.isEmpty else { return nil }
        if zip(keys, keys.dropFirst()).allSatisfy({ $0 <= $1 }) {
            return (keys, offsets, bytes)
        }
        // 並んでいないデータは、同じ郵便番号の行の出現順を保ったまま並べ替える
        let order = keys.indices.sorted { (keys[$0], $0) < (keys[$1], $1) }
        var sortedKeys: [UInt32] = []
        var sortedOffsets: [UInt32] = [0]
        var sortedBytes: [UInt8] = []
        sortedKeys.reserveCapacity(keys.count)
        sortedOffsets.reserveCapacity(keys.count + 1)
        sortedBytes.reserveCapacity(bytes.count)
        for row in order {
            sortedKeys.append(keys[row])
            sortedBytes.append(contentsOf: bytes[Int(offsets[row])..<Int(offsets[row + 1])])
            sortedOffsets.append(UInt32(sortedBytes.count))
        }
        return (sortedKeys, sortedOffsets, sortedBytes)
    }
}

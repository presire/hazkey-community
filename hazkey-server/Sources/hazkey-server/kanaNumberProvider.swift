import Foundation

/// ASCII数字列を特殊な数字表記に変換するプロバイダ
///
/// 下付き数字や上付き数字等の候補生成を1か所に集約する
///
/// 状態を持たない列挙型であり全てのメンバは静的である
enum KanaNumberProvider {
    /// ゼロを意味するかな読みの集合
    ///
    /// 変換ロジックでは使用せず、テストのアサーション専用である
    static let zeroReadings: Set<String> = ["れい", "ぜろ", "ゼロ"]

    /// テキストがASCII数字列かどうかを判定する
    ///
    /// 空文字は対象外であり全文字がASCII数字のときのみ真になる
    ///
    /// - Parameter text: 判定するテキスト
    /// - Returns: 空でなく全文字がASCII数字のときに真を返す
    static func isAsciiDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 10進数字列から特殊表記の候補列を生成する
    ///
    /// 下付き数字と上付き数字と丸数字に加えて、ローマ数字の大文字と小文字や括弧付き数字やピリオド付き数字や装飾付き丸数字を集める
    ///
    /// 重複は取り除いて最初の出現順を保つ
    ///
    /// - Parameter digits: 10進数字からなる文字列
    /// - Returns: 変換できた表記の列を返す
    /// - Note: ASCII数字でない場合やIntに変換できない場合は、空配列を返す
    static func generateCandidates(forDecimalDigits digits: String) -> [String] {
        guard isAsciiDecimal(digits), let value = Int(digits) else {
            return []
        }

        var seen: Set<String> = []
        var results: [String] = []
        func add(_ text: String?) {
            guard let text, seen.insert(text).inserted else { return }
            results.append(text)
        }

        add(mapDigits(digits, using: subscriptDigits))
        add(mapDigits(digits, using: superscriptDigits))
        add(circledText(value: value))
        add(codepointText(value: value, range: 1...12, base: 0x2160))
        add(codepointText(value: value, range: 1...20, base: 0x2474))
        add(codepointText(value: value, range: 1...20, base: 0x2488))
        add(codepointText(value: value, range: 1...10, base: 0x2776))
        add(codepointText(value: value, range: 1...12, base: 0x2170))
        return results
    }

    /// 下付き数字への変換表
    ///
    /// ASCII数字から対応する下付き文字への写像である
    private static let subscriptDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
    ]
    /// 上付き数字への変換表
    ///
    /// ASCII数字から対応する上付き文字への写像である
    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]

    /// 数字列を変換表で置き換える
    ///
    /// 全ての桁を表引きで変換し1文字でも対応が無い場合は失敗とする
    ///
    /// - Parameters:
    ///   - digits: 変換元の数字列
    ///   - table: 数字から変換後文字への対応表
    /// - Returns: 変換後の文字列を返す
    /// - Note: 対応の無い数字がある場合はnilを返す
    private static func mapDigits(_ digits: String, using table: [Character: Character]) -> String? {
        var mapped = String()
        mapped.reserveCapacity(digits.count)
        for digit in digits {
            guard let replaced = table[digit] else { return nil }
            mapped.append(replaced)
        }
        return mapped
    }

    /// 範囲内の値に対応するUnicodeスカラー1文字を返す
    ///
    /// 基準符号位置に範囲先頭からの差分を加えて1文字を組み立てる
    ///
    /// - Parameters:
    ///   - value: 変換する整数値
    ///   - range: 有効な値の範囲
    ///   - base: 範囲先頭に対応するUnicode符号位置
    /// - Returns: 範囲内のときは1文字を返し範囲外の時は、nilを返す
    private static func codepointText(value: Int, range: ClosedRange<Int>, base: Int) -> String? {
        guard range.contains(value) else { return nil }
        guard let scalar = Unicode.Scalar(base + value - range.lowerBound) else { return nil }
        return String(Character(scalar))
    }

    /// 丸数字表記を返す
    ///
    /// 0は⓪を返し1から20までは丸数字域から組み立てる
    ///
    /// - Parameter value: 変換する整数値
    /// - Returns: 対応する丸数字を返し範囲外の時は、nilを返す
    private static func circledText(value: Int) -> String? {
        if value == 0 { return "⓪" }
        return codepointText(value: value, range: 1...20, base: 0x2460)
    }
}

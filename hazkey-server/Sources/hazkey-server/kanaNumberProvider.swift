import Foundation

enum KanaNumberProvider {
    static let zeroReadings: Set<String> = ["れい", "ぜろ", "ゼロ"]

    static func isAsciiDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

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

    private static let subscriptDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
    ]
    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]

    private static func mapDigits(_ digits: String, using table: [Character: Character]) -> String? {
        var mapped = String()
        mapped.reserveCapacity(digits.count)
        for digit in digits {
            guard let replaced = table[digit] else { return nil }
            mapped.append(replaced)
        }
        return mapped
    }

    private static func codepointText(value: Int, range: ClosedRange<Int>, base: Int) -> String? {
        guard range.contains(value) else { return nil }
        guard let scalar = Unicode.Scalar(base + value - range.lowerBound) else { return nil }
        return String(Character(scalar))
    }

    private static func circledText(value: Int) -> String? {
        if value == 0 { return "⓪" }
        return codepointText(value: value, range: 1...20, base: 0x2460)
    }
}

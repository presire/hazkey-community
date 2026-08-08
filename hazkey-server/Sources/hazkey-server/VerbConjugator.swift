import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// Tail-detection layer that maps a verb's hiragana reading tail to the correct
/// base CID, then expands the verb into all conjugated `DicdataElement` forms.
///
/// Known limitation: 一段 vs 五段-る ambiguity (e.g. 切る/走る/帰る end in -iru/-eru
/// but are actually 五段) is not resolvable from the reading alone without a
/// dictionary. Ambiguous cases default to 一段 (CID 619). The base form
/// (終止形) is always injected regardless, so users still get the dictionary form.
enum VerbConjugator {
    // イ段 kana used to detect 一段(上) verbs (prev kana before final る).
    private static let ichidanIPrev: Set<Character> = [
        "い", "き", "し", "ち", "に", "ひ", "み", "り", "ぎ", "じ", "び", "ぴ",
    ]
    // エ段 kana used to detect 一段(下) verbs (prev kana before final る).
    private static let ichidanEPrev: Set<Character> = [
        "え", "け", "せ", "て", "ね", "へ", "め", "れ", "げ", "ぜ", "べ", "ぺ",
    ]

    /// Detects the base conjugation CID from the hiragana reading's tail.
    /// Returns nil for カ変 (くる) and undetectable tails; the caller falls
    /// back to a single element with CID 772 in that case.
    static func detectBaseCid(hiraganaReading: String) -> Int? {
        // Priority 1: サ変 (する)
        if hiraganaReading.hasSuffix("する") { return 583 }
        // Priority 2: カ変 (くる) — deferred to nil
        if hiraganaReading.hasSuffix("くる") { return nil }

        let chars = Array(hiraganaReading)

        if hiraganaReading.hasSuffix("る") {
            // Need at least 2 chars to check prev kana.
            if chars.count >= 2 {
                let prev = chars[chars.count - 2]
                // Priority 3: 一段(上) — prev kana in イ段
                if ichidanIPrev.contains(prev) { return 619 }
                // Priority 4: 一段(下) — prev kana in エ段
                if ichidanEPrev.contains(prev) { return 619 }
            }
            // Priority 5: other -る → 五段ラ行
            return 772
        }

        // Priority 6-13: single-kana tails
        guard let last = chars.last else { return nil }
        switch last {
        case "く": return 679   // 五段カ行(イ音便)
        case "ぐ": return 723   // 五段ガ行
        case "す": return 731   // 五段サ行
        case "つ": return 738   // 五段タ行
        case "ぬ": return 746   // 五段ナ行
        case "ぶ": return 754   // 五段バ行
        case "む": return 762   // 五段マ行
        case "う": return 802   // 五段ワ行(ウ音便)
        default: return nil     // Priority 14: undetectable
        }
    }

    /// Expands a verb into all conjugated `DicdataElement` forms (including the
    /// base 終止形). Falls back to a single element with CID 772 when the base
    /// CID cannot be detected (カ変/くる or non-verb tails).
    static func dicdataElements(word: String, hiraganaReading: String) -> [DicdataElement] {
        guard let baseCid = detectBaseCid(hiraganaReading: hiraganaReading) else {
            // Undetectable (incl. カ変/くる): fall back to single element with CID 772.
            return [DicdataElement(word: word, ruby: hiraganaReading.toKatakana(),
                                   cid: 772, mid: MIDData.一般.mid, value: -5)]
        }
        let rubyKatakana = hiraganaReading.toKatakana()
        let forms = JapaneseConjugationBuilder.conjugations(
            for: (word: word, ruby: rubyKatakana, cid: baseCid),
            includingStandardForm: true)
        return forms.map { form in
            DicdataElement(word: form.word, ruby: form.ruby,
                           cid: form.cid, mid: MIDData.一般.mid, value: -5)
        }
    }
}

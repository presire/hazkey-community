import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// 動詞のひらがな読みの末尾を正しい基本CIDへ対応付け、その動詞をすべての活用形のDicdataElementへ展開する末尾検出レイヤー
///
/// 既知の限界:
/// 一段 vs 五段-る の曖昧さ (例: "切る/走る/帰る"は、"-iru/-eru"で終わるが、実際には五段) は、辞書なしでは読みだけから解決できない
/// 曖昧なケースは一段 (CID 619) にフォールバックする
/// 基本形 (終止形) は常に注入されるため、いずれにせよユーザは辞書形を得られる
enum VerbConjugator {
    // 一段(上)動詞を検出するために使うイ段のかな (末尾の「る」の直前のかな)
    private static let ichidanIPrev: Set<Character> = [
        "い", "き", "し", "ち", "に", "ひ", "み", "り", "ぎ", "じ", "び", "ぴ",
    ]
    // 一段(下)動詞を検出するために使うエ段のかな (末尾の「る」の直前のかな)
    private static let ichidanEPrev: Set<Character> = [
        "え", "け", "せ", "て", "ね", "へ", "め", "れ", "げ", "ぜ", "べ", "ぺ",
    ]

    /// ひらがな読みの末尾から基本活用CIDを検出する
    /// カ変 (くる) と検出不能な末尾ではnilを返し、呼び出し側はその場合はCID 772の単一要素にフォールバックする
    static func detectBaseCid(hiraganaReading: String) -> Int? {
        // 優先度1: サ変 (する)
        if hiraganaReading.hasSuffix("する") { return 583 }
        // 優先度2: カ変 (くる) - nilを返す
        if hiraganaReading.hasSuffix("くる") { return nil }

        let chars = Array(hiraganaReading)

        if hiraganaReading.hasSuffix("る") {
            // 直前のかなを調べるには最低2文字必要
            if chars.count >= 2 {
                let prev = chars[chars.count - 2]
                // 優先度3: 一段(上) - 直前のかながイ段
                if ichidanIPrev.contains(prev) { return 619 }
                // 優先度4: 一段(下) - 直前のかながエ段
                if ichidanEPrev.contains(prev) { return 619 }
            }
            // 優先度5: それ以外の -る → 五段ラ行
            return 772
        }

        // 優先度6-13: 1文字のかなの末尾
        guard let last = chars.last else { return nil }
        switch last {
        case "く": return 679   // 五段カ行(イ音便)
        case "ぐ": return 723   // 五段ガ行
        case "す": return 731   // 五段サ行
        case "つ": return 738   // 五段タ行
        case "ぬ": return 746   // 五段ナ行
        case "ぶ": return 754   // 五段バ行
        case "む": return 762   // 五段マ行
        case "う": return 802   // 五段ワ行 (ウ音便)
        default: return nil     // 優先度14: 検出不能
        }
    }

    /// 動詞を全活用形のDicdataElement (基本形の終止形を含む) へ展開する
    /// 基本CIDを検出できない場合 (カ変 / くる、または動詞以外の末尾) は、CID 772の単一要素にフォールバックする
    static func dicdataElements(word: String, hiraganaReading: String) -> [DicdataElement] {
        guard let baseCid = detectBaseCid(hiraganaReading: hiraganaReading) else {
            // 検出不能 (カ変 / くるを含む): CID 772の単一要素にフォールバックする
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

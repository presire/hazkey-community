import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// 動詞のひらがな読みの末尾から基本CIDを特定し全活用形のDicdataElementへ展開する末尾検出層
///
/// 読みの末尾だけを見て基本となる活用CIDを決める
///
/// 決めたCIDを起点に全活用形へ展開する
///
/// - Note: 一段と五段-るの曖昧さ (切るや走るや帰る等-iruや-eruで終わるが実際は五段) は読みだけでは解決できない
///
/// - Note: 曖昧な場合は一段 (CID 619) へフォールバックするが終止形は常に注入されるため辞書形は得られる
enum VerbConjugator {
    /// 一段(上)を検出するためのイ段かな
    ///
    /// 末尾の[る]の直前のかなと照合する
    private static let ichidanIPrev: Set<Character> = [
        "い", "き", "し", "ち", "に", "ひ", "み", "り", "ぎ", "じ", "び", "ぴ",
    ]
    /// 一段(下)を検出するためのエ段かな
    ///
    /// 末尾の[る]の直前のかなと照合する
    private static let ichidanEPrev: Set<Character> = [
        "え", "け", "せ", "て", "ね", "へ", "め", "れ", "げ", "ぜ", "べ", "ぺ",
    ]

    /// ひらがな読みの末尾から基本活用CIDを検出する
    ///
    /// [サ変]するは583を返す
    ///
    /// [カ変]くるはnilを返す
    ///
    /// [る]で終わる場合は直前のかなで一段(上)や一段(下)や五段ラ行を切り分ける
    ///
    /// 一段(上)や一段(下)は619を返しそれ以外の[る]は五段ラ行として772を返す
    ///
    /// 末尾1かなでは五段各行を切り分ける (くは679、ぐは723、すは731、つは738、ぬは746、ぶは754、むは762、うは802)
    ///
    /// - Parameter hiraganaReading: 判定対象のひらがな読み
    /// - Returns: 基本活用CID、[カ変]や動詞以外の末尾ではnil
    /// - Note: nilの場合は呼び出し側がCID 772の単一要素へフォールバックする
    static func detectBaseCid(hiraganaReading: String) -> Int? {
        // 優先度1はサ変(する)
        if hiraganaReading.hasSuffix("する") { return 583 }
        // 優先度2はカ変(くる)でありnilを返す
        if hiraganaReading.hasSuffix("くる") { return nil }

        let chars = Array(hiraganaReading)

        if hiraganaReading.hasSuffix("る") {
            // 直前のかなを調べるには最低2文字必要
            if chars.count >= 2 {
                let prev = chars[chars.count - 2]
                // 優先度3は一段(上)であり直前のかながイ段の場合
                if ichidanIPrev.contains(prev) { return 619 }
                // 優先度4は一段(下)であり直前のかながエ段の場合
                if ichidanEPrev.contains(prev) { return 619 }
            }
            // 優先度5はそれ以外の[る]であり五段ラ行として扱う
            return 772
        }

        // 優先度6から13は末尾1かなによる五段各行の判定
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
        default: return nil     // 優先度14は検出不能
        }
    }

    /// 動詞を基本形を含む全活用形のDicdataElementへ展開する
    ///
    /// [reading]をカタカナ化してJapaneseConjugationBuilderへ渡す
    ///
    /// 生成した各活用形へMIDData一般と値-5を付けて返す
    ///
    /// - Parameters:
    ///   - word: 表記
    ///   - hiraganaReading: ひらがな読み
    /// - Returns: 全活用形の要素、検出不能時はCID 772の単一要素
    /// - Note: [カ変]やくるや動詞以外の末尾では基本CIDが定まらないためフォールバックする
    static func dicdataElements(word: String, hiraganaReading: String) -> [DicdataElement] {
        guard let baseCid = detectBaseCid(hiraganaReading: hiraganaReading) else {
            // 検出不能 (カ変やくるを含む) はCID 772の単一要素へフォールバックする
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

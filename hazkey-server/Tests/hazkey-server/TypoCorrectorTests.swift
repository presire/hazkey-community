import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 誤字訂正 (TypoCorrector) の純粋ロジックを変換器なしで検証するテストスイート
///
/// トリガー検出、訂正候補 (variant) の生成と優先順位、表示条件 (shouldOffer)、
/// 変換候補からの完全一致選択、訂正用オプションの構築を対象にする
///
/// 実際の変換スコアによる閾値の較正は TypoCorrectionCalibrationTests が担う
final class TypoCorrectorTests: XCTestCase {
    /// テスト用に登録するローマ字入力テーブルの名前 (本番と同じ文節区切り表 + ローマ字表)
    private static let tableName = "typo-corrector-tests"

    /// テストクラス全体で使うローマ字入力テーブルを登録する
    ///
    /// 本番と同じ構成 (文節区切り表 compositionSeparatorTable とローマ字表 romajiTable、
    /// 後着優先の order lastInputWins) を tableName の名前で登録する
    override class func setUp() {
        super.setUp()
        InputStyleManager.registerInputStyle(
            table: InputTable(
                tables: [compositionSeparatorTable, romajiTable], order: .lastInputWins),
            for: tableName)
    }

    /// 登録済みの tableName を使う mapped 入力スタイルを返す
    ///
    /// 組成テキストへ挿入する各要素がこのスタイルを持つ
    private static var mappedStyle: InputStyle { .mapped(id: .tableName(tableName)) }

    /// ローマ字の打鍵列から組成テキストを作る
    ///
    /// - Parameters:
    ///   - romaji: 1文字ずつ入力する打鍵列
    ///   - separator: 変換時と同じく末尾に文節区切りを入れる (末尾のnを「ん」へ確定させる)
    private func compose(_ romaji: String, separator: Bool = true) -> ComposingText {
        var text = ComposingText()
        for character in romaji {
            text.insertAtCursorPosition([
                .init(piece: .character(character), inputStyle: Self.mappedStyle)
            ])
        }
        if separator {
            text.insertAtCursorPosition([
                .init(piece: .compositionSeparator, inputStyle: Self.mappedStyle)
            ])
        }
        return text
    }

    /// ローマ字の打鍵列から得られる訂正候補の読み一覧を返す
    ///
    /// - Parameter romaji: 1文字ずつ入力する打鍵列
    /// - Returns: トリガー検出と訂正案生成を通した後の読みの配列
    private func readings(of romaji: String) -> [String] {
        let text = compose(romaji)
        return TypoCorrector.variants(of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
            .map(\.reading)
    }

    // MARK: - トリガー

    /// 連打した促音と撥音がトリガーとして検出されることを検証する
    ///
    /// しっっぱいした と こんんにちは のいずれも位置 1..<3 にトリガーが立つ
    func testTriggersDetectRepeatedSokuonAndN() {
        XCTAssertEqual(TypoCorrector.triggers(in: "しっっぱいした").map(\.range), [1..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "こんんにちは").map(\.range), [1..<3])
    }

    /// 連打した長音符がトリガーとして検出されることを検証する
    ///
    /// すーーぱー の位置 1..<3 にトリガーが立つ
    func testRepeatedLongVowelTriggers() {
        XCTAssertEqual(TypoCorrector.triggers(in: "すーーぱー").map(\.range), [1..<3])
    }

    /// 連打した小書きやがトリガーとして検出されることを検証する
    ///
    /// こんにゃゃく の位置 3..<5 にトリガーが立つ
    func testRepeatedSmallYaTriggers() {
        XCTAssertEqual(TypoCorrector.triggers(in: "こんにゃゃく").map(\.range), [3..<5])
    }

    /// 小書きや以外の連続した小書きかなもトリガーとして検出されることを検証する
    ///
    /// きょょう の位置 1..<3、しゅゅみ の位置 1..<3 にトリガーが立つ
    func testRepeatedOtherSmallKanaTriggers() {
        XCTAssertEqual(TypoCorrector.triggers(in: "きょょう").map(\.range), [1..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "しゅゅみ").map(\.range), [1..<3])
    }

    /// 連続した促音がトリガーとして検出されることを検証する
    ///
    /// しっっ の位置 1..<3、さらに しっっっ では重なる 1..<3 と 2..<4 の両方にトリガーが立つ
    func testRepeatedSokuonTriggers() {
        XCTAssertEqual(TypoCorrector.triggers(in: "しっっ").map(\.range), [1..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "しっっっ").map(\.range), [1..<3, 2..<4])
    }

    /// 母音・撥音・長音符の直前にある促音が単独でトリガーになることを検証する
    ///
    /// えっあの・あっんと・あっーとのいずれも位置 1..<3 にトリガーが立つ
    func testTriggersDetectSokuonBeforeVowelNOrLongVowel() {
        XCTAssertEqual(TypoCorrector.triggers(in: "えっあの").map(\.range), [1..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "あっんと").map(\.range), [1..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "あっーと").map(\.range), [1..<3])
    }

    /// かなに挟まれた半角英字がトリガーとして検出されることを検証する
    ///
    /// ありgたおう は 2..<3、でsqうね は 1..<3 にトリガーが立つ
    func testTriggersDetectLatinLettersEnclosedByKana() {
        XCTAssertEqual(TypoCorrector.triggers(in: "ありgたおう").map(\.range), [2..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "でsqうね").map(\.range), [1..<3])
    }

    /// 読みの末尾に残ったローマ字がトリガーにならないことを検証する
    ///
    /// しっぱいしt・しっぱいsh・mch のいずれもトリガーが空になる
    func testTrailingRomajiIsNotATrigger() {
        XCTAssertTrue(TypoCorrector.triggers(in: "しっぱいしt").isEmpty)
        XCTAssertTrue(TypoCorrector.triggers(in: "しっぱいsh").isEmpty)
        XCTAssertTrue(TypoCorrector.triggers(in: "mch").isEmpty)
    }

    /// 読みの先頭に残ったローマ字が直後のかなと組でトリガーになることを検証する
    ///
    /// mちがい と gあいう のいずれも位置 0..<1 にトリガーが立つ
    func testLeadingRomajiFollowedByKanaIsATrigger() {
        XCTAssertEqual(TypoCorrector.triggers(in: "mちがい").map(\.range), [0..<1])
        XCTAssertEqual(TypoCorrector.triggers(in: "gあいう").map(\.range), [0..<1])
    }

    /// 先頭子音の後の母音を打ち忘れた入力に母音挿入の訂正が提示されることを検証する
    ///
    /// mchigai からは まちがい、mchigaeru からは みちがえる が得られる
    func testMissingVowelInsertionRestoresTheSkippedLeadingKana() {
        // Given: 先頭子音の後の母音が抜けている (machigai / michigaeru)
        XCTAssertEqual(compose("mchigai").convertTarget, "mちがい")

        // Then: 意図した読みを復元する母音挿入が訂正候補に含まれる
        XCTAssertTrue(readings(of: "mchigai").contains("まちがい"))
        XCTAssertTrue(readings(of: "mchigaeru").contains("みちがえる"))
    }

    /// 他の編集で編集枠が埋まっていても母音挿入の全候補が評価されることを検証する
    ///
    /// matgaeru から またがえる・まちがえる・まつがえる・まてがえる・まとがえる が得られる
    func testEveryVowelIsInsertedEvenAfterOtherEditsFillTheSlots() {
        // Given: 残存ローマ字の削除と入れ替えで3つの編集枠のうち2つが既に埋まっている (まtがえる)
        XCTAssertEqual(compose("matgaeru").convertTarget, "まtがえる")

        // Then: 母音挿入の位置が1枠を使い、2番目の母音 i を含む5母音すべてが評価される
        let readings = readings(of: "matgaeru")
        for reading in ["またがえる", "まちがえる", "まつがえる", "まてがえる", "まとがえる"] {
            XCTAssertTrue(readings.contains(reading), "\(reading): \(readings)")
        }
    }

    /// 通常のかな読みにはトリガーが検出されないことを検証する
    ///
    /// 日常的な文12件のいずれもトリガーが空になる
    func testOrdinaryReadingsHaveNoTrigger() {
        let ordinary = [
            "わたしはがくせいです", "きょうはいいてんきですね", "こんにちは", "がっこうにいきます",
            "ありがとうございます", "しっぱいした", "こーひーをのむ", "ほんとうにそう",
            "きっとだいじょうぶ", "らーめんがたべたい", "かんじへんかん", "よろしくおねがいします",
        ]
        for reading in ordinary {
            XCTAssertTrue(TypoCorrector.triggers(in: reading).isEmpty, reading)
        }
    }

    // MARK: - 訂正案

    /// 促音の連打を削除する訂正が先頭に提示されることを検証する
    ///
    /// shipppaishita の先頭候補は しっぱいした で編集種別は repeatedKey になる
    func testRepeatedKeyDeletionFixesDoubledSokuon() {
        XCTAssertEqual(compose("shipppaishita").convertTarget, "しっっぱいした")
        let text = compose("shipppaishita")
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        XCTAssertEqual(variants.first?.reading, "しっぱいした")
        XCTAssertEqual(variants.first?.edit.kind, .repeatedKey)
    }

    /// 促音以外の連打も削除で訂正されることを検証する
    ///
    /// gakkkou は がっこう、mottto は もっと になる
    func testRepeatedKeyDeletionFixesDoubledNAndSokuonInOtherWords() {
        XCTAssertEqual(readings(of: "gakkkou").first, "がっこう")
        XCTAssertEqual(readings(of: "mottto").first, "もっと")
    }

    /// 連打の長い並びがトリガーを消す最小の削除数に縮約されることを検証する
    ///
    /// shippppai は count 2 の削除で しっぱい になり、より長い連打も同じ結果になる
    func testRepeatedKeyRunCollapsesToTheSmallestFix() {
        XCTAssertEqual(compose("shippppai").convertTarget, "しっっっぱい")
        let text = compose("shippppai")
        let variant = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget)).first
        XCTAssertEqual(variant?.reading, "しっぱい")
        XCTAssertEqual(variant?.edit.kind, .repeatedKey)
        XCTAssertEqual(variant?.edit.count, 2)
        XCTAssertEqual(readings(of: "shipppppai").first, "しっぱい")
    }

    /// 連打した長音符が1つに縮約されることを検証する
    ///
    /// suーーpaー と suーーーーーpaー のいずれも すーぱー になる
    func testRepeatedLongVowelRunCollapsesToOne() {
        // 本番の"-"はキーマップで"ー"になるため、テスト表では"ー"を直接打鍵する
        XCTAssertEqual(compose("suーーpaー").convertTarget, "すーーぱー")
        XCTAssertEqual(readings(of: "suーーpaー").first, "すーぱー")
        XCTAssertEqual(compose("suーーーーーpaー").convertTarget, "すーーーーーぱー")
        XCTAssertEqual(readings(of: "suーーーーーpaー").first, "すーぱー")
    }

    /// 離れた複数の長音符の連打がまとめて訂正されることを検証する
    ///
    /// suーーpaーーー から すーぱー が得られる
    func testSeparateLongVowelRunsAreCorrectedTogether() {
        let text = compose("suーーpaーーー")
        XCTAssertEqual(text.convertTarget, "すーーぱーーー")
        XCTAssertTrue(readings(of: "suーーpaーーー").contains("すーぱー"))
    }

    /// 離れた促音と長音符の連打が2編集でまとめて訂正されることを検証する
    ///
    /// yattttaーーーman から やったーまん が得られる
    func testSeparateSokuonAndLongVowelRunsAreCorrectedTogether() {
        let text = compose("yattttaーーーman")
        XCTAssertEqual(text.convertTarget, "やっっったーーーまん")
        let variants = readings(of: "yattttaーーーman")
        XCTAssertTrue(variants.contains("やったーまん"), "actual variants: \(variants)")
    }

    /// 離れた撥音と小書きやの連打がまとめて訂正されることを検証する
    ///
    /// konnnnnnnixyaxyaku から こんにゃく が得られる
    func testSeparateNAndSmallYaRunsAreCorrectedTogether() {
        let text = compose("konnnnnnnixyaxyaku")
        XCTAssertEqual(text.convertTarget, "こんんんにゃゃく")
        XCTAssertTrue(readings(of: "konnnnnnnixyaxyaku").contains("こんにゃく"))
    }

    /// キーをまたいだ促音と小書きやの重なる連続が、まとめて1文字へ縮約されることを検証する
    ///
    /// chaxyaxyaxtuxtuxtuto・chaxyaxyatttto・chalyalyaltultultuto は、いずれも読み ちゃゃゃっっっと になり
    /// 先頭の訂正が collapsedRepeats の ちゃっと (2箇所の縮約) になる
    func testOverlappingRunsAreCollapsedTogetherAcrossKeys() {
        for romaji in ["chaxyaxyaxtuxtuxtuto", "chaxyaxyatttto", "chalyalyaltultultuto"] {
            let text = compose(romaji)
            XCTAssertEqual(text.convertTarget, "ちゃゃゃっっっと", romaji)
            let variants = TypoCorrector.variants(
                of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
            XCTAssertTrue(variants.map(\.reading).contains("ちゃっと"), "\(romaji): \(variants.map(\.reading))")
            XCTAssertEqual(variants.first?.edit.kind, .collapsedRepeats, romaji)
            XCTAssertEqual(variants.first?.reading, "ちゃっと", romaji)
            XCTAssertEqual(variants.first?.editCount, 2, romaji)
        }
    }

    /// 別々のローマ字キーで打った促音と小書きかなの連続が1文字へ縮約されることを検証する
    ///
    /// shixtuxtupai から しっぱい、kyoxyou から きょう が得られる
    func testSmallKanaAndSokuonTypedByDistinctKeysCollapse() {
        XCTAssertEqual(compose("shixtuxtupai").convertTarget, "しっっぱい")
        XCTAssertTrue(readings(of: "shixtuxtupai").contains("しっぱい"))
        XCTAssertEqual(compose("kyoxyou").convertTarget, "きょょう")
        XCTAssertTrue(readings(of: "kyoxyou").contains("きょう"))
    }

    /// かなの直後で ん を伴わない にゃ・にゅ・にょ だけがトリガーになることを検証する
    ///
    /// きにょうび は 1..<3、こにゃく は 1..<3 にトリガーが立ち、こんにゃく と読み先頭の にゅうりょく には立たない
    func testTriggersDetectNyaWithoutPrecedingN() {
        XCTAssertEqual(TypoCorrector.triggers(in: "きにょうび").map(\.range), [1..<3])
        XCTAssertEqual(TypoCorrector.triggers(in: "こにゃく").map(\.range), [1..<3])
        XCTAssertTrue(TypoCorrector.triggers(in: "こんにゃく").isEmpty)
        XCTAssertTrue(TypoCorrector.triggers(in: "にゅうりょく").isEmpty)
    }

    /// 母音の代わりに隣の子音キーを打った入力が、その子音を母音へ置き換えて訂正されることを検証する
    ///
    /// arigatpu (p→o)、sayonsra (s→a)、shitsumkn (k→o) の意図した読みが adjacentKey の訂正として得られ、
    /// どの訂正案にも半角英字が残らない
    func testAdjacentKeySubstitutionRestoresMistypedVowel() {
        let cases = [
            ("arigatpu", "ありがtぷ", "ありがとう"),
            ("sayonsra", "さよんsら", "さよなら"),
            ("shitsumkn", "しつmkん", "しつもん"),
        ]
        for (romaji, reading, expected) in cases {
            let text = compose(romaji)
            XCTAssertEqual(text.convertTarget, reading, romaji)
            let variants = TypoCorrector.variants(
                of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
            XCTAssertTrue(
                variants.contains { $0.edit.kind == .adjacentKey && $0.reading == expected },
                "\(romaji): \(variants.map(\.reading))")
            for variant in variants {
                XCTAssertFalse(variant.reading.contains { $0.isASCII && $0.isLetter }, "\(romaji) -> \(variant.reading)")
            }
        }
    }

    /// ん を打ち忘れて にゃ・にゅ・にょ になった入力に、ん を補う訂正が提示されることを検証する
    ///
    /// kinyoubi は きんようび、konyaku は こんやく、hanyou は はんよう の missingN の訂正を得る
    func testMissingNInsertionRestoresNBeforeYaRow() {
        let cases = [
            ("kinyoubi", "きにょうび", "きんようび"),
            ("konyaku", "こにゃく", "こんやく"),
            ("hanyou", "はにょう", "はんよう"),
        ]
        for (romaji, reading, expected) in cases {
            let text = compose(romaji)
            XCTAssertEqual(text.convertTarget, reading, romaji)
            let variants = TypoCorrector.variants(
                of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
            XCTAssertTrue(
                variants.contains { $0.edit.kind == .missingN && $0.reading == expected },
                "\(romaji): \(variants.map(\.reading))")
        }
    }

    /// 最良の訂正から1編集分のペナルティ以上離れた訂正が除かれることを検証する
    ///
    /// 最良 38.2 に対して 26.2 ちょうどは除かれ、それより近い値は元の順序のまま残る
    func testCompetitiveKeepsOnlyCorrectionsNearTheBest() {
        let best = 38.2
        let values = [best, best - TypoCorrector.competitiveMargin + 0.1, best - TypoCorrector.competitiveMargin, 13.1]
        XCTAssertEqual(TypoCorrector.competitive(values, adjustedValue: { $0 }), Array(values.prefix(2)))
        XCTAssertTrue(TypoCorrector.competitive([Double](), adjustedValue: { $0 }).isEmpty)
    }

    /// かなに挟まれた英字に母音を補って読みを復元する訂正を検証する
    ///
    /// arigtou と argatou のいずれも missingVowel の訂正で ありがとう になる
    func testMissingVowelInsertionRestoresTheSkippedKana() {
        XCTAssertEqual(compose("arigtou").convertTarget, "ありgとう")
        XCTAssertTrue(
            TypoCorrector.variants(of: compose("arigtou"), triggers: TypoCorrector.triggers(in: "ありgとう"))
                .contains { $0.edit.kind == .missingVowel && $0.reading == "ありがとう" })
        XCTAssertEqual(compose("argatou").convertTarget, "あrがとう")
        XCTAssertTrue(
            TypoCorrector.variants(of: compose("argatou"), triggers: TypoCorrector.triggers(in: "あrがとう"))
                .contains { $0.edit.kind == .missingVowel && $0.reading == "ありがとう" })
    }

    /// 訂正候補の読みに半角英字が残らないことを検証する
    ///
    /// 英字を含む複数の打鍵列で、生成されたどの候補にも半角英字が含まれない
    func testVariantsNeverLeaveLatinLettersAroundTheEdit() {
        for romaji in ["argatou", "arigtou", "arigtaou", "arigaqtou", "shitsumkon"] {
            let text = compose(romaji)
            for variant in TypoCorrector.variants(of: text, triggers: TypoCorrector.triggers(in: text.convertTarget)) {
                XCTAssertFalse(variant.reading.contains { $0.isASCII && $0.isLetter }, "\(romaji) -> \(variant.reading)")
            }
        }
    }

    /// 読みに残った英字だけを削除する訂正が先頭に提示されることを検証する
    ///
    /// arigaqtou の先頭候補は ありがとう で編集種別は strayRomaji になる
    func testStrayRomajiDeletionRemovesOnlyTheLetterLeftInTheReading() {
        XCTAssertEqual(compose("arigaqtou").convertTarget, "ありがqとう")
        let text = compose("arigaqtou")
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        XCTAssertEqual(variants.first?.reading, "ありがとう")
        XCTAssertEqual(variants.first?.edit.kind, .strayRomaji)
    }

    /// 残存ローマ字削除に続いて隣接文字の入れ替え訂正も提示されることを検証する
    ///
    /// arigtaou では先頭が strayRomaji で、adjacentSwap の ありがとう も候補に含まれる
    func testAdjacentSwapIsOfferedAfterStrayRomajiDeletion() {
        XCTAssertEqual(compose("arigtaou").convertTarget, "ありgたおう")
        let text = compose("arigtaou")
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        XCTAssertEqual(variants.first?.edit.kind, .strayRomaji)
        XCTAssertTrue(variants.contains { $0.edit.kind == .adjacentSwap && $0.reading == "ありがとう" })
    }

    /// トリガーを解消できない編集が候補から除外されることを検証する
    ///
    /// shitsumkon では m が残る入れ替えは提示されず、全候補でトリガーが消える
    func testEditThatDoesNotRemoveTheTriggerIsRejected() {
        // "しつmこん"の"m"だけが残存ローマ字で、他の編集では"m"が残る
        let text = compose("shitsumkon")
        XCTAssertEqual(text.convertTarget, "しつmこん")
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        XCTAssertEqual(variants.first?.reading, "しつこん")
        XCTAssertFalse(variants.contains { $0.edit.kind == .adjacentSwap })
        for variant in variants {
            XCTAssertTrue(TypoCorrector.triggers(in: variant.reading).isEmpty)
        }
    }

    /// トリガーが無い入力では訂正候補が生成されないことを検証する
    ///
    /// しっぱいした はトリガーが空で、明示的な空トリガーでも候補が空になる
    func testNoTriggerYieldsNoVariant() {
        let text = compose("shippaishita")
        XCTAssertTrue(TypoCorrector.triggers(in: text.convertTarget).isEmpty)
        XCTAssertTrue(TypoCorrector.variants(of: text, triggers: []).isEmpty)
    }

    /// 訂正候補が編集種別と位置で優先順位付けされ上限3件に制限されることを検証する
    ///
    /// 先頭は全並びをまとめて縮約する collapsedRepeats で、その後に同じ並びの数だけ縮約箇所を数えた
    /// 連打削除 (repeatedKey) が左から続く
    ///
    /// collapsedRepeats は1回で全ての並びを消せるため、1箇所だけを縮約する partial な案より先に置く
    func testVariantsArePrioritizedByEditKindThenPositionAndCappedAtThree() {
        // 優先順位: 全並び縮約 → 連打削除 (左から)、上限は縮約箇所の数で3
        let text = compose("arigaqtoushipppaigakkkoumottto")
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        XCTAssertEqual(variants.count, TypoCorrector.maxVariants)
        XCTAssertEqual(variants.map(\.edit.kind), [.collapsedRepeats, .repeatedKey, .repeatedKey])
        XCTAssertEqual(
            variants.map(\.reading),
            [
                "ありがqとうしっぱいがっこうもっと",
                "ありがqとうしっぱいがっっこうもっっと",
                "ありがqとうしっっぱいがっこうもっっと",
            ])
        XCTAssertEqual(variants.first?.editCount, 3)

        let mixed = compose("shipppaiarigaqtou")
        let mixedVariants = TypoCorrector.variants(
            of: mixed, triggers: TypoCorrector.triggers(in: mixed.convertTarget))
        let kinds = mixedVariants.map(\.edit.kind)
        XCTAssertEqual(kinds.first, .repeatedKey)
        if let strayIndex = kinds.firstIndex(of: .strayRomaji),
            let swapIndex = kinds.firstIndex(of: .adjacentSwap)
        {
            XCTAssertLessThan(strayIndex, swapIndex)
        }
    }

    /// 訂正後の組成テキストが各要素の元の入力スタイルを保つことを検証する
    ///
    /// 要素数は削除分だけ減り、全要素が mappedStyle で、カーソルは末尾に残る
    func testVariantsKeepTheOriginalInputStyleOfEachElement() {
        let text = compose("shipppaishita")
        let variant = try? XCTUnwrap(
            TypoCorrector.variants(of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
                .first)
        XCTAssertEqual(variant?.composingText.input.count, text.input.count - 1)
        XCTAssertTrue(variant?.composingText.input.allSatisfy { $0.inputStyle == Self.mappedStyle } ?? false)
        XCTAssertTrue(variant?.composingText.isAtEndIndex ?? false)
    }

    /// 直接入力の要素が訂正で削除も入れ替えもされないことを検証する
    ///
    /// 直接入力の っ が2つ並んでトリガーが立っても訂正候補は生成されない
    func testDirectInputElementsAreNeverEdited() {
        // 直接入力の"っ"が2つ並んでトリガーになるが、直接入力の要素は削除も入れ替えもしない
        var text = ComposingText()
        text.insertAtCursorPosition("shi".map { .init(piece: .character($0), inputStyle: Self.mappedStyle) })
        text.insertAtCursorPosition("っっ", inputStyle: .direct)
        text.insertAtCursorPosition("pai".map { .init(piece: .character($0), inputStyle: Self.mappedStyle) })
        XCTAssertEqual(text.convertTarget, "しっっぱい")
        XCTAssertFalse(TypoCorrector.triggers(in: text.convertTarget).isEmpty)
        XCTAssertTrue(
            TypoCorrector.variants(of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
                .isEmpty)
    }

    /// 訂正によって文節区切りの要素が増減しないことを検証する
    ///
    /// 候補が生成される入力でも全候補で区切りの個数が元と一致する
    func testCompositionSeparatorsAreNeverEdited() {
        var text = ComposingText()
        let separator = ComposingText.InputElement(piece: .compositionSeparator, inputStyle: Self.mappedStyle)
        text.insertAtCursorPosition("shippp".map { .init(piece: .character($0), inputStyle: Self.mappedStyle) })
        text.insertAtCursorPosition([separator, separator])
        text.insertAtCursorPosition("aishita".map { .init(piece: .character($0), inputStyle: Self.mappedStyle) })
        text.insertAtCursorPosition([separator])
        let separatorCount = text.input.filter { $0.piece == .compositionSeparator }.count
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        XCTAssertFalse(variants.isEmpty)
        for variant in variants {
            XCTAssertEqual(
                variant.composingText.input.filter { $0.piece == .compositionSeparator }.count,
                separatorCount)
        }
    }

    // MARK: - 表示条件

    /// 表示条件が編集数に応じたペナルティを減算して判定されることを検証する
    ///
    /// 1編集ではペナルティ分の差まで提示し、2編集では同じ差でも提示しない
    func testOfferConditionSubtractsThePenaltyPerEdit() {
        let penalty = Double(TypoCorrector.typoEditPenalty)
        XCTAssertTrue(TypoCorrector.shouldOffer(variantValue: -10, baselineValue: -10 - penalty, editCount: 1))
        XCTAssertFalse(
            TypoCorrector.shouldOffer(variantValue: -10, baselineValue: -10 - penalty + 0.5, editCount: 1))
        XCTAssertFalse(TypoCorrector.shouldOffer(variantValue: -10, baselineValue: -10 - penalty, editCount: 2))
    }

    /// 完全な訂正が提示される場合はトリガーが残る部分的な訂正が除かれることを検証する
    ///
    /// ちゃっと が候補にあるときは ゃゃ が残る ちゃゃっっっと を落とし、完全な訂正が無いときは全件を返す
    func testPreferringCompleteDropsPartialCorrectionsWhenACompleteOneExists() {
        let partials = ["ちゃゃっっっと", "ちゃゃゃっっと"]
        let withComplete = TypoCorrector.preferringComplete(["ちゃゃっっっと", "ちゃっと"], reading: { $0 })
        XCTAssertEqual(withComplete, ["ちゃっと"])
        XCTAssertEqual(TypoCorrector.preferringComplete(partials, reading: { $0 }), partials)
        XCTAssertTrue(TypoCorrector.preferringComplete([String](), reading: { $0 }).isEmpty)
    }

    /// 読み全体を覆わない候補を除外して完全一致する候補を選ぶことを検証する
    ///
    /// 読み長6では 失敗した が選ばれ、読み長7では一致する候補が無い
    func testBestExactMatchIgnoresCandidatesThatDoNotCoverTheWholeReading() {
        /// 指定した表記と読み長を持つテスト用の変換候補を作る
        ///
        /// - Parameters:
        ///   - text: 候補の表記
        ///   - ruby: 候補の読み (カタカナ)
        ///   - value: 候補のスコア
        /// - Returns: 組み立てた Candidate
        func candidate(_ text: String, ruby: String, value: PValue) -> Candidate {
            Candidate(
                text: text, value: value, composingCount: .surfaceCount(ruby.count),
                lastMid: MIDData.一般.mid,
                data: [.init(word: text, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: value)])
        }
        let result = [candidate("失敗", ruby: "シッパイ", value: -5), candidate("失敗した", ruby: "シッパイシタ", value: -9)]
        XCTAssertEqual(TypoCorrector.bestExactMatch(in: result, readingLength: 6)?.text, "失敗した")
        XCTAssertNil(TypoCorrector.bestExactMatch(in: result, readingLength: 7))
    }

    /// 訂正用オプションが不要な変換機能を無効化することを検証する
    ///
    /// 候補数1・特別候補なし・Zenzaiオフ・予測無効・古典訂正無効を設定し学習種別は維持する
    func testCorrectionOptionsDisableZenzaiPredictionAndSpecialCandidates() {
        let memory = FileManager.default.temporaryDirectory
        let base = ConvertRequestOptions(
            N_best: 9, requireJapanesePrediction: .manualMix, requireEnglishPrediction: .disabled,
            keyboardLanguage: .none, learningType: .inputAndOutput, memoryDirectoryURL: memory,
            sharedContainerURL: memory, textReplacer: .empty,
            specialCandidateProviders: [CalendarSpecialCandidateProvider()],
            typoCorrectionMode: .disabled, metadata: nil)
        let options = TypoCorrector.correctionOptions(from: base)
        XCTAssertEqual(options.N_best, 1)
        XCTAssertTrue(options.specialCandidateProviders.isEmpty)
        guard case .off = options.zenzaiMode else { return XCTFail("zenzai must be off") }
        guard case .disabled = options.requireJapanesePrediction else {
            return XCTFail("prediction must be disabled")
        }
        guard case .disabled = options.typoCorrectionMode else {
            return XCTFail("classic typo correction must stay disabled")
        }
        XCTAssertEqual(options.learningType, .inputAndOutput)
    }
}

import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// タイポ訂正の編集ペナルティが陽性例とトリガ付き陰性例を分離することを較正するテスト
///
/// 編集ペナルティ (1編集目12、追加編集ごと+8) を実測マージンに対して固定し
/// 陽性フィクスチャが提示され続け、トリガ付き陰性フィクスチャが抑制されることを検証する
final class TypoCorrectionCalibrationTests: XCTestCase {
    /// この較正テスト専用の入力スタイル名
    ///
    /// [InputStyleManager.registerInputStyle] へ登録するテーブル名として使う
    private static let tableName = "typo-correction-calibration-tests"

    /// 提示され続けるべき陽性フィクスチャの組を固定する
    ///
    /// 各要素は (タイポ入力, 期待する訂正後の表記) の組である
    /// いずれも訂正候補が提示され、表記が期待値と一致することを検証する
    private static let positiveFixtures: [(input: String, expected: String)] = [
        ("shipppaishita", "失敗した"),
        ("konnnnichiha", "こんにちは"),
        ("gakkkou", "学校"),
        ("mottto", "もっと"),
        ("chottto", "ちょっと"),
        ("kittto", "きっと"),
        ("zetttai", "絶対"),
        ("ipppai", "いっぱい"),
        ("arigaqtou", "ありがとう"),
        ("arigtaou", "ありがとう"),
        ("sukkkiri", "スッキリ"),
        ("ikkkai", "1回"),
        ("makkkuro", "真っ黒"),
        ("shippppai", "失敗"),
        ("suーーpaー", "スーパー"),
        ("suーーーーーpaー", "スーパー"),
        ("arigtou", "ありがとう"),
        ("argatou", "ありがとう"),
        ("yatttaーーーman", "ヤッターマン"),
        ("konnnnnnnixyaxyaku", "こんにゃく"),
        ("suーーpaーーー", "スーパー"),
        ("arigatpu", "ありがとう"),
        ("sayonsra", "さよなら"),
        ("shitsumkn", "質問"),
        ("kinyoubi", "金曜日"),
        ("konyaku", "婚約"),
        ("hanyou", "汎用"),
    ]

    /// 最良の訂正に2編集を要する入力の集合
    ///
    /// [positiveFixtures] の部分集合であり、訂正の編集数が2であることを検証する
    private static let multiEditFixtures = ["yatttaーーーman", "konnnnnnnixyaxyaku", "suーーpaーーー"]

    /// トリガを持たない通常の読みの集合
    ///
    /// タイポ訂正のトリガが発生せず、訂正候補の変種も生成されないことを検証する
    private static let negativeNoTriggerFixtures = [
        "わたしはがくせいです", "きょうはいいてんきですね", "こんにちは", "がっこうにいきます",
        "ありがとうございます", "しっぱいした", "こーひーをのむ", "ほんとうにそう",
        "きっとだいじょうぶ", "らーめんがたべたい", "かんじへんかん", "よろしくおねがいします",
    ]
    /// トリガを持つが訂正がペナルティを下回る入力の集合
    ///
    /// 例として うんん を含む
    ///
    /// 訂正候補は生成されるが、実測マージンが編集ペナルティを下回るため
    /// 提示されないことを検証する
    private static let triggeredNegativeFixtures = ["うんん"]
    /// トリガを持つが訂正がペナルティを下回る、ローマ字入力の集合
    ///
    /// ん を補う訂正 (missingN) は入力側の [n][y] の並びを必要とするため、読みではなくローマ字で組成する
    private static let triggeredNegativeRomajiFixtures = ["kinyuu", "kanyuu", "shinyou"]

    /// 較正テストで使用する入力スタイルを登録する
    ///
    /// 解決された [compositionSeparatorTable] と [romajiTable] を
    /// [tableName] の名前で [InputStyleManager] へ登録する
    override class func setUp() {
        super.setUp()
        InputStyleManager.registerInputStyle(
            table: InputTable(
                tables: [compositionSeparatorTable, romajiTable], order: .lastInputWins),
            for: tableName)
    }

    /// 較正テストが使うマップ済み入力スタイル
    ///
    /// [tableName] を参照する [InputStyle] を返す
    private static var mappedStyle: InputStyle { .mapped(id: .tableName(tableName)) }

    /// azooKey の辞書ディレクトリの URL
    ///
    /// このテストファイルの位置から3階層上り、azooKey_dictionary_storage 配下の
    /// Dictionary ディレクトリを組み立てる
    private static var dictionaryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
    }

    /// 入力文字列をローマ字入力の組成テキストへ変換する
    ///
    /// 各文字を [mappedStyle] で挿入した後、末尾に合成区切りを挿入する
    ///
    /// - Parameter input: 変換対象の入力文字列
    /// - Returns: 組み立てた [ComposingText]
    private func compose(_ input: String) -> ComposingText {
        var text = ComposingText()
        for character in input {
            text.insertAtCursorPosition([
                .init(piece: .character(character), inputStyle: Self.mappedStyle)
            ])
        }
        text.insertAtCursorPosition([
            .init(piece: .compositionSeparator, inputStyle: Self.mappedStyle)
        ])
        return text
    }

    /// 読み文字列を組成テキストへ変換する
    ///
    /// 各文字を [mappedStyle] で挿入した後、末尾に合成区切りを挿入する
    ///
    /// - Parameter reading: 変換対象の読み文字列
    /// - Returns: 組み立てた [ComposingText]
    private func composeReading(_ reading: String) -> ComposingText {
        var text = ComposingText()
        for character in reading {
            text.insertAtCursorPosition([
                .init(piece: .character(character), inputStyle: Self.mappedStyle)
            ])
        }
        text.insertAtCursorPosition([
            .init(piece: .compositionSeparator, inputStyle: Self.mappedStyle)
        ])
        return text
    }

    /// 入力テキストに対する最良の完全一致候補を返す
    ///
    /// 直前の組成を停止してから候補を要求し、読み長と rubyCount が一致する先頭の候補を選ぶ
    ///
    /// - Parameters:
    ///   - text: 候補を要求する組成テキスト
    ///   - converter: 候補生成に使う変換器
    ///   - options: 変換要求オプション
    /// - Returns: 最良の完全一致候補 一致する候補がなければ nil
    private func bestExact(
        _ text: ComposingText,
        converter: KanaKanjiConverter,
        options: ConvertRequestOptions
    ) -> Candidate? {
        converter.stopComposition()
        return TypoCorrector.bestExactMatch(
            in: converter.requestCandidates(text, options: options).mainResults,
            readingLength: text.convertTarget.count)
    }

    /// ペナルティ適用後のスコアが最大になる訂正候補を返す
    ///
    /// [TypoCorrector.variants] が生成した変種のそれぞれについて [bestExact] の候補を求め
    /// 候補値から [TypoCorrector.penalty] を引いたスコアが最大のものを選ぶ
    ///
    /// - Parameters:
    ///   - text: 候補を要求する組成テキスト
    ///   - converter: 候補生成に使う変換器
    ///   - options: 変換要求オプション
    /// - Returns: 最良の訂正候補とその編集数 候補がなければ nil
    private func bestCorrection(
        _ text: ComposingText,
        converter: KanaKanjiConverter,
        options: ConvertRequestOptions
    ) -> (candidate: Candidate, editCount: Int)? {
        let variants = TypoCorrector.variants(
            of: text, triggers: TypoCorrector.triggers(in: text.convertTarget))
        var best: (candidate: Candidate, editCount: Int)?
        var bestScore: Double?
        for variant in variants {
            guard let candidate = self.bestExact(
                variant.composingText, converter: converter, options: options)
            else { continue }
            let score = Double(candidate.value) - TypoCorrector.penalty(editCount: variant.editCount)
            if let current = bestScore, score <= current { continue }
            bestScore = score
            best = (candidate, variant.editCount)
        }
        return best
    }

    /// 編集ペナルティが陽性例とトリガ付き陰性例を分離することを検証する
    ///
    /// 陽性フィクスチャは提示され、トリガを持たない陰性フィクスチャは変種を生成せず
    /// トリガ付き陰性フィクスチャはペナルティにより抑制されることを確かめる
    ///
    /// - Throws: 辞書が未チェックアウトの場合は XCTSkip を送出する
    func testTypoEditPenaltySeparatesPositiveAndTriggeredNegativeFixtures() throws {
        // 実測境界 最小の単一編集陽性マージンは 15.611 (kittto) トリガ付き
        // 陰性の うんん のマージンは 10.644 (編集数1 ペナルティ12を下回る) ペナルティは1編集目12
        // に追加編集ごと8を加算する (2編集では20) 複数編集の陽性 yatttaーーーman
        // マージン 34.754 konnnnnnnixyaxyaku マージン 63.488 suーーpaーーー マージン 23.477 はいずれも
        // 編集数2で選択され提示され続ける 最良の変種はペナルティ適用後のスコアで選ばれ
        // 本番と一致する うんんうんん ふーーんふーーん
        // 隣接キー (adjacentKey) の実測マージンは arigatpu 44.543 sayonsra 50.153 shitsumkn 53.559
        // ん の補完 (missingN) は kinyoubi 28.364 konyaku 22.825 hanyou 14.478 で、いずれもペナルティ12を上回る
        // 正しい語が基準になる kinyuu (記入→金融 1.461) kanyuu (加入→勧誘 -1.716) shinyou (屎尿→信用 3.629) は下回る
        // うんんふーーん の変種ごとのプローブでは編集数1の変種のみが生成され (最良マージン 21.512 13.543
        // 12.605 はいずれも提示) 提示されない2編集の変種はフィクスチャとして固定できない
        guard FileManager.default.isReadableFile(
            atPath: Self.dictionaryURL.appendingPathComponent("louds/charID.chid").path)
        else { throw XCTSkip("azooKey_dictionary_storage is not checked out") }

        let memory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "typo-calibration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: memory) }

        let converter = KanaKanjiConverter(dictionaryURL: Self.dictionaryURL)
        let base = ConvertRequestOptions(
            N_best: 9, requireJapanesePrediction: .manualMix, requireEnglishPrediction: .disabled,
            keyboardLanguage: .none, fullWidthRomanCandidate: true, learningType: .nothing,
            memoryDirectoryURL: memory, sharedContainerURL: memory, textReplacer: .empty,
            specialCandidateProviders: [CalendarSpecialCandidateProvider()],
            typoCorrectionMode: .disabled, metadata: nil)
        let options = TypoCorrector.correctionOptions(from: base)
        XCTAssertGreaterThan(TypoCorrector.typoEditPenalty, 0)
        XCTAssertGreaterThanOrEqual(Self.positiveFixtures.count, 10)
        XCTAssertGreaterThanOrEqual(Self.negativeNoTriggerFixtures.count, 10)
        XCTAssertGreaterThanOrEqual(Self.triggeredNegativeFixtures.count, 1)

        for fixture in Self.positiveFixtures {
            let text = compose(fixture.input)
            let baseline = try XCTUnwrap(bestExact(text, converter: converter, options: options), fixture.input)
            let corrected = try XCTUnwrap(bestCorrection(text, converter: converter, options: options), fixture.input)
            let margin = Double(corrected.candidate.value) - Double(baseline.value)
            print("[typo-calibration] positive \(fixture.input): reading=\(text.convertTarget) surface=\(corrected.candidate.text) edits=\(corrected.editCount) margin=\(margin)")
            XCTAssertEqual(corrected.candidate.text, fixture.expected, fixture.input)
            if Self.multiEditFixtures.contains(fixture.input) {
                XCTAssertEqual(corrected.editCount, 2, fixture.input)
            }
            XCTAssertTrue(
                TypoCorrector.shouldOffer(
                    variantValue: Double(corrected.candidate.value), baselineValue: Double(baseline.value), editCount: corrected.editCount),
                fixture.input)
        }

        for reading in Self.negativeNoTriggerFixtures {
            let text = composeReading(reading)
            XCTAssertTrue(TypoCorrector.triggers(in: text.convertTarget).isEmpty, reading)
            XCTAssertTrue(
                TypoCorrector.variants(
                    of: text, triggers: TypoCorrector.triggers(in: text.convertTarget)).isEmpty,
                reading)
        }

        let triggeredNegatives =
            Self.triggeredNegativeFixtures.map { ($0, composeReading($0)) }
            + Self.triggeredNegativeRomajiFixtures.map { ($0, compose($0)) }
        for (reading, text) in triggeredNegatives {
            XCTAssertFalse(TypoCorrector.triggers(in: text.convertTarget).isEmpty, reading)
            let baseline = try XCTUnwrap(bestExact(text, converter: converter, options: options), reading)
            let corrected = try XCTUnwrap(bestCorrection(text, converter: converter, options: options), reading)
            let margin = Double(corrected.candidate.value) - Double(baseline.value)
            print("[typo-calibration] negative \(reading): corrected=\(corrected.candidate.text) edits=\(corrected.editCount) margin=\(margin)")
            XCTAssertLessThan(margin, TypoCorrector.penalty(editCount: corrected.editCount), reading)
            XCTAssertFalse(
                TypoCorrector.shouldOffer(
                    variantValue: Double(corrected.candidate.value), baselineValue: Double(baseline.value), editCount: corrected.editCount),
                reading)
        }
    }
}

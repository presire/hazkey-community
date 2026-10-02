import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// アラインメント区切りの送信判定と読み超過候補の除外、変換エンジンへ渡す組成テキストを固定する
///
/// モデルを読み込まない純関数テスト。全文を変換エンジンへ渡すのは、非サジェスト・Zenzai 有効・設定が適用可能・カーソル途中・末尾が文節区切りの時のみ
/// それ以外は、カーソルまでの読みを渡す
final class ZenzaiAlignmentRequestTests: XCTestCase {
    private static func profile(separatorOn: Bool) -> Hazkey_Config_Profile {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.zenzaiAlignmentSeparator = separatorOn
        return profile
    }

    private static func modelURL(named fileName: String) -> URL {
        URL(fileURLWithPath: "/models/\(fileName)")
    }

    /// サーバが変換時に作るのと同じ形の組成テキストを作成する
    ///
    /// 読みを挿入して、末尾に文節区切りを足して (ensureCompositionSeparatorForConversionと同じ形)、カーソルを左へ動かす
    /// 区切り無しの場合は、末尾の区切りを省く (未確定のローマ字が残る形)
    private static func midCursorText(
        reading: String, moveLeft: Int, withSeparator: Bool
    ) -> ComposingText {
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        if withSeparator {
            text.insertAtCursorPosition([
                .init(piece: .compositionSeparator, inputStyle: .direct)
            ])
        }
        _ = text.moveCursorFromCursorPosition(count: moveLeft)
        return text
    }

    private static func candidate(text: String, ruby: String) -> Candidate {
        Candidate(
            text: text,
            value: 0,
            composingCount: .surfaceCount(text.count),
            lastMid: MIDData.一般.mid,
            data: [
                .init(
                    word: text, ruby: ruby, cid: CIDData.固有名詞.cid,
                    mid: MIDData.一般.mid, value: 0)
            ]
        )
    }

    // MARK: - (a) 設定の適用判定

    /// (a1) フラグOFFでは適用されず、対応モデル + フラグONで適用される
    func testAlignmentSeparatorAppliesFlagOffAndOn() {
        XCTAssertFalse(
            HazkeyServerConfig.alignmentSeparatorApplies(
                profile: Self.profile(separatorOn: false),
                modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf")))
        XCTAssertTrue(
            HazkeyServerConfig.alignmentSeparatorApplies(
                profile: Self.profile(separatorOn: true),
                modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf")))
    }

    /// (a2) 名前で判別できないモデルは厳格に非対応
    func testAlignmentSeparatorAppliesRejectsUndistinguishableModels() {
        let profile = Self.profile(separatorOn: true)
        XCTAssertFalse(
            HazkeyServerConfig.alignmentSeparatorApplies(
                profile: profile, modelURL: Self.modelURL(named: "my-custom.gguf")))
        XCTAssertFalse(
            HazkeyServerConfig.alignmentSeparatorApplies(
                profile: profile, modelURL: Self.modelURL(named: "zenzai.gguf")))
        XCTAssertFalse(
            HazkeyServerConfig.alignmentSeparatorApplies(profile: profile, modelURL: nil))
    }

    // MARK: - (b) 全文の送信判定

    /// (b1) サジェストでは送らない
    func testShouldSendFullReadingRejectsSuggest() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: -1, withSeparator: true)
        XCTAssertFalse(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: true, zenzaiOn: true, alignmentApplies: true))
    }

    /// (b2) Zenzai無効では送らない
    func testShouldSendFullReadingRejectsZenzaiOff() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: -1, withSeparator: true)
        XCTAssertFalse(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: false, zenzaiOn: false,
                alignmentApplies: true))
    }

    /// (b3) 設定が適用不可では送らない
    func testShouldSendFullReadingRejectsWhenNotApplicable() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: -1, withSeparator: true)
        XCTAssertFalse(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: false, zenzaiOn: true,
                alignmentApplies: false))
    }

    /// (b4) カーソル位置0では送らない
    func testShouldSendFullReadingRejectsCursorAtZero() {
        let text = Self.midCursorText(
            reading: "にほんご", moveLeft: -100, withSeparator: true)
        XCTAssertEqual(text.convertTargetCursorPosition, 0)
        XCTAssertFalse(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: false, zenzaiOn: true,
                alignmentApplies: true))
    }

    /// (b5) カーソル末尾では送らない
    func testShouldSendFullReadingRejectsCursorAtEnd() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: 0, withSeparator: true)
        XCTAssertTrue(text.isAtEndIndex)
        XCTAssertFalse(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: false, zenzaiOn: true,
                alignmentApplies: true))
    }

    /// (b6) 条件を満たし、末尾が文節区切りなら送る
    func testShouldSendFullReadingAcceptsMidCursorWithSeparator() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: -1, withSeparator: true)
        XCTAssertFalse(text.isAtEndIndex)
        XCTAssertGreaterThan(text.convertTargetCursorPosition, 0)
        XCTAssertTrue(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: false, zenzaiOn: true,
                alignmentApplies: true))
    }

    /// (b7) 末尾が文節区切りでない場合 (未確定のローマ字) は送らない
    func testShouldSendFullReadingRejectsWithoutTrailingSeparator() {
        let text = Self.midCursorText(
            reading: "にほんご", moveLeft: -1, withSeparator: false)
        XCTAssertFalse(text.isAtEndIndex)
        XCTAssertGreaterThan(text.convertTargetCursorPosition, 0)
        XCTAssertFalse(
            HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: text, isSuggest: false, zenzaiOn: true,
                alignmentApplies: true))
    }

    // MARK: - (c) 読み超過候補の除外

    /// (c1) 全候補が範囲内ならそのまま返り除外件数が0
    func testCandidatesWithinReadingKeepsAllInside() {
        let candidates = [
            Self.candidate(text: "日本", ruby: "にほん"),
            Self.candidate(text: "二本", ruby: "にほん"),
        ]
        let result = HazkeyServerState.candidatesWithinReading(
            candidates, readingLength: 3)
        XCTAssertEqual(result.kept.map(\.text), ["日本", "二本"])
        XCTAssertEqual(result.droppedCount, 0)
    }

    /// (c2) 超過候補だけ除かれ件数が正しい
    func testCandidatesWithinReadingDropsOversized() {
        let candidates = [
            Self.candidate(text: "日本", ruby: "にほん"),
            Self.candidate(text: "ニホンゴ", ruby: "にほんご"),
            Self.candidate(text: "にほ", ruby: "にほ"),
            Self.candidate(text: "にほんご", ruby: "にほんご"),
        ]
        let result = HazkeyServerState.candidatesWithinReading(
            candidates, readingLength: 3)
        XCTAssertEqual(result.kept.map(\.text), ["日本", "にほ"])
        XCTAssertEqual(result.droppedCount, 2)
    }

    // MARK: - (d) 変換エンジンへ渡す組成テキスト

    /// (d1) サジェストでカーソルが途中の場合は、読み全体をカーソル末尾で渡す (Zenzai のプロンプトとラティスを一致させる)
    func testSuggestRequestTextMovesMidCursorToEnd() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: -2, withSeparator: true)
        let request = HazkeyServerState.candidateRequestText(for: text, isSuggest: true)
        XCTAssertTrue(request.isAtEndIndex)
        XCTAssertEqual(request.toHiragana(), "にほんご")
        XCTAssertEqual(request.input.count, text.input.count)
    }

    /// (d2) 変換でカーソルが途中の場合は、カーソルまでの読みを渡す
    func testConversionRequestTextUsesPrefixForMidCursor() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: -2, withSeparator: true)
        let request = HazkeyServerState.candidateRequestText(for: text, isSuggest: false)
        XCTAssertEqual(request.toHiragana(), "にほ")
    }

    /// (d3) カーソルが末尾の場合は、サジェストでも変換でも組成テキストをそのまま渡す
    func testRequestTextAtEndIsUnchanged() {
        let text = Self.midCursorText(reading: "にほんご", moveLeft: 0, withSeparator: true)
        for isSuggest in [true, false] {
            let request = HazkeyServerState.candidateRequestText(for: text, isSuggest: isSuggest)
            XCTAssertEqual(request, text)
        }
    }
}

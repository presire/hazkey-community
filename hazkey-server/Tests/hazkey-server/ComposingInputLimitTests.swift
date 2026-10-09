import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class ComposingInputLimitTests: XCTestCase {
    private func makeState(tableContents: String) throws -> HazkeyServerState {
        let directory = HazkeyServerConfig.getConfigDirectory()
        let tables = directory.appendingPathComponent("table")
        try FileManager.default.createDirectory(at: tables, withIntermediateDirectories: true)
        try Data(tableContents.utf8).write(to: tables.appendingPathComponent("bounded.tsv"))
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.zenzaiEnable = false
        profile.enabledKeymaps = []
        profile.enabledTables = [.with {
            $0.name = "bounded"
            $0.filename = "bounded.tsv"
            $0.isBuiltIn = false
        }]
        try Data("[\(try profile.jsonString())]".utf8).write(to: directory.appendingPathComponent("config.json"))
        return HazkeyServerState()
    }

    /// 表示が空になる入力要素を1回の挿入でまとめて追加する
    ///
    /// 変換エンジンのフォークは、DEBUGビルドで挿入のたびに組成テキスト全体を標準出力へ出す
    /// 4096個を1個ずつ挿入すると出力量が入力要素数の二乗に比例し、1テストで約1GBに達してCIのログ転送が詰まる
    /// 1回の挿入なら出力は1回で済み、[inputChar]を1個ずつ繰り返した場合と同じ[input]になる
    private func insertEmptyInputs(_ state: HazkeyServerState, count: Int) {
        state.composingText.value.insertAtCursorPosition(
            String(repeating: "a", count: count),
            inputStyle: .mapped(id: .tableName(state.currentTableName)))
    }

    private func prediction(reading: String) -> DisplayedCandidate {
        .fromConverter(Candidate(
            text: "仮名", value: 0, composingCount: .surfaceCount(1), lastMid: MIDData.一般.mid,
            data: [.init(word: "仮名", ruby: reading, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)]))
    }

    func testEmptyAndShrinkingCustomTablesStopAt4096InputsAndResetRecovers() throws {
        for table in ["a\t{any character}\n", "aa\ta\n"] {
            try withIsolatedServerEnvironment { _ in
                let state = try makeState(tableContents: table)
                defer { state.close() }
                insertEmptyInputs(state, count: HazkeyServerState.maxComposingInputElements - 1)
                XCTAssertEqual(state.inputChar(inputString: "a").status, .success, "input 4096")
                XCTAssertEqual(state.composingText.value.input.count, 4096)
                XCTAssertEqual(state.composingText.value.convertTarget, table.hasPrefix("aa") ? "a" : "")
                state.currentCandidateList = [prediction(reading: "カナ")]
                state.isShiftPressedAlone = true
                state.shiftPressedAt = .now
                let before = state.composingText.value
                let shiftPressedAt = state.shiftPressedAt
                let submode = state.isSubInputMode
                let sessionID = state.conversionSessionID
                let dirty = state.learningDataNeedsCommit
                let rejected = state.inputChar(inputString: "a")
                XCTAssertEqual(rejected.status, .failed)
                XCTAssertEqual(rejected.errorMessage, "Composing text is limited to 4096 inputs.")
                XCTAssertEqual(state.composingText.value, before)
                XCTAssertEqual(state.currentCandidateList?.count, 1)
                guard case .fromConverter(let candidate) = state.currentCandidateList?.first else {
                    return XCTFail("Rejection discarded the candidate")
                }
                XCTAssertEqual(candidate.text, "仮名")
                XCTAssertTrue(state.isShiftPressedAlone)
                XCTAssertEqual(state.shiftPressedAt, shiftPressedAt)
                XCTAssertEqual(state.isSubInputMode, submode)
                XCTAssertEqual(state.conversionSessionID, sessionID)
                XCTAssertEqual(state.learningDataNeedsCommit, dirty)
                XCTAssertEqual(state.createComposingTextInstanse().status, .success)
                XCTAssertEqual(state.composingText.value.input.count, 0)
                XCTAssertNil(state.currentCandidateList)
                XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
                XCTAssertEqual(state.composingText.value.input.count, 1)
            }
        }
    }

    func testPredictionInputBoundaryRejectsBeforeMutationAndAccepts4096() throws {
        for emptyInputs in [4094, 4095] {
            try withIsolatedServerEnvironment { _ in
                let state = try makeState(tableContents: "a\t{any character}\n")
                defer { state.close() }
                insertEmptyInputs(state, count: emptyInputs)
                XCTAssertEqual(state.inputChar(inputString: "か").status, .success)
                XCTAssertEqual(state.composingText.value.input.count, emptyInputs + 1)
                state.currentCandidateList = [prediction(reading: "カナ")]
                let before = state.composingText.value
                XCTAssertEqual(HazkeyServerState.predictionInputElementUpperBound(
                    reading: "カナ", composing: before), emptyInputs + 2)
                let response = state.acceptPrediction(candidateIndex: 0)
                if emptyInputs == 4095 {
                    XCTAssertEqual(response.status, .failed)
                    XCTAssertEqual(response.errorMessage, "Composing text is limited to 4096 inputs.")
                    XCTAssertEqual(state.composingText.value, before)
                    XCTAssertEqual(state.currentCandidateList?.count, 1)
                    XCTAssertFalse(state.learningDataNeedsCommit)
                } else {
                    XCTAssertEqual(response.status, .success, response.errorMessage)
                    XCTAssertEqual(state.composingText.value.input.count, 4096)
                    XCTAssertEqual(state.composingText.value.convertTarget, "かな")
                    XCTAssertNil(state.currentCandidateList)
                }
            }
        }
    }

    func testRepeatedConversionOfEmptyDisplayStopsAt4096InputsWithoutMutation() throws {
        try withIsolatedServerEnvironment { _ in
            let state = try makeState(tableContents: "a\t{any character}\n")
            defer { state.close() }
            // 先頭の数回だけ実際に変換して増加量を確かめ、残りは上限直前までまとめて挿入する
            XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            XCTAssertEqual(state.composingText.value.input.count, 2)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            XCTAssertEqual(state.composingText.value.input.count, 3)
            insertEmptyInputs(state, count: HazkeyServerState.maxComposingInputElements - 6)
            XCTAssertEqual(state.composingText.value.input.count, HazkeyServerState.maxComposingInputElements - 3)
            for count in (HazkeyServerState.maxComposingInputElements - 2)...HazkeyServerState.maxComposingInputElements {
                XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success, "input count \(count)")
                XCTAssertEqual(state.composingText.value.input.count, count)
                XCTAssertEqual(state.composingText.value.convertTarget, "")
            }
            state.currentCandidateList = [prediction(reading: "カナ")]
            state.currentCandidateListIsSuggest = true
            let before = state.composingText.value
            let sessionID = state.conversionSessionID
            let dirty = state.learningDataNeedsCommit
            for _ in 0..<3 {
                let rejected = state.getCandidates(is_suggest: false)
                XCTAssertEqual(rejected.status, .failed)
                XCTAssertEqual(rejected.errorMessage, "Composing text is limited to 4096 inputs.")
                XCTAssertNil(rejected.payload)
                XCTAssertEqual(state.composingText.value, before)
                XCTAssertEqual(state.currentCandidateList?.count, 1)
                guard case .fromConverter(let candidate) = state.currentCandidateList?.first else {
                    return XCTFail("Rejection discarded the candidate")
                }
                XCTAssertEqual(candidate.text, "仮名")
                XCTAssertTrue(state.currentCandidateListIsSuggest)
                XCTAssertEqual(state.conversionSessionID, sessionID)
                XCTAssertEqual(state.typoCorrectionSessionCount, 0)
                XCTAssertEqual(state.learningDataNeedsCommit, dirty)
            }
            XCTAssertEqual(state.createComposingTextInstanse().status, .success)
            XCTAssertEqual(state.composingText.value.input.count, 0)
        }
    }

    func testDeletionFrozenExpansionIsCheckedBeforeApplyingEitherDirection() throws {
        for emptyInputs in [4092, 4094] {
            for deletesLeft in [true, false] {
                try withIsolatedServerEnvironment { _ in
                    let state = try makeState(tableContents: "a\t{any character}\nb\tあいう\nc\tえ\n")
                    defer { state.close() }
                    // 表示される先頭文字を置き、表示が空の入力要素が[b]の[frozen]への展開に巻き込まれないようにする
                    XCTAssertEqual(state.inputChar(inputString: "c").status, .success)
                    state.composingText.value.insertAtCursorPosition(String(repeating: "a", count: emptyInputs),
                        inputStyle: .mapped(id: .tableName(state.currentTableName)))
                    XCTAssertEqual(state.inputChar(inputString: "b").status, .success)
                    XCTAssertEqual(state.composingText.value.input.count, emptyInputs + 2)
                    XCTAssertEqual(state.moveCursor(offset: deletesLeft ? -1 : -2).status, .success)
                    state.currentCandidateList = [prediction(reading: "アイウ")]
                    let before = state.composingText.value
                    var edited = before
                    if deletesLeft { edited.deleteBackwardFromCursorPosition(count: 1) }
                    else { edited.deleteForwardFromCursorPosition(count: 1) }
                    XCTAssertEqual(edited.input.count, emptyInputs + 4)
                    XCTAssertTrue(edited.input.contains { $0.piece == .character("あ") })
                    let response = deletesLeft ? state.deleteLeft() : state.deleteRight()
                    if emptyInputs == 4094 {
                        XCTAssertEqual(response.status, .failed)
                        XCTAssertEqual(response.errorMessage, "Composing text is limited to 4096 inputs.")
                        XCTAssertEqual(state.composingText.value, before)
                    } else {
                        XCTAssertEqual(response.status, .success)
                        XCTAssertEqual(state.composingText.value, edited)
                        XCTAssertEqual(edited.input.count, 4096)
                    }
                    XCTAssertEqual(state.currentCandidateList?.count, 1)
                    XCTAssertFalse(state.learningDataNeedsCommit)
                }
            }
        }
    }

    func testSurfacePrefixExpansionRejectsBeforeLearningOrCompleting() throws {
        for isConverter in [true, false] {
            try withIsolatedServerEnvironment { _ in
                let state = try makeState(tableContents: "a\t{any character}\nb\tあいう\nc\tえ\n")
                defer { state.close() }
                XCTAssertEqual(state.inputChar(inputString: "b").status, .success)
                // [b]の直後に表示される文字で境界を作り、部分確定時にも表示が空の接尾辞を残す
                XCTAssertEqual(state.inputChar(inputString: "c").status, .success)
                state.composingText.value.insertAtCursorPosition(String(repeating: "a", count: 4094),
                    inputStyle: .mapped(id: .tableName(state.currentTableName)))
                XCTAssertEqual(state.composingText.value.input.count, 4096)
                state.currentCandidateList = isConverter ? [prediction(reading: "ア")]
                    : [.fromEmoji(word: "😀", composingCount: .surfaceCount(1))]
                let before = state.composingText.value
                var completed = before
                completed.prefixComplete(composingCount: .surfaceCount(1))
                XCTAssertEqual(completed.input.count, 4097)
                let sessionID = state.conversionSessionID
                let response = state.completePrefix(candidateIndex: 0)
                XCTAssertEqual(response.status, .failed)
                XCTAssertEqual(response.errorMessage, "Composing text is limited to 4096 inputs.")
                XCTAssertEqual(state.composingText.value, before)
                XCTAssertEqual(state.currentCandidateList?.count, 1)
                XCTAssertFalse(state.learningDataNeedsCommit)
                XCTAssertEqual(state.conversionSessionID, sessionID)
            }
        }
    }

    func testOverLimitShrinkingEditIsAllowedButGrowthAndNoChangeAreRejected() throws {
        let tableName = UUID().uuidString
        let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: "a\t{any character}\n")
        InputStyleManager.registerInputStyle(table: table, for: tableName)
        var before = ComposingText()
        before.insertAtCursorPosition(String(repeating: "a", count: 4098),
                                      inputStyle: .mapped(id: .tableName(tableName)))
        var shrinking = before
        shrinking.prefixComplete(composingCount: .inputCount(1))
        XCTAssertEqual(shrinking.input.count, 4097)
        XCTAssertNil(HazkeyServerState.composingEditLimitFailure(from: before, to: shrinking))
        XCTAssertEqual(HazkeyServerState.composingEditLimitFailure(from: shrinking, to: before)?.status, .failed)
        XCTAssertEqual(HazkeyServerState.composingEditLimitFailure(from: before, to: before)?.status, .failed)
    }

    func testComposingLimitOverloadKeepsStringLimitsAndCountsInvisibleElements() throws {
        let tableName = UUID().uuidString
        let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: "a\t{any character}\n")
        InputStyleManager.registerInputStyle(table: table, for: tableName)
        var composing = ComposingText()
        composing.insertAtCursorPosition(String(repeating: "a", count: 4096),
                                        inputStyle: .mapped(id: .tableName(tableName)))
        XCTAssertFalse(HazkeyServerState.exceedsComposingLimit(composing))
        composing.insertAtCursorPosition("a", inputStyle: .mapped(id: .tableName(tableName)))
        XCTAssertTrue(HazkeyServerState.exceedsComposingLimit(composing))
        XCTAssertFalse(HazkeyServerState.exceedsComposingLimit(composing.convertTarget))
        XCTAssertFalse(HazkeyServerState.exceedsComposingLimit(String(repeating: "あ", count: 512)))
        XCTAssertTrue(HazkeyServerState.exceedsComposingLimit(String(repeating: "あ", count: 513)))
    }
}

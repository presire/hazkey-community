import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class CandidateSafetyTests: XCTestCase {
    private var root: URL?
    private var savedEnvironment: [String: String] = [:]
    private let environmentKeys = ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        self.root = root
        for key in environmentKeys {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, root.appendingPathComponent(key).path, 1)
        }
    }

    override func tearDownWithError() throws {
        for key in environmentKeys {
            if let old = savedEnvironment[key] { setenv(key, old, 1) } else { unsetenv(key) }
        }
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func stateWithCandidates() throws -> HazkeyServerState {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        _ = state.createComposingTextInstanse()
        for character in "かな" { _ = state.inputChar(inputString: String(character)) }
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        XCTAssertFalse(try XCTUnwrap(state.currentCandidateList).isEmpty)
        return state
    }

    func testStalePrefixCompletionAfterMoveToStartDoesNotTrapOnNextInput() throws {
        let state = try stateWithCandidates()
        XCTAssertEqual(state.moveCursor(offset: -1024).status, .success)
        let before = state.composingText.value
        let completion = state.completePrefix(candidateIndex: 0)
        XCTAssertEqual(completion.status, .failed)
        XCTAssertFalse(completion.errorMessage.isEmpty)
        XCTAssertEqual(state.composingText.value, before)
        XCTAssertEqual(state.inputChar(inputString: "あ").status, .success)
        XCTAssertGreaterThanOrEqual(state.composingText.value.convertTargetCursorPosition, 0)
    }

    func testAllCandidateIndexAPIsRejectEditedComposition() throws {
        for edit in [0, 1, 2] {
            let state = try stateWithCandidates()
            if edit == 0 { _ = state.inputChar(inputString: "あ") }
            if edit == 1 { _ = state.deleteLeft() }
            if edit == 2 {
                _ = state.moveCursor(offset: -1)
                _ = state.deleteRight()
            }
            let before = state.composingText.value
            XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .failed)
            XCTAssertEqual(state.acceptPrediction(candidateIndex: 0).status, .failed)
            XCTAssertEqual(state.deleteCandidateLearningData(candidateIndex: 0).status, .failed)
            XCTAssertEqual(state.composingText.value, before)
        }
    }

    func testPrefixCompletionRepairsCursorEvenForFreshMidCursorCandidate() throws {
        let state = try stateWithCandidates()
        _ = state.moveCursor(offset: -1024)
        state.currentCandidateList = [.fromConverter(Candidate(
            text: "仮名", value: 0, composingCount: .surfaceCount(2), lastMid: MIDData.一般.mid,
            data: [.init(word: "仮名", ruby: "カナ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)]))]
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertEqual(state.composingText.value.convertTargetCursorPosition, 0)
        XCTAssertEqual(state.inputChar(inputString: "あ").status, .success)
    }

    func testInputCharacterLimitLeavesCompositionAndModifiersUnchanged() {
        let state = HazkeyServerState()
        state.composingText.value.insertAtCursorPosition(String(repeating: "あ", count: 511), inputStyle: .direct)
        XCTAssertEqual(state.inputChar(inputString: "あ").status, .success)
        let before = state.composingText.value
        let submode = state.isSubInputMode
        let rejected = state.inputChar(inputString: "A")
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertFalse(rejected.errorMessage.isEmpty)
        XCTAssertEqual(state.composingText.value, before)
        XCTAssertEqual(state.isSubInputMode, submode)
    }

    /// 結合文字を連ねた巨大な1文字 (文字数では1) を受け付けない
    func testOversizedSingleCharacterIsRejected() {
        let state = HazkeyServerState()
        let hugeCharacter = "a" + String(repeating: "\u{0301}", count: 10_000)
        XCTAssertEqual(hugeCharacter.count, 1)
        let rejected = state.inputChar(inputString: hugeCharacter)
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertTrue(state.composingText.value.isEmpty)

        let bounded = "a" + String(repeating: "\u{0301}", count: 60)
        var accepted = 0
        while accepted < HazkeyServerState.maxComposingCharacters,
            state.inputChar(inputString: bounded).status == .success
        {
            accepted += 1
        }
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertLessThan(accepted, HazkeyServerState.maxComposingCharacters)
        let before = state.composingText.value
        XCTAssertEqual(state.inputChar(inputString: bounded).status, .failed)
        XCTAssertEqual(state.composingText.value, before)
        XCTAssertLessThanOrEqual(
            state.composingText.value.convertTarget.utf8.count, HazkeyServerState.maxComposingUTF8Bytes)
    }

    /// 上限を超える読みの予測候補は、組成も変換エンジンの状態も変えずに拒否する
    func testOversizedPredictionIsRejectedBeforeMutatingComposition() throws {
        let state = try stateWithCandidates()
        let reading = "カナ" + String(repeating: "ア", count: HazkeyServerState.maxComposingCharacters)
        let candidate = Candidate(
            text: reading, value: 0, composingCount: .surfaceCount(2), lastMid: MIDData.一般.mid,
            data: [.init(word: reading, ruby: reading, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)])
        state.currentCandidateList?.append(.fromConverter(candidate))
        let index = try XCTUnwrap(state.currentCandidateList?.indices.last)
        let before = state.composingText.value
        let rejected = state.acceptPrediction(candidateIndex: index)
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertFalse(rejected.errorMessage.isEmpty)
        XCTAssertEqual(state.composingText.value, before)
        XCTAssertNotNil(state.currentCandidateList)
    }
}

import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// Regression guard for the server-level learning dirty flag.
///
/// Learning memory is shared by every connection, so `learningDataNeedsCommit`
/// must only ever be set by a commit that produced a learning update, and must
/// only be cleared by `saveLearningData()`. A user-dictionary / emoji commit
/// produces no learning update; clearing the shared flag there could silently
/// drop another connection's pending persistence.
final class LearningCommitFlagTests: XCTestCase {
    private enum LearningCommitFlagTestError: Error {
        case environmentUpdateFailed
    }

    private var originalConfigHome: String?
    private var originalStateHome: String?
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        originalConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        originalStateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-learning-commit-flag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard setenv("XDG_CONFIG_HOME", directory.path, 1) == 0,
            setenv("XDG_STATE_HOME", directory.path, 1) == 0
        else {
            throw LearningCommitFlagTestError.environmentUpdateFailed
        }
        temporaryDirectory = directory
    }

    override func tearDownWithError() throws {
        if let originalConfigHome {
            setenv("XDG_CONFIG_HOME", originalConfigHome, 1)
        } else {
            unsetenv("XDG_CONFIG_HOME")
        }
        if let originalStateHome {
            setenv("XDG_STATE_HOME", originalStateHome, 1)
        } else {
            unsetenv("XDG_STATE_HOME")
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// A converter candidate whose data does NOT carry the user-dictionary
    /// metadata, so completing it feeds the converter's learning store.
    private func learnableCandidate(text: String, ruby: String) -> Candidate {
        Candidate(
            text: text,
            value: 0,
            composingCount: .inputCount(1),
            lastMid: MIDData.一般.mid,
            data: [
                .init(
                    word: text, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid,
                    value: 0)
            ]
        )
    }

    /// Gives the connection one input element so `prefixComplete` has
    /// something to consume.
    private func composeOneCharacter(_ state: HazkeyServerState) {
        state.composingText.value.insertAtCursorPosition("あ", inputStyle: .direct)
    }

    func testUserDictCommitDoesNotClearPendingLearningPersistence() {
        let state = HazkeyServerState()
        state.learningDataNeedsCommit = false

        // A converter commit sets the shared dirty flag.
        composeOneCharacter(state)
        state.currentCandidateList = [.fromConverter(learnableCandidate(text: "亜", ruby: "ア"))]
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertTrue(state.learningDataNeedsCommit)

        // A user-dictionary commit produces no learning update and must NOT
        // clear the pending flag (regression: it used to be cleared here).
        state.currentCandidateList = [.fromUserDict(word: "テスト")]
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertTrue(state.learningDataNeedsCommit)

        // Only an explicit save clears it.
        XCTAssertEqual(state.saveLearningData().status, .success)
        XCTAssertFalse(state.learningDataNeedsCommit)
    }

    func testEmojiCommitDoesNotClearPendingLearningPersistence() {
        let state = HazkeyServerState()
        state.learningDataNeedsCommit = false

        composeOneCharacter(state)
        state.currentCandidateList = [.fromConverter(learnableCandidate(text: "亜", ruby: "ア"))]
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertTrue(state.learningDataNeedsCommit)

        // Emoji direct-conversion commits never touch the learning store.
        composeOneCharacter(state)
        state.currentCandidateList = [.fromEmoji(word: "😀", composingCount: .inputCount(1))]
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertTrue(state.learningDataNeedsCommit)

        XCTAssertEqual(state.saveLearningData().status, .success)
        XCTAssertFalse(state.learningDataNeedsCommit)
    }
}

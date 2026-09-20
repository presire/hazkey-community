import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
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

    private func send(
        _ request: Hazkey_RequestEnvelope,
        to state: HazkeyServerState
    ) throws -> Hazkey_ResponseEnvelope {
        try Hazkey_ResponseEnvelope(
            serializedBytes: ProtocolHandler(state: state).processProto(data: request.serializedData()))
    }

    private func saveLearningDataRequest() -> Hazkey_RequestEnvelope {
        .with { $0.saveLearningData = Hazkey_Commands_SaveLearningData() }
    }

    /// 永続化に失敗したコミットは成功として扱わない。dirty フラグを維持したまま
    /// FAILED を返し、保存先が復旧した後の次のトリガーで同じ学習が永続化される。
    func testFailedLearningCommitKeepsDirtyFlagAndReportsFailure() throws {
        let shared = HazkeySharedResources()
        let first = HazkeyServerState(shared: shared)
        let second = HazkeyServerState(shared: shared)
        defer {
            first.close()
            second.close()
        }

        composeOneCharacter(first)
        first.currentCandidateList = [.fromConverter(learnableCandidate(text: "亜", ruby: "ア"))]
        XCTAssertEqual(first.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertTrue(shared.learningDataNeedsCommit)

        // 保存先を同名の通常ファイルに置き換えて書き込みを ENOTDIR で失敗させる。
        // chmod は CI コンテナの root が迂回できるため使わない。
        let memoryDirectory = shared.serverConfig.memoryDirectory()
        try FileManager.default.removeItem(at: memoryDirectory)
        XCTAssertTrue(FileManager.default.createFile(atPath: memoryDirectory.path, contents: Data()))

        let failure = try send(saveLearningDataRequest(), to: first)
        XCTAssertEqual(failure.status, .failed)
        XCTAssertFalse(failure.errorMessage.isEmpty)
        XCTAssertTrue(shared.learningDataNeedsCommit)

        try FileManager.default.removeItem(at: memoryDirectory)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

        let recovered = try send(saveLearningDataRequest(), to: second)
        XCTAssertEqual(recovered.status, .success)
        XCTAssertFalse(shared.learningDataNeedsCommit)
        let keys = try shared.converter.persistedLearningMemoryKeys(exactReadings: ["ア"])
        XCTAssertTrue(keys.contains { $0.reading == "ア" && $0.word == "亜" })
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

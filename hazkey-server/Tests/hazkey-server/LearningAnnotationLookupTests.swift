import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// [community] Reading-keyed point lookup behind the "deletable" candidate
/// annotation (GitHub Issue #1), plus the two adjacent learning-memory
/// correctness bugs fixed alongside it.
final class LearningAnnotationLookupTests: XCTestCase {
    private func withTemporaryXDG<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-annotation-lookup-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let originalConfigDirectory = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let originalStateDirectory = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", configDirectory.path, 1)
        setenv("XDG_STATE_HOME", stateDirectory.path, 1)
        defer {
            if let originalConfigDirectory {
                setenv("XDG_CONFIG_HOME", originalConfigDirectory, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            if let originalStateDirectory {
                setenv("XDG_STATE_HOME", originalStateDirectory, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        return try body(root)
    }

    private func send(
        _ request: Hazkey_RequestEnvelope,
        to state: HazkeyServerState
    ) throws -> Hazkey_ResponseEnvelope {
        try Hazkey_ResponseEnvelope(
            serializedBytes: ProtocolHandler(state: state).processProto(data: request.serializedData()))
    }

    private func seed(_ elements: [DicdataElement], in state: HazkeyServerState) {
        for element in elements {
            state.converter.updateLearningData(
                .init(
                    text: element.word,
                    value: element.value(),
                    composingCount: .inputCount(element.ruby.count),
                    lastMid: element.mid,
                    data: [element]))
            state.converter.stopComposition()
        }
        state.converter.commitUpdateLearningData()
    }

    @discardableResult
    private func candidates(
        for hiragana: String,
        in state: HazkeyServerState
    ) throws -> Hazkey_Commands_CandidatesResult {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in hiragana {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = try send(
            .with { $0.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = false } },
            to: state)
        XCTAssertEqual(response.status, .success)
        return response.candidates
    }

    private func annotated(_ word: String, in result: Hazkey_Commands_CandidatesResult) -> Bool? {
        result.candidates.first { $0.text == word }?.hasLearningEntry_p
    }

    private func profile(id: String) -> Hazkey_Config_Profile {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.profileName = id
        profile.profileID = id
        profile.useProfileIndependentHistory = true
        return profile
    }

    private func switchProfiles(
        _ profiles: [Hazkey_Config_Profile],
        in state: HazkeyServerState
    ) throws {
        let response = try send(
            .with { $0.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = profiles } },
            to: state)
        XCTAssertEqual(response.status, .success)
    }

    private func historyCount(in state: HazkeyServerState) throws -> UInt32 {
        let response = try send(
            .with {
                $0.getLearningHistory = Hazkey_Config_GetLearningHistory.with {
                    $0.query = ""
                    $0.offset = 0
                    $0.limit = 200
                }
            }, to: state)
        XCTAssertEqual(response.status, .success)
        return response.getLearningHistoryResult.totalCount
    }

    // MARK: - Point lookup semantics

    /// 永続 trie はカタカナ ruby を保存するため、ひらがな読みとの突き合わせは
    /// カタカナ正規化を経由しなければならない。
    func testPersistedTrieStoresKatakanaRubyAndAnnotatesHiraganaReading() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let entries = try state.listLearningEntries(query: "", offset: 0, limit: 10).entries
            XCTAssertEqual(entries.map(\.reading), ["キョウ"])

            let result = try candidates(for: "きょう", in: state)
            XCTAssertEqual(annotated("今日", in: result), true)
            XCTAssertTrue(result.candidates.contains { !$0.hasLearningEntry_p })
        }
    }

    func testUnlearnedReadingIsNeverAnnotated() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()

            let result = try candidates(for: "きょう", in: state)
            XCTAssertFalse(result.candidates.isEmpty)
            XCTAssertTrue(result.candidates.allSatisfy { !$0.hasLearningEntry_p })
        }
    }

    /// `.pause` がある間はスナップショットが不整合なので、注釈は付けずに縮退する
    /// (候補取得自体は成功させる)。
    func testPausedSnapshotLeavesCandidatesUnannotated() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)

            let pauseURL = state.serverConfig.memoryDirectory()
                .appendingPathComponent(".pause", isDirectory: false)
            XCTAssertTrue(FileManager.default.createFile(atPath: pauseURL.path, contents: Data()))
            defer { try? FileManager.default.removeItem(at: pauseURL) }

            let result = try candidates(for: "きょう", in: state)
            XCTAssertFalse(result.candidates.isEmpty)
            XCTAssertTrue(result.candidates.allSatisfy { !$0.hasLearningEntry_p })
        }
    }

    func testConcurrentSessionsObserveConsistentAnnotations() throws {
        try withTemporaryXDG { _ in
            let shared = HazkeySharedResources()
            let first = HazkeyServerState(shared: shared)
            let second = HazkeyServerState(shared: shared)
            defer {
                first.close()
                second.close()
            }
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: first)

            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: first)), true)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: second)), true)
        }
    }

    // MARK: - Bug D (fork): memory LOUDS cache invalidation on profile switch

    /// プロファイル切替直後の注釈は、切替後プロファイルの memory ディレクトリを反映する。
    /// バグD未修正だと旧プロファイルのキャッシュ済み trie で解決してしまう。
    func testAnnotationFollowsProfileMemoryDirectoryAfterSwitch() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            let profileA = profile(id: "A")
            let profileB = profile(id: "B")

            try switchProfiles([profileA, profileB], in: state)
            try candidates(for: "きょう", in: state)
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            try switchProfiles([profileB, profileA], in: state)
            try candidates(for: "きょう", in: state)
            seed([.init(word: "鏡", ruby: "カガミ", lcid: 12, rcid: 13, mid: 1, value: -5)], in: state)

            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)
            XCTAssertEqual(annotated("鏡", in: try candidates(for: "かがみ", in: state)), true)

            try switchProfiles([profileA, profileB], in: state)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)
            XCTAssertEqual(annotated("鏡", in: try candidates(for: "かがみ", in: state)), false)
        }
    }

    // MARK: - Bug B: clearing history must leave nothing to resurrect

    func testClearProfileIndependentHistoryLeavesNothingToResurrect() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            try switchProfiles([profile(id: "A")], in: state)
            try candidates(for: "きょう", in: state)

            let result = try candidates(for: "きょう", in: state)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == "今日" })
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            XCTAssertTrue(state.learningDataNeedsCommit)

            XCTAssertEqual(state.clearProfileLearningData().status, .success)
            XCTAssertFalse(state.learningDataNeedsCommit)

            XCTAssertEqual(try send(.with { $0.saveLearningData = Hazkey_Commands_SaveLearningData() }, to: state).status, .success)
            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)
        }
    }

    // MARK: - Bug C: pending learning must not leak across a profile switch

    func testPendingLearningDoesNotLeakIntoNewProfileDirectory() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            let profileA = profile(id: "A")
            let profileB = profile(id: "B")
            try switchProfiles([profileA, profileB], in: state)
            try candidates(for: "きょう", in: state)

            let result = try candidates(for: "きょう", in: state)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == "今日" })
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            XCTAssertTrue(state.learningDataNeedsCommit)

            try switchProfiles([profileB, profileA], in: state)
            XCTAssertEqual(try send(.with { $0.saveLearningData = Hazkey_Commands_SaveLearningData() }, to: state).status, .success)

            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)

            try switchProfiles([profileA, profileB], in: state)
            XCTAssertGreaterThan(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)
        }
    }
}

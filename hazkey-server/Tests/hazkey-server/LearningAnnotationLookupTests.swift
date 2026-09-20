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
        XCTAssertNoThrow(try state.converter.commitUpdateLearningData())
    }

    @discardableResult
    private func candidates(
        for hiragana: String,
        in state: HazkeyServerState,
        isSuggest: Bool = false
    ) throws -> Hazkey_Commands_CandidatesResult {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in hiragana {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = try send(
            .with {
                $0.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = isSuggest }
            },
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

    /// `emoji_all_E*.txt` TSV shape: emoji TAB comma-separated hiragana
    /// readings TAB variations.
    private func writeEmojiFixture(_ contents: String, named name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// - Parameter emojiFixtureURL: Always pass a fixture. `nil` falls back to
    ///   the production E17 asset, which is absent here and would disable the
    ///   emoji injection this test relies on.
    private func annotationState(emojiFixtureURL: URL?) -> HazkeyServerState {
        let state = HazkeyServerState(emojiDictionaryURL: emojiFixtureURL)
        state.serverConfig.currentProfile.zenzaiEnable = false
        return state
    }

    private func assertOnlyConverterCandidatesAreAnnotated(
        _ result: Hazkey_Commands_CandidatesResult,
        in state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let displayed = try XCTUnwrap(state.currentCandidateList, file: file, line: line)
        XCTAssertEqual(result.candidates.count, displayed.count, file: file, line: line)
        for (index, entry) in displayed.enumerated() where index < result.candidates.count {
            let wire = result.candidates[index]
            switch entry {
            case .fromConverter(let candidate):
                XCTAssertEqual(wire.text, candidate.text, file: file, line: line)
            case .fromUserDict(let word):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            case .fromDateProvider(let word):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            case .fromKanaNumberProvider(let word):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            case .fromEmoji(let word, _):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            }
        }
    }

    private func injectionCount(
        in state: HazkeyServerState,
        matching predicate: (DisplayedCandidate) -> Bool
    ) -> Int {
        (state.currentCandidateList ?? []).count(where: predicate)
    }

    // MARK: - R1: learned prediction candidates

    /// 予測候補の永続エントリは予測部分まで含む完全 ruby の下に保存されるため、
    /// 入力 prefix に切り詰めた読みでは注釈も削除も当たらない。
    func testLearnedPredictionCandidateIsAnnotatedAndDeletable() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            state.serverConfig.currentProfile.zenzaiEnable = false

            let reading = "きょう"
            try candidates(for: reading, in: state, isSuggest: true)
            let displayed = try XCTUnwrap(state.currentCandidateList)
            let target = try XCTUnwrap(
                displayed.compactMap { entry -> (text: String, ruby: String)? in
                    guard case .fromConverter(let candidate) = entry, !candidate.data.isEmpty else {
                        return nil
                    }
                    let fullRuby = candidate.data.map(\.ruby).joined()
                    guard fullRuby.count > reading.count else { return nil }
                    return (candidate.text, fullRuby)
                }.first)

            seed(
                [.init(word: target.text, ruby: target.ruby, lcid: 10, rcid: 11, mid: 1, value: -5)],
                in: state)

            let result = try candidates(for: reading, in: state, isSuggest: true)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == target.text })
            XCTAssertTrue(result.candidates[index].hasLearningEntry_p)

            let response = try send(
                .with {
                    $0.deleteCandidateLearningData = Hazkey_Commands_DeleteCandidateLearningData
                        .with { $0.index = Int32(index) }
                }, to: state)
            XCTAssertEqual(response.status, .success)
            XCTAssertGreaterThan(response.deleteCandidateLearningDataResult.deletedCount, 0)

            let requeried = try candidates(for: reading, in: state, isSuggest: true)
            XCTAssertEqual(
                requeried.candidates.first { $0.text == target.text }?.hasLearningEntry_p ?? false,
                false)
        }
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

    /// 注釈は列挙 API (全走査) ではなくポイント照会で解決される。列挙は
    /// `memory.memorymetadata` を必ず読むが、ポイント照会は LOUDS と該当シャード
    /// しか読まないので、metadata を消すと履歴は空になり注釈だけが残る。
    /// 全走査方式へ戻すと最後のアサートが落ちる。
    func testPointLookupDoesNotDependOnEnumerationMetadata() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            XCTAssertGreaterThan(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)

            let metadataURL = state.serverConfig.memoryDirectory()
                .appendingPathComponent("memory.memorymetadata", isDirectory: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
            try FileManager.default.removeItem(at: metadataURL)

            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)
        }
    }

    // MARK: - Alignment with injected candidates

    /// 注釈は絵文字・相対日付・かな数字の注入より前に確定する。相対日付は
    /// 候補列の中間に insert するため、注入が先に走ると以降の候補が別の読みで
    /// 判定される。
    func testInjectedCandidatesDoNotDisturbAnnotationAlignment() throws {
        try withTemporaryXDG { root in
            let fixture = try writeEmojiFixture(
                "🌞\tきょう,きょうのひ\t\n", named: "emoji_fixture.txt", in: root)
            let state = annotationState(emojiFixtureURL: fixture)
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let result = try candidates(for: "きょう", in: state)

            XCTAssertGreaterThan(
                injectionCount(in: state) { if case .fromDateProvider = $0 { return true } else { return false } },
                0)
            XCTAssertGreaterThan(
                injectionCount(in: state) { if case .fromEmoji = $0 { return true } else { return false } },
                0)
            XCTAssertEqual(annotated("今日", in: result), true)
            try assertOnlyConverterCandidatesAreAnnotated(result, in: state)
        }
    }

    func testKanaNumberInjectionDoesNotDisturbAnnotationAlignment() throws {
        try withTemporaryXDG { root in
            let fixture = try writeEmojiFixture(
                "🔟\tじゅう\t\n", named: "emoji_fixture.txt", in: root)
            let state = annotationState(emojiFixtureURL: fixture)

            let result = try candidates(for: "じゅう", in: state)

            XCTAssertTrue(result.candidates.contains { $0.text == "10" })
            let generated = Set(KanaNumberProvider.generateCandidates(forDecimalDigits: "10"))
            XCTAssertFalse(generated.isEmpty)
            XCTAssertGreaterThan(
                injectionCount(in: state) { entry in
                    guard case .fromKanaNumberProvider(let word) = entry else { return false }
                    return generated.contains(word)
                },
                0)
            try assertOnlyConverterCandidatesAreAnnotated(result, in: state)
        }
    }

    // MARK: - Delete round trip

    /// `[削除可]` と表示された候補は実際に削除でき、削除後に取り直した候補では
    /// 注釈が消える。既存の削除テストは応答に載る再構築済みペイロードまでしか
    /// 見ないので、再照会の経路はここでしか固定されない。
    func testAnnotatedCandidateDeleteRoundTripRemovesAnnotationOnRequery() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let result = try candidates(for: "きょう", in: state)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == "今日" })
            XCTAssertTrue(result.candidates[index].hasLearningEntry_p)

            let response = try send(
                .with {
                    $0.deleteCandidateLearningData = Hazkey_Commands_DeleteCandidateLearningData
                        .with { $0.index = Int32(index) }
                }, to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertGreaterThan(response.deleteCandidateLearningDataResult.deletedCount, 0)
            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)
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

    /// `.pause` 以外の照会失敗 (破損シャード) でも、候補取得そのものは成功し、
    /// 全候補が未注釈へ縮退する。実シャードをゴミで壊すと変換経路が境界検証の
    /// ない parse へ到達し得るため、照会シームに `malformedShard` を注入する。
    func testCorruptedShardLeavesCandidatesUnannotated() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)

            state.shared.learningSurfaceKeyLookup = { _ in
                throw LearningMemoryEnumerationError.malformedShard
            }
            defer { state.shared.learningSurfaceKeyLookup = nil }

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

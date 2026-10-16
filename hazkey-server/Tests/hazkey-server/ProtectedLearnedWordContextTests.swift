import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 選び直して確定した学習語を、確定時と同じ左文脈の要求でだけZenzaiに保護させる記録のテスト
///
/// 記録 (ProtectedLearnedWordStore) は左文脈の完全一致でだけ語を返し、学習の削除・設定の適用で捨てる
final class ProtectedLearnedWordContextTests: XCTestCase {
    private enum TestError: Error {
        case environmentUpdateFailed
    }

    private var originalConfigHome: String?
    private var originalStateHome: String?
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        originalConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        originalStateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-protected-learned-word-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard setenv("XDG_CONFIG_HOME", directory.path, 1) == 0,
            setenv("XDG_STATE_HOME", directory.path, 1) == 0
        else {
            throw TestError.environmentUpdateFailed
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

    private typealias Word = ConvertRequestOptions.ZenzaiMode.ProtectedLearnedWord

    private func element(_ word: String, _ ruby: String) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
    }

    private func candidate(_ data: [DicdataElement]) -> Candidate {
        Candidate(
            text: data.map(\.word).joined(),
            value: 0,
            composingCount: .inputCount(1),
            lastMid: MIDData.一般.mid,
            data: data
        )
    }

    // MARK: - 記録

    func testWordsAreReturnedOnlyForTheSameLeftContext() {
        var store = ProtectedLearnedWordStore()
        store.record(leftContext: "とても", data: [element("機械", "キカイ")])
        XCTAssertEqual(store.words(forLeftContext: "とても"), [Word(ruby: "キカイ", word: "機械")])
        XCTAssertEqual(store.words(forLeftContext: "あまり"), [])
        XCTAssertEqual(store.words(forLeftContext: "もとても"), [])
        XCTAssertEqual(store.words(forLeftContext: ""), [])
    }

    func testEmptyLeftContextIsNotRecorded() {
        var store = ProtectedLearnedWordStore()
        store.record(leftContext: "", data: [element("機械", "キカイ")])
        XCTAssertTrue(store.records.isEmpty)
    }

    func testCompoundIsRecordedWithEachElementAndHiraganaReadingIsNormalized() {
        var store = ProtectedLearnedWordStore()
        store.record(leftContext: "左", data: [element("講演", "こうえん"), element("会", "カイ")])
        XCTAssertEqual(
            store.words(forLeftContext: "左"),
            [Word(ruby: "コウエン", word: "講演"), Word(ruby: "カイ", word: "会"), Word(ruby: "コウエンカイ", word: "講演会")])
    }

    func testCapacityDropsOldestAndRerecordingMovesToNewest() {
        var store = ProtectedLearnedWordStore()
        for index in 0..<ProtectedLearnedWordStore.capacity {
            store.record(leftContext: "文脈\(index)", data: [element("機械", "キカイ")])
        }
        store.record(leftContext: "文脈0", data: [element("機械", "キカイ")])
        store.record(leftContext: "新しい文脈", data: [element("機械", "キカイ")])
        XCTAssertEqual(store.records.count, ProtectedLearnedWordStore.capacity)
        XCTAssertFalse(store.words(forLeftContext: "文脈0").isEmpty)
        XCTAssertTrue(store.words(forLeftContext: "文脈1").isEmpty)
        XCTAssertFalse(store.words(forLeftContext: "新しい文脈").isEmpty)
    }

    func testRemoveDropsMatchingWordInEveryContext() {
        var store = ProtectedLearnedWordStore()
        store.record(leftContext: "一", data: [element("機械", "キカイ")])
        store.record(leftContext: "二", data: [element("機械", "キカイ"), element("だ", "ダ")])
        store.remove([(reading: "きかい", word: "機械")])
        XCTAssertEqual(store.words(forLeftContext: "一"), [])
        XCTAssertEqual(store.words(forLeftContext: "二"), [Word(ruby: "ダ", word: "だ"), Word(ruby: "キカイダ", word: "機械だ")])
    }

    // MARK: - 確定時の記録

    private func commit(_ state: HazkeyServerState, leftContext: String) {
        state.setContext(surroundingText: leftContext, anchorIndex: leftContext.unicodeScalars.count)
        state.composingText.value.insertAtCursorPosition("き", inputStyle: .direct)
        state.currentCandidateList = [.fromConverter(candidate([element("機械", "キカイ")]))]
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
    }

    func testCommitRecordsWithTheLeftContextAndIsSharedAcrossConnections() {
        let shared = HazkeySharedResources()
        let first = HazkeyServerState(shared: shared)
        let second = HazkeyServerState(shared: shared)
        defer {
            first.close()
            second.close()
        }
        commit(first, leftContext: "とてもいい")
        XCTAssertEqual(shared.protectedLearnedWords.words(forLeftContext: "とてもいい"), [Word(ruby: "キカイ", word: "機械")])
    }

    /// フロントエンドは確定の直前に確定語を加えた周辺テキストを送るため、候補リストを作った時点の左文脈で記録する
    func testCommitRecordsTheLeftContextOfTheCandidateListNotTheUpdatedOne() {
        let shared = HazkeySharedResources()
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        let left = "とてもいい"
        state.setContext(surroundingText: left, anchorIndex: left.unicodeScalars.count)
        state.composingText.value.insertAtCursorPosition("き", inputStyle: .direct)
        state.currentCandidateList = [.fromConverter(candidate([element("機械", "キカイ")]))]
        let updated = left + "機械"
        state.setContext(surroundingText: updated, anchorIndex: updated.unicodeScalars.count)
        XCTAssertEqual(state.completePrefix(candidateIndex: 0).status, .success)
        XCTAssertEqual(shared.protectedLearnedWords.words(forLeftContext: left), [Word(ruby: "キカイ", word: "機械")])
        XCTAssertEqual(shared.protectedLearnedWords.words(forLeftContext: updated), [])
    }

    func testCommitDoesNotRecordWhenContextualModeIsOff() {
        let state = HazkeyServerState()
        defer { state.close() }
        state.serverConfig.currentProfile.zenzaiContextualMode = false
        commit(state, leftContext: "とてもいい")
        XCTAssertTrue(state.shared.protectedLearnedWords.records.isEmpty)
    }

    func testCommitDoesNotRecordWhenNewHistoryIsNotStored() {
        let state = HazkeyServerState()
        defer { state.close() }
        state.serverConfig.currentProfile.stopStoreNewHistory = true
        commit(state, leftContext: "とてもいい")
        XCTAssertTrue(state.shared.protectedLearnedWords.records.isEmpty)
    }

    // MARK: - 削除

    func testClearingLearningDataDropsRecords() {
        let state = HazkeyServerState()
        defer { state.close() }
        commit(state, leftContext: "とてもいい")
        XCTAssertEqual(state.shared.clearProfileLearningData().status, .success)
        XCTAssertTrue(state.shared.protectedLearnedWords.records.isEmpty)
    }

    func testForgettingSurfaceDropsRecord() throws {
        let state = HazkeyServerState()
        defer { state.close() }
        commit(state, leftContext: "とてもいい")
        _ = try state.shared.forgetLearningSurfaces([(reading: "きかい", word: "機械")])
        XCTAssertTrue(state.shared.protectedLearnedWords.records.isEmpty)
    }

    func testReinitializingConfigurationDropsRecords() {
        let state = HazkeyServerState()
        defer { state.close() }
        commit(state, leftContext: "とてもいい")
        state.reinitializeConfiguration()
        XCTAssertTrue(state.shared.protectedLearnedWords.records.isEmpty)
    }
}

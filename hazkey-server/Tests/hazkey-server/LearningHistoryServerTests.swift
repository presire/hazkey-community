import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
import XCTest

@testable import hazkey_server

final class LearningHistoryServerTests: XCTestCase {
    private func withTemporaryXDG<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-learning-history-server-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeState(memoryURL: URL) -> HazkeyServerState {
        let state = HazkeyServerState()
        let sharedURL = memoryURL.deletingLastPathComponent().appendingPathComponent(
            "shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: memoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let options = ConvertRequestOptions(
            N_best: 1,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .none,
            learningType: .inputAndOutput,
            maxMemoryCount: 64,
            memoryDirectoryURL: memoryURL,
            sharedContainerURL: sharedURL,
            textReplacer: .empty,
            specialCandidateProviders: [],
            zenzaiMode: .off,
            typoCorrectionMode: .disabled,
            metadata: nil
        )
        let composingText = ComposingText(
            convertTargetCursorPosition: 1,
            input: [.init(character: "ア", inputStyle: .direct)],
            convertTarget: "ア"
        )
        _ = state.converter.requestCandidates(composingText, options: options)
        return state
    }

    private func seed(_ elements: [DicdataElement], in state: HazkeyServerState) {
        for element in elements {
            state.converter.updateLearningData(
                .init(
                    text: element.word,
                    value: element.value(),
                    composingCount: .inputCount(1),
                    lastMid: element.mid,
                    data: [element]
                )
            )
            state.converter.stopComposition()
        }
        state.converter.commitUpdateLearningData()
    }

    private func send(
        _ request: Hazkey_RequestEnvelope,
        to state: HazkeyServerState
    ) throws -> Hazkey_ResponseEnvelope {
        let bytes = try request.serializedData()
        return try Hazkey_ResponseEnvelope(serializedBytes: ProtocolHandler(state: state).processProto(data: bytes))
    }

    private func historyRequest(query: String, offset: UInt32 = 0, limit: UInt32 = 20)
        -> Hazkey_RequestEnvelope
    {
        Hazkey_RequestEnvelope.with {
            $0.getLearningHistory = Hazkey_Config_GetLearningHistory.with {
                $0.query = query
                $0.offset = offset
                $0.limit = limit
            }
        }
    }

    private func deleteRequest(_ entries: [Hazkey_Config_LearningEntryKey]) -> Hazkey_RequestEnvelope {
        Hazkey_RequestEnvelope.with {
            $0.deleteLearningEntries = Hazkey_Config_DeleteLearningEntries.with {
                $0.entries = entries
            }
        }
    }

    private func key(for element: DicdataElement) -> Hazkey_Config_LearningEntryKey {
        Hazkey_Config_LearningEntryKey.with {
            $0.reading = element.ruby
            $0.word = element.word
            $0.lcid = UInt32(element.lcid)
            $0.rcid = UInt32(element.rcid)
        }
    }

    func testHistoryFiltersByReadingSubstring() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            seed([
                .init(word: "漢字", ruby: "カンジ", lcid: 10, rcid: 11, mid: 1, value: -5),
                .init(word: "仮名", ruby: "カナ", lcid: 12, rcid: 13, mid: 1, value: -5),
            ], in: state)

            let response = try send(historyRequest(query: "ンジ"), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.getLearningHistoryResult.entries.map(\.word), ["漢字"])
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 1)
        }
    }

    func testGetLearningHistoryMatchesHiraganaQueryAgainstKatakanaReading() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            seed([.init(word: "切符", ruby: "キリン", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let response = try send(historyRequest(query: "きりん"), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.getLearningHistoryResult.entries.map(\.word), ["切符"])
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 1)
        }
    }

    func testGetLearningHistoryMatchesKatakanaQueryAgainstHiraganaReading() throws {
        XCTAssertTrue(learningHistoryMatches(query: "キリン", reading: "きりん", word: "切符"))
    }

    func testHistoryFiltersByWordSubstring() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            seed([
                .init(word: "東京都", ruby: "トウキョウト", lcid: 10, rcid: 11, mid: 1, value: -5),
                .init(word: "京都府", ruby: "キョウトフ", lcid: 12, rcid: 13, mid: 1, value: -5),
            ], in: state)

            let response = try send(historyRequest(query: "京都府"), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.getLearningHistoryResult.entries.map(\.word), ["京都府"])
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 1)
        }
    }

    func testHistoryReturnsEmptyResultForNoMatch() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            seed([.init(word: "漢字", ruby: "カンジ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let response = try send(historyRequest(query: "不存在"), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertTrue(response.getLearningHistoryResult.entries.isEmpty)
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 0)
        }
    }

    func testInitialHistoryDoesNotRequireCandidateRequest() throws {
        try withTemporaryXDG { _ in
            let response = try send(historyRequest(query: ""), to: HazkeyServerState())

            XCTAssertEqual(response.status, .success)
            XCTAssertTrue(response.getLearningHistoryResult.entries.isEmpty)
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 0)
        }
    }

    func testHistoryPaginatesFilteredEntriesAndPreservesTotalCount() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            let elements = (0 ..< 7).map {
                DicdataElement(word: "候補\($0)", ruby: "コウホ\($0)", lcid: 10 + $0, rcid: 20 + $0, mid: 1, value: -5)
            }
            seed(elements, in: state)

            let response = try send(historyRequest(query: "候補", offset: 2, limit: 3), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.getLearningHistoryResult.entries.count, 3)
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 7)
            XCTAssertEqual(response.getLearningHistoryResult.entries.map(\.word), ["候補2", "候補3", "候補4"])
        }
    }

    func testGetLearningHistoryClampsLimitToServerMaximum() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            let elements = (0 ..< 210).map {
                DicdataElement(word: "候補\($0)", ruby: "コウホ\($0)", lcid: 10, rcid: 11, mid: 1, value: -5)
            }
            seed(elements, in: state)

            let response = try send(historyRequest(query: "", offset: 0, limit: 10000), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.getLearningHistoryResult.entries.count, 200)
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 210)
        }
    }

    func testDeleteRemovesEntryAndPersistsForFreshState() throws {
        try withTemporaryXDG { root in
            let memoryURL = root.appendingPathComponent("memory", isDirectory: true)
            let target = DicdataElement(word: "削除", ruby: "サクジョ", lcid: 10, rcid: 11, mid: 1, value: -5)
            let survivor = DicdataElement(word: "保持", ruby: "ホジ", lcid: 12, rcid: 13, mid: 1, value: -5)
            let state = makeState(memoryURL: memoryURL)
            seed([target, survivor], in: state)

            let deletion = try send(deleteRequest([key(for: target)]), to: state)
            let freshState = makeState(memoryURL: memoryURL)
            let listing = try send(historyRequest(query: ""), to: freshState)

            XCTAssertEqual(deletion.status, .success)
            XCTAssertEqual(deletion.deleteLearningEntriesResult.deletedCount, 1)
            XCTAssertEqual(listing.status, .success)
            XCTAssertEqual(listing.getLearningHistoryResult.entries.map(\.word), [survivor.word])
        }
    }

    func testDeleteInProfileDirectoryLeavesSharedDirectoryUnchanged() throws {
        try withTemporaryXDG { root in
            var profile = Hazkey_Config_Profile()
            profile.profileID = "separated"
            profile.useProfileIndependentHistory = true
            let sharedURL = HazkeyServerConfig.memoryDirectory(
                for: Hazkey_Config_Profile(), stateDirectory: root)
            let profileURL = HazkeyServerConfig.memoryDirectory(for: profile, stateDirectory: root)
            let sharedEntry = DicdataElement(word: "共有", ruby: "キョウユウ", lcid: 10, rcid: 11, mid: 1, value: -5)
            let profileEntry = DicdataElement(word: "分離", ruby: "ブンリ", lcid: 12, rcid: 13, mid: 1, value: -5)
            let sharedState = makeState(memoryURL: sharedURL)
            let profileState = makeState(memoryURL: profileURL)
            seed([sharedEntry], in: sharedState)
            seed([profileEntry], in: profileState)

            let deletion = try send(deleteRequest([key(for: profileEntry)]), to: profileState)
            let sharedListing = try send(historyRequest(query: ""), to: sharedState)

            XCTAssertEqual(deletion.status, .success)
            XCTAssertEqual(sharedListing.status, .success)
            XCTAssertEqual(sharedListing.getLearningHistoryResult.entries.map(\.word), [sharedEntry.word])
        }
    }

    // MARK: [community] Surface-key merging (one row per reading+word)

    /// Rows with the same (reading, word) but different CIDs — e.g. the
    /// clause-bigram and whole-string entries of one commit — merge into a
    /// single history row with summed counts.
    func testHistoryMergesCidVariantsIntoSingleSurfaceRow() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            seed([
                .init(word: "気円", ruby: "キエン", lcid: 10, rcid: 11, mid: 1, value: -5),
                .init(word: "気円", ruby: "キエン", lcid: 20, rcid: 21, mid: 1, value: -5),
                .init(word: "別語", ruby: "ベツゴ", lcid: 30, rcid: 31, mid: 1, value: -5),
            ], in: state)

            let response = try send(historyRequest(query: "キエン"), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.getLearningHistoryResult.entries.count, 1)
            XCTAssertEqual(response.getLearningHistoryResult.totalCount, 1)
            XCTAssertEqual(response.getLearningHistoryResult.entries.first?.word, "気円")
            XCTAssertEqual(response.getLearningHistoryResult.entries.first?.count, 2)
        }
    }

    /// Deleting a merged row removes every CID variant of the surface, even
    /// when the request key carries no CIDs (the dialog sends merged rows).
    func testDeleteSurfaceRemovesAllCidVariants() throws {
        try withTemporaryXDG { root in
            let memoryURL = root.appendingPathComponent("memory", isDirectory: true)
            let variant1 = DicdataElement(word: "気円", ruby: "キエン", lcid: 10, rcid: 11, mid: 1, value: -5)
            let variant2 = DicdataElement(word: "気円", ruby: "キエン", lcid: 20, rcid: 21, mid: 1, value: -5)
            let survivor = DicdataElement(word: "保持", ruby: "ホジ", lcid: 12, rcid: 13, mid: 1, value: -5)
            let state = makeState(memoryURL: memoryURL)
            seed([variant1, variant2, survivor], in: state)
            let surfaceKey = Hazkey_Config_LearningEntryKey.with {
                $0.reading = "キエン"
                $0.word = "気円"
            }

            let deletion = try send(deleteRequest([surfaceKey]), to: state)
            let deletedListing = try send(historyRequest(query: "キエン"), to: state)
            let survivorListing = try send(historyRequest(query: "ホジ"), to: state)

            XCTAssertEqual(deletion.status, .success)
            XCTAssertEqual(deletion.deleteLearningEntriesResult.deletedCount, 2)
            XCTAssertEqual(deletedListing.getLearningHistoryResult.totalCount, 0)
            XCTAssertEqual(survivorListing.getLearningHistoryResult.totalCount, 1)
        }
    }

    func testInvalidOffsetReturnsFailedStatusWithoutCrashing() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))

            let response = try send(historyRequest(query: "", offset: UInt32.max), to: state)

            XCTAssertEqual(response.status, .failed)
        }
    }

    /// A surface with no stored entry is skipped: deletion is best-effort per
    /// surface key, so an unknown (or already deleted) row reports success
    /// with zero deletions instead of failing the whole batch.
    func testUnknownSurfaceDeleteReturnsSuccessWithZeroCount() throws {
        try withTemporaryXDG { root in
            let state = makeState(memoryURL: root.appendingPathComponent("memory", isDirectory: true))
            let unknown = DicdataElement(word: "未知", ruby: "ミチ", lcid: 10, rcid: 11, mid: 1, value: -5)

            let response = try send(deleteRequest([key(for: unknown)]), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.deleteLearningEntriesResult.deletedCount, 0)
        }
    }

    // MARK: [community] DeleteCandidateLearningData

    private func getCandidatesRequest(isSuggest: Bool) -> Hazkey_RequestEnvelope {
        Hazkey_RequestEnvelope.with {
            $0.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = isSuggest }
        }
    }

    private func deleteCandidateRequest(index: Int32) -> Hazkey_RequestEnvelope {
        Hazkey_RequestEnvelope.with {
            $0.deleteCandidateLearningData = Hazkey_Commands_DeleteCandidateLearningData.with {
                $0.index = index
            }
        }
    }

    private func makeInputState(_ reading: String) throws -> HazkeyServerState {
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        return state
    }

    private func appendSyntheticCandidate(
        _ state: HazkeyServerState, word: String, ruby: String
    ) throws -> Int32 {
        state.currentCandidateList?.append(
            .fromConverter(
                Candidate(
                    text: word,
                    value: 0,
                    composingCount: .surfaceCount(ruby.count),
                    lastMid: MIDData.一般.mid,
                    data: [
                        .init(
                            word: word, ruby: ruby, cid: CIDData.固有名詞.cid,
                            mid: MIDData.一般.mid, value: 0)
                    ]
                )))
        return Int32(try XCTUnwrap(state.currentCandidateList?.indices.last))
    }

    /// One request deletes every stored CID variant of the same (reading,
    /// word) pair, the rebuilt list no longer contains the word, and the
    /// learning memory no longer holds the entries.
    func testDeleteCandidateLearningDataDeletesAllVariantEntriesAndPersists() throws {
        try withTemporaryXDG { _ in
            let state = try makeInputState("てすとてきご")
            let variant1 = DicdataElement(
                word: "テスト的語", ruby: "テストテキゴ", lcid: 10, rcid: 11, mid: 1, value: -5)
            let variant2 = DicdataElement(
                word: "テスト的語", ruby: "テストテキゴ", lcid: 20, rcid: 21, mid: 1, value: -5)
            seed([variant1, variant2], in: state)
            XCTAssertEqual(try send(getCandidatesRequest(isSuggest: false), to: state).status, .success)

            // The engine may or may not surface a made-up word from the system
            // dictionary, so the candidate backed by the seeded learning is
            // injected synthetically (AcceptPredictionTests pattern).
            let index = try appendSyntheticCandidate(state, word: "テスト的語", ruby: "テストテキゴ")

            let response = try send(deleteCandidateRequest(index: index), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.deleteCandidateLearningDataResult.deletedCount, 2)
            let rebuiltMatches = response.deleteCandidateLearningDataResult.candidates.candidates
                .filter { $0.text == "テスト的語" }
            if getZenzaiModelPath() == nil {
                // Without Zenzai the rebuilt list is computed from the fresh
                // lattice alone: the deleted word cannot appear at all.
                XCTAssertTrue(rebuiltMatches.isEmpty)
            } else {
                // With Zenzai the fresh draft may regenerate a similar
                // candidate, but it must no longer carry the learning
                // annotation.
                XCTAssertTrue(rebuiltMatches.allSatisfy { !$0.hasLearningEntry_p })
            }
            XCTAssertEqual(response.deleteCandidateLearningDataResult.hiragana, "てすとてきご")

            let listing = try send(historyRequest(query: "テスト"), to: state)
            XCTAssertEqual(listing.getLearningHistoryResult.totalCount, 0)
        }
    }

    /// A candidate without a matching learning entry reports "nothing
    /// deleted" as a normal success result.
    func testDeleteCandidateLearningDataOnUnlearnedCandidateReturnsZero() throws {
        try withTemporaryXDG { _ in
            let state = try makeInputState("みらぼご")
            XCTAssertEqual(try send(getCandidatesRequest(isSuggest: false), to: state).status, .success)
            let index = try appendSyntheticCandidate(state, word: "未学習語", ruby: "ミラボゴ")

            let response = try send(deleteCandidateRequest(index: index), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.deleteCandidateLearningDataResult.deletedCount, 0)
        }
    }

    /// Annotation flags follow the same matching rule as deletion: a learned
    /// candidate is flagged deletable, plain dictionary candidates are not,
    /// and after deletion the rebuilt list has the flag cleared.
    func testDeleteCandidateLearningDataUpdatesAnnotationFlags() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            let learned = DicdataElement(
                word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)
            seed([learned], in: state)
            XCTAssertEqual(state.createComposingTextInstanse().status, .success)
            for character in "きょう" {
                XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
            }

            let initial = try send(getCandidatesRequest(isSuggest: false), to: state)
            XCTAssertEqual(initial.status, .success)
            let todayIndex = try XCTUnwrap(
                initial.candidates.candidates.firstIndex { $0.text == "今日" },
                "dictionary candidate 今日 not found")
            XCTAssertTrue(initial.candidates.candidates[todayIndex].hasLearningEntry_p)
            XCTAssertTrue(initial.candidates.candidates.contains { !$0.hasLearningEntry_p })

            let response = try send(deleteCandidateRequest(index: Int32(todayIndex)), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.deleteCandidateLearningDataResult.deletedCount, 1)
            if let rebuiltToday = response.deleteCandidateLearningDataResult.candidates.candidates
                .first(where: { $0.text == "今日" })
            {
                XCTAssertFalse(rebuiltToday.hasLearningEntry_p)
            }
            let listing = try send(historyRequest(query: "キョウ"), to: state)
            XCTAssertEqual(listing.getLearningHistoryResult.totalCount, 0)
        }
    }

    func testDeleteCandidateLearningDataRejectsInvalidIndex() throws {
        try withTemporaryXDG { _ in
            let state = try makeInputState("あ")
            XCTAssertEqual(try send(getCandidatesRequest(isSuggest: false), to: state).status, .success)

            let response = try send(deleteCandidateRequest(index: 9999), to: state)

            XCTAssertEqual(response.status, .failed)
        }
    }

    /// Non-converter candidates (date provider etc.) carry no learning
    /// backing: "nothing deleted" instead of an error.
    func testDeleteCandidateLearningDataOnNonConverterCandidateReturnsZero() throws {
        try withTemporaryXDG { _ in
            let state = try makeInputState("きょう")
            XCTAssertEqual(try send(getCandidatesRequest(isSuggest: false), to: state).status, .success)
            state.currentCandidateList?.append(.fromDateProvider(word: "2026年9月8日"))
            let index = Int32(try XCTUnwrap(state.currentCandidateList?.indices.last))

            let response = try send(deleteCandidateRequest(index: index), to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertEqual(response.deleteCandidateLearningDataResult.deletedCount, 0)
        }
    }
}

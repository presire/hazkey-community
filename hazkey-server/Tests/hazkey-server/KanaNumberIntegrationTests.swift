import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class KanaNumberIntegrationTests: XCTestCase {
    func testZeroAliasesProduceZeroFamily() throws {
        for reading in ["れい", "ぜろ", "ゼロ"] {
            let texts = try candidateTexts(forReading: reading)
            for expected in ["₀", "⁰", "⓪"] {
                XCTAssertEqual(texts.filter { $0 == expected }.count, 1)
            }
        }
    }

    func testTenAnchorExistsAndEachApprovedGlyphAppearsExactlyOnce() throws {
        let texts = try candidateTexts(forReading: "じゅう")
        guard texts.contains("10") else {
            XCTFail("Expected ASCII decimal anchor")
            return
        }
        for glyph in KanaNumberProvider.generateCandidates(forDecimalDigits: "10") {
            XCTAssertEqual(texts.filter { $0 == glyph }.count, 1)
        }
    }

    func testApprovedGlyphsAppearAtMostOnce() throws {
        // 前提: 候補リストに辞書由来の候補も含まれる値
        // 実行: 日本語の数詞読みを変換する
        // 期待: 合成挿入によって承認済みの字形が重複しない
        let texts = try candidateTexts(forReading: "いち")
        for glyph in KanaNumberProvider.generateCandidates(forDecimalDigits: "1") {
            XCTAssertLessThanOrEqual(texts.filter { $0 == glyph }.count, 1)
        }
    }

    func testKanaNumberPrefixCompletionRetainsRightSideReading() throws {
        try assertKanaNumberPrefixCompletion(suffix: "えん")
    }

    func testKanaNumberPrefixCompletionAtCursorEndClearsComposition() throws {
        try assertKanaNumberPrefixCompletion(suffix: "")
    }

    private func assertKanaNumberPrefixCompletion(suffix: String) throws {
        let prefix = "じゅう"
        for pendingLearning in [false, true] {
            try withTemporaryState { state in
                XCTAssertEqual(state.createComposingTextInstanse().status, .success)
                for character in prefix + suffix {
                    XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
                }
                let response = state.getCandidates(is_suggest: false)
                XCTAssertEqual(response.status, .success)
                let result: Hazkey_Commands_CandidatesResult
                if suffix.isEmpty {
                    result = response.candidates
                } else {
                    let adjusted = state.adjustClauseBoundary(offset: -suffix.count)
                    XCTAssertEqual(adjusted.status, .success)
                    result = adjusted.clauseBoundaryResult.candidates
                }
                XCTAssertEqual(state.composingText.value.convertTargetCursorPosition, prefix.count)
                XCTAssertEqual(state.composingText.value.toHiragana(), prefix + suffix)
                XCTAssertTrue(result.candidates.contains { $0.text == "10" })
                let index = try XCTUnwrap(state.currentCandidateList?.firstIndex {
                    if case .fromKanaNumberProvider = $0 { return true }
                    return false
                }, "Expected a kana-number candidate for \(prefix)")
                let candidate = try XCTUnwrap(result.candidates.indices.contains(index)
                    ? result.candidates[index] : nil)
                XCTAssertEqual(candidate.subHiragana, suffix)
                XCTAssertFalse(candidate.hasLearningEntry_p)

                state.learningDataNeedsCommit = pendingLearning
                XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

                XCTAssertEqual(state.composingText.value.toHiragana(), suffix)
                XCTAssertEqual(state.composingText.value.isEmpty, suffix.isEmpty)
                XCTAssertEqual(state.learningDataNeedsCommit, pendingLearning)
            }
        }
    }

    private enum StateTestError: Error {
        case environmentUpdateFailed(String)
    }

    private func withTemporaryState(_ body: (HazkeyServerState) throws -> Void) throws {
        let root = try TestTempRoot.make()
        let dictionary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
        let paths = [
            "XDG_CONFIG_HOME": root.path,
            "XDG_STATE_HOME": root.path,
            "XDG_CACHE_HOME": root.path,
            "XDG_DATA_HOME": root.path,
            "HAZKEY_DICTIONARY": dictionary.path,
        ]
        let originalEnvironment = ProcessInfo.processInfo.environment
        defer {
            for variable in paths.keys {
                if let value = originalEnvironment[variable] {
                    setenv(variable, value, 1)
                } else {
                    unsetenv(variable)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for (variable, path) in paths {
            guard setenv(variable, path, 1) == 0 else {
                throw StateTestError.environmentUpdateFailed(variable)
            }
        }
        let state = HazkeyServerState()
        defer { state.close() }
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.useTypoCorrection = false
        try body(state)
    }

    private func candidateTexts(forReading reading: String) throws -> [String] {
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }
}

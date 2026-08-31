import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// Regression tests for duplicate candidates in the suggestion response.
///
/// The suggestion window (suggestionListMode = ShowPredictiveResults) receives
/// `predictionResults` followed by `mainResults`. Both arrays can contain the
/// same surface text (e.g. a user dictionary word that the converter also emits
/// as a prediction of its own best node), and `makeCandidatesResult` used to
/// concatenate them without cross-deduplication, so the same candidate appeared
/// twice in the candidate window.
final class CandidateDeduplicationTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case setFailed(String)
        case missingPath(String)
    }

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-candidate-dedup-\(UUID().uuidString)", isDirectory: true)
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        // config/hazkey/ holds the user dictionary TSV consumed by the server.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey"), withIntermediateDirectories: true)

        let paths = [
            "XDG_DATA_HOME": "data",
            "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime",
            "XDG_STATE_HOME": "state",
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            if variable == "HAZKEY_DICTIONARY" {
                let dictionaryPath = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
                guard setenv(variable, dictionaryPath.path, 1) == 0 else {
                    throw SetupError.setFailed(variable)
                }
                continue
            }
            guard let directory = paths[variable] else {
                throw SetupError.missingPath(variable)
            }
            guard setenv(variable, root.appendingPathComponent(directory).path, 1) == 0 else {
                throw SetupError.setFailed(variable)
            }
        }
        temporaryDirectory = root

        // Register 衛宮 (えみや) through the real TSV pipeline. The word is
        // expected to surface both as a prediction of its own best node and as
        // a conversion candidate, reproducing the reported duplicate.
        let tsv = root.appendingPathComponent("config/hazkey/user_dictionary.tsv")
        try "えみや\t衛宮\tregression test\tperson\n"
            .write(to: tsv, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                setenv(variable, value, 1)
            } else {
                unsetenv(variable)
            }
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testSuggestionListDeduplicatesPredictionAndMainResults() throws {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.numSuggestions = 10
        state.serverConfig.currentProfile.numCandidatesPerPage = 10
        state.serverConfig.currentProfile.suggestionListMode =
            .suggestionListShowPredictiveResults

        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in "えみや" {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: true)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        let texts = result.candidates.map(\.text)
        print("DEDUP-TEST suggestion texts:", texts)

        // Core regression: no surface text may appear more than once.
        let duplicates = Dictionary(grouping: texts, by: { $0 }).mapValues(\.count)
            .filter { $0.value > 1 }
        XCTAssertTrue(
            duplicates.isEmpty,
            "duplicate candidates in suggestion response: \(duplicates)")
        XCTAssertTrue(
            texts.contains("衛宮"),
            "user dictionary entry missing from suggestion response: \(texts)")

        // The live text must keep pointing at a visible entry carrying the
        // same text (index == texts.count models the hidden-entry case).
        let liveIndex = Int(result.liveTextIndex)
        if liveIndex >= 0 && liveIndex < texts.count {
            XCTAssertEqual(texts[liveIndex], result.liveText)
        }
    }
}

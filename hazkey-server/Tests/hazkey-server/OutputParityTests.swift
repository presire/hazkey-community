import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class OutputParityTests: XCTestCase {
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

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-output-parity-\(UUID().uuidString)", isDirectory: true)
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }

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
                    throw EnvironmentError.setFailed(variable)
                }
                continue
            }
            guard let directory = paths[variable] else {
                throw EnvironmentError.missingPath(variable)
            }
            guard setenv(variable, root.appendingPathComponent(directory).path, 1) == 0 else {
                throw EnvironmentError.setFailed(variable)
            }
        }
        temporaryDirectory = root
    }

    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                guard setenv(variable, value, 1) == 0 else {
                    throw EnvironmentError.setFailed(variable)
                }
            } else {
                guard unsetenv(variable) == 0 else {
                    throw EnvironmentError.unsetFailed(variable)
                }
            }
        }
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFullConversionParity() throws {
        try assertCandidateParity(for: CorpusFixtures.fullConversion)
    }

    func testSuggestionParity() throws {
        try assertCandidateParity(for: CorpusFixtures.suggestion)
    }

    func testPrefixConversionParity() throws {
        try assertCandidateParity(for: CorpusFixtures.prefixConversion)
    }

    func testKanaNumberParity() throws {
        try assertCandidateParity(for: CorpusFixtures.kanaNumber)
    }

    func testRelativeDateCandidateParity() throws {
        let fixture = CorpusFixtures.relativeDate
        let dateCandidatesAt: Int
        switch fixture.request {
        case .full(_, let insertionIndex?):
            dateCandidatesAt = insertionIndex
        case .full, .suggestion, .prefix:
            XCTFail("Relative-date fixture must define its dynamic date insertion index")
            return
        }
        let trigger = try XCTUnwrap(
            RelativeDateProvider.detectTrigger(composingHiragana: fixture.reading))
        var expectedCandidates = fixture.expectedCandidates
        expectedCandidates.insert(
            contentsOf: RelativeDateProvider.generateDateStrings(for: trigger),
            at: dateCandidatesAt)
        XCTAssertEqual(try candidates(for: fixture), expectedCandidates, fixture.name)
    }

    func testNonLearnableKanaNumberCommitClearsComposingText() throws {
        let fixture = CorpusFixtures.nonLearnableCommit
        let state = try makeState(for: fixture)
        let candidates = try candidates(from: state, for: fixture)
        XCTAssertEqual(candidates, fixture.expectedCandidates, fixture.name)
        let candidate = try XCTUnwrap(fixture.committedCandidate)
        let candidateIndex = try XCTUnwrap(candidates.firstIndex(of: candidate))
        XCTAssertEqual(state.completePrefix(candidateIndex: candidateIndex).status, .success)

        let response = state.getComposingString(charType: .hiragana, currentPreedit: "")
        XCTAssertEqual(response.status, .success)
        guard case .text(let composingText)? = response.payload else {
            XCTFail("Expected composing text response")
            return
        }
        XCTAssertEqual(composingText, fixture.expectedComposingTextAfterCommit)
    }

    private func assertCandidateParity(for fixture: CorpusFixture) throws {
        XCTAssertEqual(try candidates(for: fixture), fixture.expectedCandidates, fixture.name)
    }

    private func candidates(for fixture: CorpusFixture) throws -> [String] {
        let state = try makeState(for: fixture)
        return try candidates(from: state, for: fixture)
    }

    private func makeState(for fixture: CorpusFixture) throws -> HazkeyServerState {
        let state = HazkeyServerState()
        // config.swift:578 enables neural conversion when this remains true.
        state.serverConfig.currentProfile.zenzaiEnable = false
        if case .full(let numCandidatesPerPage, _) = fixture.request,
            let numCandidatesPerPage
        {
            state.serverConfig.currentProfile.numCandidatesPerPage = numCandidatesPerPage
        }
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in fixture.reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        if case .prefix(let cursorOffset) = fixture.request {
            XCTAssertEqual(state.moveCursor(offset: cursorOffset).status, .success)
        }
        return state
    }

    private func candidates(from state: HazkeyServerState, for fixture: CorpusFixture) throws -> [String] {
        let isSuggestion: Bool
        switch fixture.request {
        case .full(_, _), .prefix:
            isSuggestion = false
        case .suggestion:
            isSuggestion = true
        }
        let response = state.getCandidates(is_suggest: isSuggestion)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }
}

private enum EnvironmentError: Error {
    case missingPath(String)
    case setFailed(String)
    case unsetFailed(String)
}

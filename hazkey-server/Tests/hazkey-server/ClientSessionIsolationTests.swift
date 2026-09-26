import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// Multi-client session isolation tests.
///
/// One `HazkeySharedResources` (converter, config, user dictionary) backs two
/// `HazkeyServerState` connections. Each connection must keep its own
/// composing text and converter session: converting in one session must never
/// observe the other's uncommitted input, and closing one session must leave
/// the other fully functional.
final class ClientSessionIsolationTests: XCTestCase {
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
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey-community"), withIntermediateDirectories: true)

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

    /// Two states from one shared object hold distinct converter sessions
    /// while sharing the heavy converter and config instances.
    func testSessionsShareConverterButHoldDistinctSessionIDs() {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        let first = HazkeyServerState(shared: shared)
        let second = HazkeyServerState(shared: shared)
        defer {
            first.close()
            second.close()
        }

        XCTAssertNotEqual(first.conversionSessionID, second.conversionSessionID)
        XCTAssertTrue(first.converter === second.converter)
        XCTAssertTrue(first.serverConfig === second.serverConfig)
    }

    /// Composing "あい" in session A and "かき" in session B keeps each
    /// composing text local, and each session's candidates reflect its own
    /// input (distinct live texts).
    func testSessionsKeepIndependentComposingTextAndCandidates() throws {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = false
        let first = HazkeyServerState(shared: shared)
        let second = HazkeyServerState(shared: shared)
        defer {
            first.close()
            second.close()
        }

        XCTAssertEqual(first.createComposingTextInstanse().status, .success)
        for character in "あい" {
            XCTAssertEqual(first.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(second.createComposingTextInstanse().status, .success)
        for character in "かき" {
            XCTAssertEqual(second.inputChar(inputString: String(character)).status, .success)
        }

        XCTAssertEqual(first.composingText.value.toHiragana(), "あい")
        XCTAssertEqual(second.composingText.value.toHiragana(), "かき")

        let firstResponse = first.getCandidates(is_suggest: false)
        XCTAssertEqual(firstResponse.status, .success)
        let secondResponse = second.getCandidates(is_suggest: false)
        XCTAssertEqual(secondResponse.status, .success)
        guard case .candidates(let firstResult)? = firstResponse.payload,
            case .candidates(let secondResult)? = secondResponse.payload
        else {
            XCTFail("Expected candidates responses")
            return
        }
        // Each session converted its own input: the live texts are non-empty
        // and differ (あい vs かき convert differently). Crossed sessions
        // would produce identical live texts.
        XCTAssertFalse(firstResult.liveText.isEmpty)
        XCTAssertFalse(secondResult.liveText.isEmpty)
        XCTAssertNotEqual(firstResult.liveText, secondResult.liveText)
    }

    /// Closing one session leaves the other able to compose and convert with
    /// its own composing text intact.
    func testClosingOneSessionLeavesTheOtherFunctional() throws {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = false
        let first = HazkeyServerState(shared: shared)
        let drop = HazkeyServerState(shared: shared)
        defer {
            first.close()
            drop.close()
        }

        XCTAssertEqual(first.createComposingTextInstanse().status, .success)
        for character in "あい" {
            XCTAssertEqual(first.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(drop.createComposingTextInstanse().status, .success)
        for character in "かき" {
            XCTAssertEqual(drop.inputChar(inputString: String(character)).status, .success)
        }

        drop.close()

        // The surviving session keeps its own composing text and still
        // converts (the closed session's removal must not disturb it).
        XCTAssertEqual(first.composingText.value.toHiragana(), "あい")
        let response = first.getCandidates(is_suggest: true)
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(first.composingText.value.toHiragana(), "あい")
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        XCTAssertFalse(result.candidates.isEmpty)
    }
}

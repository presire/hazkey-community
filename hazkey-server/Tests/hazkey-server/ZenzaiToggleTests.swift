import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class ZenzaiToggleTests: XCTestCase {
    private var originalConfigHome: String?
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        originalConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-zenzai-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard setenv("XDG_CONFIG_HOME", directory.path, 1) == 0 else {
            throw ZenzaiToggleTestError.environmentUpdateFailed
        }
        temporaryDirectory = directory
    }

    override func tearDownWithError() throws {
        if let originalConfigHome {
            guard setenv("XDG_CONFIG_HOME", originalConfigHome, 1) == 0 else {
                throw ZenzaiToggleTestError.environmentUpdateFailed
            }
        } else {
            guard unsetenv("XDG_CONFIG_HOME") == 0 else {
                throw ZenzaiToggleTestError.environmentUpdateFailed
            }
        }
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testToggleZenzaiPersistsActiveProfileAndChangesGeneratedMode() throws {
        // Given: an active profile with Zenzai enabled and an available model.
        let config = HazkeyServerConfig()
        config.zenzaiAvailable = true
        config.zenzaiModelPath = temporaryDirectory?.appendingPathComponent("model.gguf")
        XCTAssertTrue(config.currentProfile.zenzaiEnable)
        if case .off = config.genZenzaiMode(leftContext: "") {
            XCTFail("Expected Zenzai mode to start enabled")
            return
        }

        // When: the dedicated toggle operation is invoked.
        let response = config.toggleZenzai()

        // Then: the returned state, next generated mode, and persisted profile are disabled.
        XCTAssertEqual(response.status, .success)
        XCTAssertFalse(response.toggleZenzaiResult.enabled)
        guard case .off = config.genZenzaiMode(leftContext: "") else {
            XCTFail("Expected the next Zenzai mode to be disabled")
            return
        }
        XCTAssertFalse(try XCTUnwrap(HazkeyServerConfig.loadConfig().first).zenzaiEnable)
    }

    func testToggleZenzaiRPCPreservesCompositionAndCandidateState() throws {
        // Given: an in-progress composition and an existing candidate list.
        let state = HazkeyServerState()
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        state.currentCandidateList = [.fromUserDict(word: "sentinel")]
        let composingBefore = state.getComposingString(charType: .hiragana, currentPreedit: "").text
        let tableBefore = state.currentTableName
        let handler = ProtocolHandler(state: state)
        let request = Hazkey_RequestEnvelope.with {
            $0.toggleZenzai = Hazkey_Commands_ToggleZenzai()
        }

        // When: the lightweight toggle RPC is dispatched.
        let response = try Hazkey_ResponseEnvelope(
            serializedBytes: handler.processProto(data: try request.serializedData()))

        // Then: only Zenzai enablement changes; composition and candidates remain valid.
        XCTAssertEqual(response.status, .success)
        XCTAssertFalse(response.toggleZenzaiResult.enabled)
        XCTAssertEqual(
            state.getComposingString(charType: .hiragana, currentPreedit: "").text,
            composingBefore)
        XCTAssertEqual(state.currentTableName, tableBefore)
        guard case .fromUserDict(let word)? = state.currentCandidateList?.first else {
            XCTFail("Expected the existing candidate state to remain")
            return
        }
        XCTAssertEqual(word, "sentinel")
    }
}

private enum ZenzaiToggleTestError: Error {
    case environmentUpdateFailed
}

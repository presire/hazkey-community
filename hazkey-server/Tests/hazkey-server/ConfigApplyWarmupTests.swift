import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// [community] The config-apply warm-up is a fire-and-forget side effect of the
/// `setConfig` RPC: it must run the neural model load, but a failed load must
/// never turn the RPC itself into a failure (the settings dialog already
/// reports model-load errors through the dedicated `reloadZenzaiModel` RPC).
final class ConfigApplyWarmupTests: XCTestCase {
    private var originalConfigHome: String?
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        originalConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-config-warmup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard setenv("XDG_CONFIG_HOME", directory.path, 1) == 0 else {
            throw ConfigApplyWarmupTestError.environmentUpdateFailed
        }
        temporaryDirectory = directory
    }

    override func tearDownWithError() throws {
        if let originalConfigHome {
            guard setenv("XDG_CONFIG_HOME", originalConfigHome, 1) == 0 else {
                throw ConfigApplyWarmupTestError.environmentUpdateFailed
            }
        } else {
            guard unsetenv("XDG_CONFIG_HOME") == 0 else {
                throw ConfigApplyWarmupTestError.environmentUpdateFailed
            }
        }
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSetConfigTriggersWarmupAttemptWithInvalidWeight() throws {
        // Given: a setConfig request whose profile points Zenzai at a file that is not a GGUF model.
        let state = HazkeyServerState()
        try XCTSkipUnless(
            !state.serverConfig.ggmlBackendDevices.isEmpty,
            "A Zenzai backend is required to exercise model loading")
        let invalidWeight = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-invalid-zenzai-\(UUID().uuidString).gguf")
        try Data("not a GGUF model".utf8).write(to: invalidWeight)
        defer { try? FileManager.default.removeItem(at: invalidWeight) }
        state.serverConfig.currentProfile.zenzaiEnable = true
        state.serverConfig.currentProfile.useZenzaiCustomWeight = true
        state.serverConfig.currentProfile.zenzaiWeightPath = invalidWeight.path
        XCTAssertEqual(state.converter.zenzStatus, "")

        // When: the configuration is applied over the RPC.
        let response = try setConfig(using: state)

        // Then: the warm-up ran (the converter recorded the attempted load) but
        // its failure did not fail the RPC that persisted the configuration.
        XCTAssertEqual(response.status, .success)
        XCTAssertTrue(state.converter.zenzStatus.hasPrefix("load "))
        XCTAssertTrue(state.converter.zenzStatus.contains(invalidWeight.path))
    }

    func testSetConfigWithDisabledZenzaiDoesNotForceInference() throws {
        // Given: a setConfig request whose profile disables Zenzai.
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        let statusBefore = state.converter.zenzStatus

        // When: the configuration is applied over the RPC.
        let response = try setConfig(using: state)

        // Then: no warm-up was forced and the converter status is untouched.
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(state.converter.zenzStatus, statusBefore)
    }

    private func setConfig(using state: HazkeyServerState) throws -> Hazkey_ResponseEnvelope {
        let handler = ProtocolHandler(state: state)
        let request = Hazkey_RequestEnvelope.with {
            $0.setConfig = Hazkey_Config_SetConfig.with {
                $0.profiles = [state.serverConfig.currentProfile]
            }
        }
        return try Hazkey_ResponseEnvelope(
            serializedBytes: handler.processProto(data: try request.serializedData()))
    }
}

private enum ConfigApplyWarmupTestError: Error {
    case environmentUpdateFailed
}

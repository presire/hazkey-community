import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class ConfigRevisionTests: XCTestCase {
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

    func testSaveConfigBumpsRevisionButGetConfigDoesNot() throws {
        // Given: a freshly loaded server configuration.
        let config = HazkeyServerConfig()
        XCTAssertEqual(config.configRevision, 0)

        // When: the settings are applied twice.
        let profile = HazkeyServerConfig.genDefaultConfig()
        try config.saveConfig([profile])
        XCTAssertEqual(config.configRevision, 1)

        // Then: a read does not bump it, and the next apply does.
        _ = config.getCurrentConfig()
        XCTAssertEqual(config.configRevision, 1)

        try config.saveConfig([profile])
        XCTAssertEqual(config.configRevision, 2)
    }

    func testResponseCarriesConfigRevision() throws {
        // Given: a server state and a dispatcher.
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        let state = HazkeyServerState(shared: shared)
        let handler = ProtocolHandler(state: state)
        var request = Hazkey_RequestEnvelope()
        request.getConfig = Hazkey_Config_GetConfig()

        // When: a request is handled before and after an apply.
        let before = try Hazkey_ResponseEnvelope(
            serializedBytes: handler.processProto(data: try request.serializedData()))
        try state.serverConfig.saveConfig([HazkeyServerConfig.genDefaultConfig()])
        let after = try Hazkey_ResponseEnvelope(
            serializedBytes: handler.processProto(data: try request.serializedData()))

        // Then: the revision is carried on the wire and advances.
        XCTAssertEqual(before.configRevision, 0)
        XCTAssertEqual(after.configRevision, 1)
    }
}

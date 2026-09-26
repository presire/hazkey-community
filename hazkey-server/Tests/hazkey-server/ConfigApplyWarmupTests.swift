import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 設定適用時のウォームアップは、"setConfig" RPCのfire-and-forgetな副作用である
/// ニューラルモデルのロードを実行する必要がある一方、ロード失敗によってRPC自体を失敗にしてはならない
/// モデルロードのエラーは、設定ダイアログが専用の"reloadZenzaiModel" RPC経由で報告する
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
        // 前提: ZenzaiにGGUFモデルではないファイルを指定するプロファイルを持つsetConfigリクエスト
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

        // 操作: RPC経由で設定を適用する
        let response = try setConfig(using: state)

        // 期待: ウォームアップが実行される (converterがロード試行を記録する) が、その失敗は設定を永続化するRPCを失敗にしない
        XCTAssertEqual(response.status, .success)
        XCTAssertTrue(state.converter.zenzStatus.hasPrefix("load "))
        XCTAssertTrue(state.converter.zenzStatus.contains(invalidWeight.path))
    }

    func testSetConfigWithDisabledZenzaiDoesNotForceInference() throws {
        // 前提: Zenzaiを無効化するプロファイルを持つsetConfigリクエスト
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        let statusBefore = state.converter.zenzStatus

        // 操作: RPC経由で設定を適用する
        let response = try setConfig(using: state)

        // 期待: ウォームアップは強制されず、converterの状態は変更されない
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

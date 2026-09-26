import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class ZenzaiReloadWarmupTests: XCTestCase {
    func testReloadZenzaiModelWithoutAvailableModelPreservesRequestingState() throws {
        // 前提: モデル解決に使えるバックエンドがなく、組成中のクライアント
        let state = HazkeyServerState()
        state.serverConfig.ggmlBackendDevices = []
        state.shared.learningDataNeedsCommit = true
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        state.currentCandidateList = [.fromUserDict(word: "sentinel")]
        let composingBefore = state.getComposingString(charType: .hiragana, currentPreedit: "").text

        // 操作: Settings が既存のRPC経由でサーバにZenzaiモデルの再ロードを要求する
        let response = try reloadZenzaiModel(using: state)

        // 期待: ウォームアップは不要で、クライアントローカル状態と学習状態は維持される
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(
            state.getComposingString(charType: .hiragana, currentPreedit: "").text,
            composingBefore)
        XCTAssertTrue(state.shared.learningDataNeedsCommit)
        guard case .fromUserDict(let word)? = state.currentCandidateList?.first else {
            XCTFail("Expected candidate state to remain")
            return
        }
        XCTAssertEqual(word, "sentinel")
    }

    func testReloadZenzaiModelWhenDisabledDoesNotForceInference() throws {
        // 前提: Zenzaiを無効化したプロファイルと、未変更のconverter状態
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        let statusBefore = state.converter.zenzStatus

        // 操作: モデルメタデータを再ロードする。
        let response = try reloadZenzaiModel(using: state)

        // 期待: 無効化されたZenzaiは、ウォームアップなしで成功する経路のままである
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(state.converter.zenzStatus, statusBefore)
    }

    func testReloadZenzaiModelReportsFailureWhenInvalidWeightCannotLoad() throws {
        // 前提: 利用可能なバックエンドと、GGUFモデルではない通常ファイル
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
        state.shared.learningDataNeedsCommit = true
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        state.currentCandidateList = [.fromUserDict(word: "sentinel")]
        let composingBefore = state.getComposingString(charType: .hiragana, currentPreedit: "").text

        // 操作: 再ロードが単一のウォームアップ要求を実行する
        let response = try reloadZenzaiModel(using: state)

        // 期待: converter のフォールバック候補は、未確認のモデルロードを隠してはならない
        XCTAssertEqual(response.status, .failed)
        XCTAssertTrue(response.errorMessage.hasPrefix("Zenzai model warmup failed:"))
        XCTAssertTrue(state.shared.learningDataNeedsCommit)
        XCTAssertEqual(
            state.getComposingString(charType: .hiragana, currentPreedit: "").text,
            composingBefore)
        guard case .fromUserDict(let word)? = state.currentCandidateList?.first else {
            XCTFail("Expected candidate state to remain")
            return
        }
        XCTAssertEqual(word, "sentinel")
    }

    private func reloadZenzaiModel(using state: HazkeyServerState) throws -> Hazkey_ResponseEnvelope {
        let handler = ProtocolHandler(state: state)
        let request = Hazkey_RequestEnvelope.with {
            $0.reloadZenzaiModel = Hazkey_Config_ReloadZenzaiModel()
        }
        return try Hazkey_ResponseEnvelope(
            serializedBytes: handler.processProto(data: try request.serializedData()))
    }
}

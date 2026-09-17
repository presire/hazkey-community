import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class ZenzaiReloadWarmupTests: XCTestCase {
    func testReloadZenzaiModelWithoutAvailableModelPreservesRequestingState() throws {
        // Given: a composing client with no backend available to resolve a model.
        let state = HazkeyServerState()
        state.serverConfig.ggmlBackendDevices = []
        state.shared.learningDataNeedsCommit = true
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        state.currentCandidateList = [.fromUserDict(word: "sentinel")]
        let composingBefore = state.getComposingString(charType: .hiragana, currentPreedit: "").text

        // When: Settings asks the server to reload the Zenzai model over the existing RPC.
        let response = try reloadZenzaiModel(using: state)

        // Then: no warmup is needed and the client-local and learning state survive.
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
        // Given: a disabled Zenzai profile and an untouched converter status.
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        let statusBefore = state.converter.zenzStatus

        // When: the model metadata is reloaded.
        let response = try reloadZenzaiModel(using: state)

        // Then: disabled Zenzai remains a successful no-warmup path.
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(state.converter.zenzStatus, statusBefore)
    }

    func testReloadZenzaiModelReportsFailureWhenInvalidWeightCannotLoad() throws {
        // Given: an available backend and a regular file that is not a GGUF model.
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

        // When: reload performs its single warmup request.
        let response = try reloadZenzaiModel(using: state)

        // Then: fallback converter candidates cannot mask an unconfirmed model load.
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

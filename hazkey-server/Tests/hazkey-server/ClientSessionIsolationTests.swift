import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 複数クライアント間のセッション分離テスト
///
/// 1つの"HazkeySharedResources"がconverter、設定、ユーザ辞書を共有しつつ、2つの"HazkeyServerState"接続を支える
/// 各接続はそれぞれのcomposing textとconverterセッションを維持しなければならない
/// 一方のセッションで変換しても、もう一方の未確定入力を観測してはならず、片方を閉じてももう片方は完全に動作し続けなければならない
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

    /// 1つの共有オブジェクトから作った2つのstateは、重いconverterと設定インスタンスを共有しながら、
    /// それぞれ別のconverterセッションを保持する
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

    /// セッションAで「あい」、セッションBで「かき」を組成しても、各composing textはローカルに保たれ、各セッションの候補は自身の入力を反映する
    /// live textも異なる
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
        // 各セッションは自身の入力を変換するため、live textは空でなく異なる
        // 「あい」と「かき」は異なる変換結果になる
        // セッションが混線すれば、live textは一致する
        XCTAssertFalse(firstResult.liveText.isEmpty)
        XCTAssertFalse(secondResult.liveText.isEmpty)
        XCTAssertNotEqual(firstResult.liveText, secondResult.liveText)
    }

    /// 一方のセッションを閉じても、もう一方は自身のcomposing textを保ったまま、組成と変換を続けられる
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

        // 残ったセッションは自身のcomposing textを保ったまま変換を続ける
        // 閉じたセッションの削除は、残ったセッションに影響してはならない
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

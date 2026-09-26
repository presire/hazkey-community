import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// サジェスト応答内の重複候補に対する回帰テスト
///
/// サジェストウィンドウ ("suggestionListMode = ShowPredictiveResults") は、"predictionResults"の後に"mainResults"を受け取る
/// 両配列には同じ表記が含まれ得る
/// 例えば、converterが自身の最良ノードの予測としても出力するユーザ辞書語等である
///
/// "makeCandidatesResult"は以前、配列間の重複排除をせずに連結していたため、同じ候補が候補ウィンドウに2回表示されていた
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
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        // "config/hazkey-community/"にはサーバが読むユーザ辞書TSVを置く
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

        // 実際のTSVパイプライン経由で衛宮 (えみや) を登録する
        // この語は自身の最良ノードの予測と変換候補の両方に現れ、報告された重複を再現する
        let tsv = root.appendingPathComponent("config/hazkey-community/user_dictionary.tsv")
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

        // 中核となる回帰確認
        // いかなる表記も複数回出現してはならない
        let duplicates = Dictionary(grouping: texts, by: { $0 }).mapValues(\.count)
            .filter { $0.value > 1 }
        XCTAssertTrue(
            duplicates.isEmpty,
            "duplicate candidates in suggestion response: \(duplicates)")
        XCTAssertTrue(
            texts.contains("衛宮"),
            "user dictionary entry missing from suggestion response: \(texts)")

        // ライブテキストは同じ文字列を持つ可視エントリを指し続けなければならない
        // "index == texts.count"は、非表示エントリのケースを表す
        let liveIndex = Int(result.liveTextIndex)
        if liveIndex >= 0 && liveIndex < texts.count {
            XCTAssertEqual(texts[liveIndex], result.liveText)
        }
    }
}

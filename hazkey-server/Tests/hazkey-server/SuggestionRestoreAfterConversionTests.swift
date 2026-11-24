import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// [Space]で通常変換した後に[Esc]でサジェストへ戻したときの予測候補の復元を検証する回帰テスト
///
/// [提案リストのモード]が予測変換の時、サジェストは1打鍵ごとの予測候補を表示する
///
/// [Space]は同じ読みを通常変換へ切り替えるため、サーバは変換エンジンへ予測なしの要求 (requireJapanesePredictionがdisabled) を渡す
///
/// 変換エンジンがこの要求でセッションの予測候補のキャッシュを消すと、続く[Esc]のサジェスト要求で[Space]の前の予測候補が戻らない
final class SuggestionRestoreAfterConversionTests: XCTestCase {
    /// テストごとに復元する環境変数
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
    ]

    /// テスト開始前の環境変数の値
    private var originalEnvironment: [String: String?] = [:]

    /// テスト用の一時ディレクトリ
    private var temporaryDirectory: URL?

    /// テストのセットアップに失敗した理由
    private enum SetupError: Error {
        /// 環境変数を設定できなかった
        case setFailed(String)

        /// 一時ディレクトリのパスを解決できなかった
        case missingPath(String)
    }

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey-community"),
            withIntermediateDirectories: true
        )

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

    /// [Space]の前後でサジェスト候補が同じ並びで復元されることを検証する
    ///
    /// 読みを1文字ずつ入力し、各打鍵でサジェストを要求したときの最後の候補一覧を記録する
    ///
    /// 続いて[Space]相当の通常変換と[Esc]相当のサジェスト要求を行い、記録した一覧との一致を確かめる
    ///
    /// "ちゅうしゃじょう"では、打鍵ごとの要求でだけ現れる予測候補 ("駐車上記") があることを前提として検査する
    ///
    /// "駐車上記"は、"ちゅうしゃじょ"の打鍵で作られた予測候補のキャッシュから持ち越されるため、辞書が変わると前提が崩れる
    ///
    /// "ぽけもん"の予測候補はキャッシュに依存しないため、同じ比較だけで復元を検査する
    func testEscapeAfterSpaceRestoresSuggestionList() {
        assertSuggestionListRestored(
            for: "ちゅうしゃじょう",
            requiringCacheDependentPrediction: "駐車上記"
        )
        assertSuggestionListRestored(for: "ぽけもん", requiringCacheDependentPrediction: nil)
    }

    /// 未確定のローマ字の末尾を[Space]で確定した後も、予測候補が読みと矛盾しないことを検証する
    ///
    /// "kan"を1キーずつ入力すると、組成の末尾に未確定の"n"が残る (かn)
    ///
    /// "かn"の予測候補には、"n"の続きを"な"・"の"等と見た語 ("可能"・"かなり") が入る
    ///
    /// 通常変換は文節区切りを入れて、"n"を"ん"へ確定するため、続くサジェスト要求の読みは"かん"になる
    ///
    /// キャッシュを残しても、"かん"と矛盾する予測候補 ("可能"・"かなり") は返らないことを確かめる
    func testEscapeAfterSpaceWithPendingRomanSuffixKeepsPredictionsConsistent() {
        let state = makeState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)

        var beforeSpace: [String] = []
        for character in "kan" {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
            beforeSpace = candidates(state, isSuggest: true).map(\.text)
        }
        // 前提: [Space]の前の予測候補に、確定後の読み"かん"と合わない語がある
        let inconsistentWithKan = ["可能", "かなり"]
        for text in inconsistentWithKan {
            XCTAssertTrue(beforeSpace.contains(text), "前提が崩れている: かn のサジェストに \(text) が無い")
        }

        _ = candidates(state, isSuggest: false)
        let restored = candidates(state, isSuggest: true).map(\.text)

        XCTAssertFalse(restored.isEmpty, "[Esc]のサジェストに候補が無い")
        for text in inconsistentWithKan {
            XCTAssertFalse(restored.contains(text), "確定後の読み かん と矛盾する予測候補: \(text)")
        }
    }

    /// 指定した読みで[Space]の前後を比較し、サジェスト一覧が復元されることを検証する
    ///
    /// - Parameters:
    ///   - reading: 入力する読み
    ///   - expectedPrediction: 途中の打鍵でだけ現れる予測候補
    private func assertSuggestionListRestored(
        for reading: String,
        requiringCacheDependentPrediction expectedPrediction: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let state = makeState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success, file: file, line: line)

        var beforeSpace: [String] = []
        for character in reading {
            XCTAssertEqual(
                state.inputChar(inputString: String(character)).status,
                .success,
                file: file,
                line: line
            )
            beforeSpace = candidates(state, isSuggest: true, file: file, line: line).map(\.text)
        }

        if let expectedPrediction {
            XCTAssertTrue(
                beforeSpace.contains(expectedPrediction),
                "前提が崩れている: 打鍵ごとのサジェストに \(expectedPrediction) が無い",
                file: file,
                line: line
            )

            // 打鍵ごとの予測キャッシュが無い一括変換では、同じ語が現れないことを確かめる
            let control = makeState()
            XCTAssertEqual(
                control.createComposingTextInstanse().status,
                .success,
                file: file,
                line: line
            )
            for character in reading {
                XCTAssertEqual(
                    control.inputChar(inputString: String(character)).status,
                    .success,
                    file: file,
                    line: line
                )
            }
            let controlTexts = candidates(control, isSuggest: true, file: file, line: line).map(\.text)
            XCTAssertFalse(
                controlTexts.contains(expectedPrediction),
                "前提が崩れている: 打鍵ごとの要求が無い一括変換にも \(expectedPrediction) が現れる",
                file: file,
                line: line
            )
        }

        _ = candidates(state, isSuggest: false, file: file, line: line)
        let afterSpace = candidates(state, isSuggest: true, file: file, line: line).map(\.text)
        XCTAssertEqual(
            afterSpace,
            beforeSpace,
            "[Space]後の[Esc]でサジェスト候補の並びが変化している",
            file: file,
            line: line
        )
    }

    /// テスト用のプロファイルでサーバ状態を作る
    ///
    /// - Returns: 新しい接続セッションのサーバ状態
    private func makeState() -> HazkeyServerState {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.numSuggestions = 10
        state.serverConfig.currentProfile.numCandidatesPerPage = 10
        state.serverConfig.currentProfile.suggestionListMode =
            .suggestionListShowPredictiveResults
        return state
    }

    /// 候補要求を送り、返ってきた候補を返す
    ///
    /// - Parameters:
    ///   - state: 候補を要求するサーバ状態
    ///   - isSuggest: サジェストを要求するか
    /// - Returns: サーバが返した候補
    private func candidates(
        _ state: HazkeyServerState,
        isSuggest: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Hazkey_Commands_CandidatesResult.Candidate] {
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success, file: file, line: line)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("候補応答を取得できませんでした", file: file, line: line)
            return []
        }
        return result.candidates
    }
}

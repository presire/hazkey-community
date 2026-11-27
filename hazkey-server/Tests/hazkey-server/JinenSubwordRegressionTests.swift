import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// Jinen v2のサブワード整合と空白入力と空文脈プロンプトの実モデル回帰テスト
///
/// 環境変数HAZKEY_JINEN_MODELが空でない実在のモデルファイルを指すときだけ実行されるオプトインのテスト群
///
/// F1の学習語のサブワード位置ずれと、F3の空白を含む入力のトークナイズ、F6の空左文脈のプロンプトを実モデルで検証する
///
/// モデルはCPU固定で読み込み、学習・設定・辞書・キャッシュの保存先は一時ディレクトリへ隔離する
///
/// - Note: 対象モデルは環境変数HAZKEY_JINEN_MODELで受け取る
final class JinenSubwordRegressionTests: XCTestCase {
    /// 検証対象のモデルを環境変数から解決する
    ///
    /// 未設定・空・実在しないパスの場合は実行せずにスキップする
    ///
    /// - Returns: 実体へ解決済みのモデルURL
    /// - Throws: スキップの通知
    private func jinenModelURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment["HAZKEY_JINEN_MODEL"] ?? ""
        try XCTSkipUnless(
            !path.isEmpty,
            "Set HAZKEY_JINEN_MODEL to a Jinen v2 model file to run the real-model regression tests")
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        try XCTSkipUnless(
            exists && !isDirectory.boolValue,
            "HAZKEY_JINEN_MODEL must point to an existing model file")
        return url
    }

    /// モデルを読み込めなかったことを表すエラー
    private struct ModelLoadFailure: Error, CustomStringConvertible {
        /// 失敗の説明
        let description: String
    }

    /// 一時ディレクトリ上に、学習・設定・辞書・キャッシュの保存先を隔離した環境を作って渡す
    ///
    /// 環境変数を差し替えてからbodyを実行し、終了後は元の値へ戻して一時ディレクトリを削除する
    ///
    /// - Parameter body: 隔離したルートURLを受け取り、テスト本体を実行するクロージャ
    /// - Throws: 一時領域の作成失敗やbodyが投げるエラー
    private func withIsolatedRoot(_ body: (URL) throws -> Void) throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment: [String: String] = [:]
        for (variable, directory) in [
            "XDG_DATA_HOME": "data", "XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime", "XDG_STATE_HOME": "state",
        ] {
            let path = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            environment[variable] = path.path
        }
        environment["HAZKEY_DICTIONARY"] = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        environment["HAZKEY_ZENZAI_DEADLINE_MS"] = "0"
        let original = ProcessInfo.processInfo.environment
        defer {
            for variable in environment.keys {
                if let value = original[variable] { setenv(variable, value, 1) }
                else { unsetenv(variable) }
            }
        }
        for (variable, value) in environment { XCTAssertEqual(setenv(variable, value, 1), 0) }
        try body(root)
    }

    /// 隔離環境上にJinen v2を使う接続状態を作る
    ///
    /// モデルはCPU固定で読み込み、読み込みとウォームアップの成功を確認する
    ///
    /// - Parameters:
    ///   - modelURL: 実体へ解決済みのモデルURL
    ///   - useInputHistory: 入力履歴を使う場合はtrue
    ///   - useUserDictionary: ユーザ辞書を使う場合はtrue
    ///   - useTypoCorrection: 誤字訂正を使う場合はtrue
    ///   - zenzaiContextualMode: 文脈変換を使う場合はtrue
    /// - Returns: 作成した接続状態
    /// - Throws: モデルを読み込めなかった場合のModelLoadFailure
    private func makeState(
        modelURL: URL,
        useInputHistory: Bool,
        useUserDictionary: Bool = false,
        useTypoCorrection: Bool = false,
        zenzaiContextualMode: Bool = true
    ) throws -> HazkeyServerState {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = true
        state.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        state.serverConfig.currentProfile.zenzaiContextualMode = zenzaiContextualMode
        state.serverConfig.currentProfile.useInputHistory = useInputHistory
        state.serverConfig.currentProfile.stopStoreNewHistory = false
        state.serverConfig.currentProfile.useUserDictionary = useUserDictionary
        state.serverConfig.currentProfile.useTypoCorrection = useTypoCorrection
        state.serverConfig.currentProfile.useZenzaiCustomWeight = true
        state.serverConfig.currentProfile.zenzaiWeightPath = modelURL.path
        state.baseConvertRequestOptions = state.serverConfig.genBaseConvertRequestOptions()
        let reload = state.reloadZenzaiModel()
        guard reload.status == .success, state.serverConfig.zenzaiAvailable else {
            state.close()
            throw ModelLoadFailure(description: "Jinen model failed to load: \(reload.errorMessage)")
        }
        return state
    }

    /// 組成を作り直し、左文脈を設定してから読みを1文字ずつ入力する
    ///
    /// 組成の作り直しは左文脈を消去するため、左文脈は作り直しの直後かつ文字の入力前に設定する
    ///
    /// - Parameters:
    ///   - reading: 入力する読み
    ///   - leftContext: 左文脈 (空の場合は設定しない)
    ///   - state: 処理を受け持つ接続状態
    private func typeReading(_ reading: String, leftContext: String, into state: HazkeyServerState) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        if !leftContext.isEmpty {
            XCTAssertEqual(
                state.setContext(
                    surroundingText: leftContext,
                    anchorIndex: leftContext.unicodeScalars.count
                ).status,
                .success)
        }
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
    }

    /// 現在の候補リストから変換エンジン由来の表記を入力順に抜き出す
    ///
    /// - Parameter state: 処理を受け持つ接続状態
    /// - Returns: 変換エンジン由来の表記
    private func converterTexts(in state: HazkeyServerState) -> [String] {
        (state.currentCandidateList ?? []).compactMap { entry in
            if case .fromConverter(let candidate) = entry { return candidate.text }
            return nil
        }
    }

    /// 文字列がJinenのプロンプト制御トークンを含むかを返す
    ///
    /// - Parameter text: 検査する文字列
    /// - Returns: U+EE00・U+EE01・U+EE02のいずれかを含む場合はtrue
    private func containsPromptControlToken(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0.value == 0xEE00 || $0.value == 0xEE01 || $0.value == 0xEE02
        }
    }

    /// 変換の応答が成功し、空でない候補を返して制御トークンを含まないことを確認する
    ///
    /// - Parameters:
    ///   - response: 候補要求の応答
    ///   - state: 処理を受け持つ接続状態
    private func assertHealthyCandidates(
        _ response: Hazkey_ResponseEnvelope, in state: HazkeyServerState
    ) {
        XCTAssertEqual(response.status, .success)
        for text in response.candidates.candidates.map(\.text) {
            XCTAssertFalse(
                containsPromptControlToken(text), "prompt control token leaked into \(text)")
        }
        let texts = converterTexts(in: state)
        XCTAssertGreaterThanOrEqual(texts.count, 1, "the converter must return at least one candidate")
        XCTAssertTrue(texts.contains { !$0.isEmpty }, "the converter must return a non-empty candidate")
    }

    // F1: サブワードが学習語と前の語をまたいでも、学習語の加点が位置ずれしないことを確認する
    func testOptInJinenLearnedWordWorksAfterSubwordMerge() throws {
        let modelURL = try jinenModelURL()
        try withIsolatedRoot { _ in
            var state = try makeState(modelURL: modelURL, useInputHistory: true)
            defer { state.close() }

            // こうえん を変換して 公演 を確定し、未保存の一時学習を作る
            typeReading("こうえん", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            guard
                let targetIndex = state.currentCandidateList?.firstIndex(where: { entry in
                    if case .fromConverter(let candidate) = entry { return candidate.text == "公演" }
                    return false
                })
            else {
                return XCTFail("公演 must be a candidate for こうえん: \(converterTexts(in: state))")
            }
            guard case .fromConverter(let learnedCandidate) = (state.currentCandidateList ?? [])[targetIndex]
            else {
                return XCTFail("公演 must come from the converter")
            }
            let learnedWords = learnedCandidate.data.map {
                LearningSurfaceKey(reading: $0.ruby, word: $0.word)
            }
            XCTAssertEqual(state.completePrefix(candidateIndex: targetIndex).status, .success)

            // 未保存の学習: の公演 の静的連語を避けて学習語 (公演) が評価される経路 (suggest -> nonSuggest) で、
            // 日本語の のサブワード結合後も学習語が先頭に残る
            typeReading("にほんごのこうえん", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: true).status, .success)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            XCTAssertEqual(converterTexts(in: state).first, "日本語の公演")

            // 学習を保存して、ディスクへコミットできたことを確認する
            XCTAssertEqual(state.saveLearningData().status, .success)
            let persistedKeys =
                (try? state.shared.learningSurfaceKeys(forReadings: learnedWords.map(\.reading))) ?? []
            XCTAssertGreaterThan(
                learnedWords.filter { persistedKeys.contains($0) }.count, 0,
                "the learned word must be persisted")

            // 保存直後の新しい組成: ライブ変換後の通常変換で学習語が先頭に残る
            typeReading("にほんごのこうえん", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: true).status, .success)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            XCTAssertEqual(converterTexts(in: state).first, "日本語の公演")

            // 変換エンジンを作り直して、保存した学習が読み込まれても同様に先頭へ残ることを確認する
            state.close()
            state = try makeState(modelURL: modelURL, useInputHistory: true)
            typeReading("にほんごのこうえん", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: true).status, .success)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            XCTAssertEqual(converterTexts(in: state).first, "日本語の公演")
        }
    }

    // F3: 半角空白を含む左文脈と組成が、トークナイズの破綻や制御トークンの混入を起こさないことを確認する
    func testOptInJinenSpaceInputDoesNotCorruptTokenization() throws {
        let modelURL = try jinenModelURL()
        try withIsolatedRoot { _ in
            let state = try makeState(modelURL: modelURL, useInputHistory: false)
            defer { state.close() }

            // 左文脈の半角空白は、プロンプトのトークン数を見積もりより増やす
            typeReading("てんき", leftContext: "A B ", into: state)
            assertHealthyCandidates(state.getCandidates(is_suggest: false), in: state)

            // 半角空白キーはキーマップで全角スペースになり、組成に入る
            XCTAssertEqual(state.createComposingTextInstanse().status, .success)
            XCTAssertEqual(state.inputChar(inputString: " ").status, .success)
            for character in "てんき" {
                XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
            }
            assertHealthyCandidates(state.getCandidates(is_suggest: false), in: state)

            // 直接入力の英字と半角空白を含む組成は、評価対象の表記に半角空白を残す
            XCTAssertEqual(state.createComposingTextInstanse().status, .success)
            state.isSubInputMode = true
            for character in "hello " {
                XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
            }
            state.isSubInputMode = false
            for character in "てんき" {
                XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
            }
            assertHealthyCandidates(state.getCandidates(is_suggest: false), in: state)
        }
    }

    // F6: 空左文脈の評価プロンプトが、既知の誤変換を再発させないことを確認する
    func testOptInJinenEmptyContextPromptAvoidsKnownRegressions() throws {
        let modelURL = try jinenModelURL()
        try withIsolatedRoot { _ in
            let state = try makeState(
                modelURL: modelURL, useInputHistory: false, useUserDictionary: false,
                useTypoCorrection: false)
            defer { state.close() }

            typeReading("きょうはいいてん", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            let first = converterTexts(in: state).first ?? ""
            XCTAssertFalse(first.isEmpty)
            XCTAssertNotEqual(first, "狂俳医典")

            typeReading("わたしのなまえはたなかたろ", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            let second = converterTexts(in: state).first ?? ""
            XCTAssertNotEqual(second, "私の名前畠中たろ")
            XCTAssertTrue(second.contains("私の名前は田中"), "unexpected conversion: \(second)")

            typeReading("しょうゆをかってきてください", leftContext: "", into: state)
            XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
            XCTAssertEqual(converterTexts(in: state).first, "醤油を買ってきてください")
        }
    }
}

import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 読みの末尾に未確定のローマ字が残る入力に対する、ユーザ辞書の回帰テスト
///
/// "ban"と入力すると、読みは"ばn"となり、末尾のnは"ん"あるいは"な"等のどれになるか未確定のまま残る
/// 以前は、"ん"で終わる読みで登録した語が"bann"では候補に出るが、"ban"では出なかった
///
/// 変換エンジンの予測候補の生成で、
/// システム辞書は末尾のローマ字を展開した読み ("ばん"、"ばな"等) で引く一方、動的ユーザ辞書は"ばn"のまま前方一致させていたためである
///
/// - Note: 修正はAzooKeyConverterフォーク (presire/AzooKeyKanaKanjiConverter、hazkeyブランチ、コミットID: 7d38b85) の
///         Kana2Kanji.getPredictionCandidatesにあり、フォーク側のテストはHazkeyTrailingRomanUserDictionaryTests.swiftにある
final class UserDictionaryTrailingRomanTests: XCTestCase {
    /// テスト中に差し替え、終了時に元へ戻す環境変数の一覧
    ///
    /// XDG系の変数で設定・学習データの保存先を一時ディレクトリへ隔離し、HAZKEY_DICTIONARYでシステム辞書の場所を指定する
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
    ]
    /// 差し替える前の環境変数の値 (未設定の変数はnil)
    private var originalEnvironment: [String: String?] = [:]
    /// テストごとに作成する一時ディレクトリ (終了時に削除する)
    private var temporaryDirectory: URL?

    /// テスト環境の準備に失敗した場合のエラー
    private enum SetupError: Error {
        /// setenvによる環境変数の設定に失敗した (関連値は変数名)
        case setFailed(String)
        /// 環境変数に対応する一時ディレクトリ名が定義されていない (関連値は変数名)
        case missingPath(String)
    }

    /// 一時ディレクトリと環境変数を準備し、ユーザ辞書を書き出す
    ///
    /// ユーザ辞書には、読み「ばん」「らん」「ばんぐみ」の語を登録する
    ///
    /// 「登録番組」は「ばn」から予測候補として出ることを確かめるための語である
    ///
    /// - Throws: ディレクトリの作成、環境変数の設定、ユーザ辞書の書き込みに失敗した場合
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

        // 列は読み、表記、コメント、品詞の順 (user_dictionary.tsvの形式)
        let tsv = root.appendingPathComponent("config/hazkey-community/user_dictionary.tsv")
        try """
            ばん\t登録版\tregression test\tnoun
            らん\t登録蘭\tregression test\tnoun
            ばんぐみ\t登録番組\tregression test\tnoun

            """
            .write(to: tsv, atomically: true, encoding: .utf8)
    }

    /// 環境変数を元に戻し、一時ディレクトリを削除する
    ///
    /// - Note: 一時ディレクトリの削除に失敗しても、テストは失敗させない
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

    /// 予測候補を表示する設定で、新しい組成を開始した接続を作成する
    ///
    /// ニューラル変換 (Zenzai) は無効にし、変換エンジンの辞書だけで候補を作る
    ///
    /// - Returns: 組成を開始済みの接続の状態
    private func makeState() -> HazkeyServerState {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.numSuggestions = 10
        state.serverConfig.currentProfile.numCandidatesPerPage = 10
        state.serverConfig.currentProfile.suggestionListMode =
            .suggestionListShowPredictiveResults
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        return state
    }

    /// ローマ字を1文字ずつ入力する
    ///
    /// - Parameters:
    ///   - romaji: 入力するローマ字の文字列
    ///   - state: 入力先の接続の状態
    private func type(_ romaji: String, into state: HazkeyServerState) {
        for character in romaji {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
    }

    /// 新しい接続でローマ字を入力し、候補の表記を取得する
    ///
    /// - Parameters:
    ///   - romaji: 入力するローマ字の文字列
    ///   - isSuggest: trueの場合はサジェスト (ライブ変換)、falseの場合は通常の変換として候補を要求する
    /// - Returns: 候補の表記の一覧 (候補リストの順)
    private func candidateTexts(typing romaji: String, isSuggest: Bool) -> [String] {
        let state = makeState()
        type(romaji, into: state)
        return requestCandidateTexts(state: state, isSuggest: isSuggest)
    }

    /// 現在の組成で候補を要求し、表記の一覧を取得する
    ///
    /// - Parameters:
    ///   - state: 候補を要求する接続の状態
    ///   - isSuggest: trueの場合はサジェスト (ライブ変換)、falseの場合は通常の変換として候補を要求する
    /// - Returns: 候補の表記の一覧 (応答が候補でない場合は空)
    private func requestCandidateTexts(state: HazkeyServerState, isSuggest: Bool) -> [String] {
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }

    /// 末尾のnが1つの「ban」「ran」でも、サジェストにユーザ辞書の語が出る
    ///
    /// 修正前は、読み「ばん」「らん」で登録した語が出なかった
    func testSuggestionListShowsUserDictionaryWordForSingleTrailingN() {
        let ban = candidateTexts(typing: "ban", isSuggest: true)
        XCTAssertTrue(ban.contains("登録版"), "user dictionary entry missing for ban: \(ban)")
        let ran = candidateTexts(typing: "ran", isSuggest: true)
        XCTAssertTrue(ran.contains("登録蘭"), "user dictionary entry missing for ran: \(ran)")
    }

    /// 末尾のnが1つの「ban」でも、通常の変換 ([Space]での変換) にユーザ辞書の語が出る
    func testConversionShowsUserDictionaryWordForSingleTrailingN() {
        let ban = candidateTexts(typing: "ban", isSuggest: false)
        XCTAssertTrue(ban.contains("登録版"), "user dictionary entry missing for ban: \(ban)")
    }

    /// 「bann」と入力した場合も、従来通りサジェストにユーザ辞書の語が出る
    func testSuggestionListKeepsUserDictionaryWordForDoubleN() {
        let bann = candidateTexts(typing: "bann", isSuggest: true)
        XCTAssertTrue(bann.contains("登録版"), "user dictionary entry missing for bann: \(bann)")
    }

    /// 1文字ごとにサジェストを要求しても、ユーザ辞書の語が重複せずに1回だけ出る
    ///
    /// 実際の打鍵と同じく、1つの接続で「b」「ba」「ban」「bann」の順に候補を要求する
    ///
    /// どの段階でも候補の表記が重複せず、「ban」と「bann」では「登録版」がちょうど1回出ることを確かめる
    func testPerKeystrokeSuggestionsShowUserDictionaryWordOnceFromSingleTrailingN() {
        let state = makeState()
        var textsByInput: [String: [String]] = [:]
        for (index, character) in "bann".enumerated() {
            type(String(character), into: state)
            textsByInput[String("bann".prefix(index + 1))] = requestCandidateTexts(
                state: state, isSuggest: true)
        }

        for (input, texts) in textsByInput {
            let duplicates = Dictionary(grouping: texts, by: { $0 }).mapValues(\.count)
                .filter { $0.value > 1 }
            XCTAssertTrue(duplicates.isEmpty, "duplicate candidates for \(input): \(duplicates)")
        }
        for input in ["ban", "bann"] {
            let texts = textsByInput[input] ?? []
            XCTAssertEqual(
                texts.filter { $0 == "登録版" }.count, 1,
                "user dictionary entry must appear exactly once for \(input): \(texts)")
        }
    }

    /// 「ban」で予測候補の「登録番組」を受け入れると、組成が「ばんぐみ」に伸びる
    ///
    /// 末尾の未確定のnは捨てられ、候補の読みの残りが組成に追加される
    ///
    /// - Throws: 予測候補が候補リストに無い場合
    func testAcceptingPredictedUserDictionaryWordFromSingleTrailingNGrowsComposingText() throws {
        let state = makeState()
        type("ban", into: state)
        let texts = requestCandidateTexts(state: state, isSuggest: true)
        let index = try XCTUnwrap(
            state.currentCandidateList?.firstIndex(where: { entry in
                if case .fromConverter(let candidate) = entry { return candidate.text == "登録番組" }
                return false
            }),
            "predicted user dictionary entry missing for ban: \(texts)")

        XCTAssertEqual(state.acceptPrediction(candidateIndex: index).status, .success)
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "ばんぐみ")
    }

    /// 「ban」で「登録版」を確定すると、組成が空になる
    ///
    /// 末尾の未確定のnを含む読み全体を消費し、組成に余りを残さない
    ///
    /// - Throws: ユーザ辞書の語が候補リストに無い場合
    func testCommittingUserDictionaryWordFromSingleTrailingNConsumesWholeReading() throws {
        let state = makeState()
        type("ban", into: state)
        let texts = requestCandidateTexts(state: state, isSuggest: true)
        let index = try XCTUnwrap(
            state.currentCandidateList?.firstIndex(where: { entry in
                if case .fromConverter(let candidate) = entry { return candidate.text == "登録版" }
                return false
            }),
            "user dictionary entry missing for ban: \(texts)")

        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
        XCTAssertEqual(state.composingText.value.convertTarget, "")
    }
}

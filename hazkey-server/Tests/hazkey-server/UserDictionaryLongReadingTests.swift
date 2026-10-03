import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// どの辞書にも読みの途中までしか無い、長い読みのユーザ辞書の語に対する回帰テスト
///
/// 「まとうぞうけん」で登録した「間桐臓硯」は、「まとうぞうけんとまとうしんじ」と入力して変換すると候補に出ず、
/// [Shift] + [Left]キーで「まとうぞうけん」だけを選択しても出なかった
///
/// 変換エンジンの辞書引きは、短い読みから順に伸ばしながら各辞書を引き、どの辞書にも続きが無い読みでそれ以上の探索を打ち切る
/// 動的ユーザ辞書はこの判定に加わっておらず、システム辞書に無い「マトウゾ」で打ち切られて「マトウゾウケン」が引かれなかった
///
/// 入力中に候補を要求するかどうか (打鍵の間引き、[リッチな提案を使用]の設定による要求の違い) で前回の探索結果の再利用範囲が変わるため、
/// 同じ入力でも語が出る場合と出ない場合があった
///
/// - Note: 修正はAzooKeyConverterフォーク (presire/AzooKeyKanaKanjiConverter、hazkeyブランチ) のDicdataStore.movingTowardPrefixSearchにあり、
///         フォーク側のテストはHazkeyLongUserDictionaryReadingTests.swiftにある
final class UserDictionaryLongReadingTests: XCTestCase {
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

    /// 入力するローマ字 (読みは「まとうぞうけんとまとうしんじ」)
    private let romaji = "matouzoukentomatousinnji"
    /// 長い読み「まとうぞうけん」で登録した語
    private let longReadingWord = "間桐臓硯"

    /// テスト環境の準備に失敗した場合のエラー
    private enum SetupError: Error {
        /// setenvによる環境変数の設定に失敗した (関連値は変数名)
        case setFailed(String)
        /// 環境変数に対応する一時ディレクトリ名が定義されていない (関連値は変数名)
        case missingPath(String)
    }

    /// 一時ディレクトリと環境変数を準備し、ユーザ辞書を書き出す
    ///
    /// ユーザ辞書には、読み「まとう」「まとうぞうけん」の人名を登録する
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
            まとう\t間桐\t\tperson
            まとうぞうけん\t間桐臓硯\t\tperson

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

    /// 新しい組成を開始した接続を作成する
    ///
    /// ニューラル変換 (Zenzai) は無効にし、変換エンジンの辞書だけで候補を作る
    ///
    /// - Returns: 組成を開始済みの接続の状態
    private func makeState() -> HazkeyServerState {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.numSuggestions = 10
        state.serverConfig.currentProfile.numCandidatesPerPage = 10
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        return state
    }

    /// ローマ字を1文字ずつ入力し、指定した打鍵の後にだけサジェストを要求する
    ///
    /// - Parameters:
    ///   - state: 入力先の接続の状態
    ///   - requestsSuggestion: 打鍵の位置 (0始まり) を受け取り、その打鍵の後にサジェストを要求する場合にtrueを返す関数
    private func type(into state: HazkeyServerState, requestsSuggestion: (Int) -> Bool) {
        for (index, character) in romaji.enumerated() {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
            if requestsSuggestion(index) {
                XCTAssertEqual(state.getCandidates(is_suggest: true).status, .success)
            }
        }
    }

    /// 通常の変換 ([Space]での変換) として候補を要求し、表記の一覧を取得する
    ///
    /// - Parameter state: 候補を要求する接続の状態
    /// - Returns: 候補の表記の一覧 (応答が候補でない場合は空)
    private func conversionTexts(state: HazkeyServerState) -> [String] {
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }

    /// 入力中に一度も候補を要求せずに変換しても、長い読みのユーザ辞書の語が候補に出る
    ///
    /// 修正前は、前回の探索結果が無く、読みの先頭から全て引き直すため出なかった
    func testConversionWithoutSuggestionsShowsLongReadingWord() {
        let state = makeState()
        type(into: state, requestsSuggestion: { _ in false })
        let texts = conversionTexts(state: state)
        XCTAssertTrue(texts.contains(longReadingWord), "long reading user dictionary entry missing: \(texts)")
    }

    /// 打鍵を間引いてサジェストを要求した後に変換しても、長い読みのユーザ辞書の語が候補に出る
    func testConversionAfterSparseSuggestionsShowsLongReadingWord() {
        for stride in 2...4 {
            let state = makeState()
            type(into: state, requestsSuggestion: { $0 % stride == 0 })
            let texts = conversionTexts(state: state)
            XCTAssertTrue(
                texts.contains(longReadingWord),
                "long reading user dictionary entry missing with suggestions every \(stride) keys: \(texts)")
        }
    }

    /// [Shift] + [Left]キーで「まとうぞうけん」だけを選択すると、長い読みのユーザ辞書の語が候補に出る
    ///
    /// 修正前は、[Space]での変換で語が出なかった場合、文節境界を調整して読みを「まとうぞうけん」だけにしても出なかった
    func testClauseBoundaryAdjustmentToLongReadingShowsWord() {
        let state = makeState()
        type(into: state, requestsSuggestion: { _ in false })
        _ = conversionTexts(state: state)

        // 読み「まとうぞうけんとまとうしんじ」(14文字) のカーソルを、「まとうぞうけん」(7文字) の直後へ移す
        let response = state.adjustClauseBoundary(offset: -7)
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(state.composingText.value.convertTargetCursorPosition, 7)
        let texts = response.clauseBoundaryResult.candidates.candidates.map(\.text)
        XCTAssertTrue(texts.contains(longReadingWord), "long reading user dictionary entry missing after adjustment: \(texts)")
    }
}

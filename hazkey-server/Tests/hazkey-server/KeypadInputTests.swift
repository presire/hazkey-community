import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// テンキーからの入力 ([InputChar.bypass_keymap]) がキーマップを迂回し、入力テーブルと変換は従来どおり働くことを検証する
///
/// フロントエンドはテンキーの設定 (半角・全角) に従って文字を決めて送るため、サーバはキーマップ (全角数字・和字記号・JISかな等) を適用しない
///
/// 入力テーブルの要素として挿入するため、未確定のローマ字の確定、郵便番号変換・漢数字・誤字訂正・記号変換は従来の入力と同じく動作する
final class KeypadInputTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
        "HAZKEY_POSTAL_CODE_DICTIONARY",
        "HAZKEY_SYMBOL_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case setFailed(String)
    }

    /// 郵便番号の小さなTSVに収録する住所
    private static let chiyodaAddress = "東京都千代田区千代田"

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        temporaryDirectory = root
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let fixture = root.appendingPathComponent("postal_codes.tsv")
        try Data("1000001\t\(Self.chiyodaAddress)\n".utf8).write(to: fixture)

        let paths = [
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("runtime").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "HAZKEY_DICTIONARY": Self.repositoryRoot.appendingPathComponent(
                "hazkey-server/azooKey_dictionary_storage/Dictionary", isDirectory: true
            ).path,
            "HAZKEY_POSTAL_CODE_DICTIONARY": fixture.path,
            "HAZKEY_SYMBOL_DICTIONARY": Self.repositoryRoot.appendingPathComponent(
                "hazkey-server/SymbolDictionary/symbol_dictionary.tsv"
            ).path,
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            guard let value = paths[variable], setenv(variable, value, 1) == 0 else {
                throw SetupError.setFailed(variable)
            }
        }
    }

    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                setenv(variable, value, 1)
            } else {
                unsetenv(variable)
            }
        }
        originalEnvironment.removeAll()
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: 補助

    /// 1回の入力 (文字とキーマップを迂回するかどうか)
    private struct Key {
        let text: String
        let bypassKeymap: Bool
    }

    /// 通常のキーの入力列を作る
    private static func typed(_ text: String) -> [Key] {
        text.map { Key(text: String($0), bypassKeymap: false) }
    }

    /// テンキーの入力列を作る
    private static func keypad(_ text: String) -> [Key] {
        text.map { Key(text: String($0), bypassKeymap: true) }
    }

    /// プロファイルを調整して共有リソースを作る
    ///
    /// - Parameter configure: 既定プロファイル (Zenzai無効) に加える変更
    /// - Returns: 設定を適用済みの共有リソース
    private func makeShared(
        _ configure: (inout Hazkey_Config_Profile) -> Void = { _ in }
    ) -> HazkeySharedResources {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.zenzaiEnable = false
        configure(&profile)
        shared.serverConfig.currentProfile = profile
        shared.reinitializeConfiguration()
        return shared
    }

    /// 新しい組成へ入力列を送る
    ///
    /// - Parameters:
    ///   - state: 入力する接続セッション
    ///   - keys: 入力列
    private func input(_ state: HazkeyServerState, _ keys: [Key]) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for key in keys {
            XCTAssertEqual(
                state.inputChar(inputString: key.text, bypassKeymap: key.bypassKeymap).status,
                .success, key.text)
        }
    }

    /// 入力列を送った後の組成の文字列を返す
    private func composition(_ shared: HazkeySharedResources, _ keys: [Key]) -> String {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        input(state, keys)
        return state.composingText.value.convertTarget
    }

    /// 入力列を送った後の候補を返す
    ///
    /// - Parameters:
    ///   - shared: 共有リソース
    ///   - keys: 入力列
    ///   - prepare: 入力前に接続セッションへ加える変更
    /// - Returns: 通常変換の候補の結果
    private func candidates(
        _ shared: HazkeySharedResources, _ keys: [Key],
        prepare: (HazkeyServerState) -> Void = { _ in }
    ) -> Hazkey_Commands_CandidatesResult {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        prepare(state)
        input(state, keys)
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        return response.candidates
    }

    private static func enabledKeymap(_ name: String) -> Hazkey_Config_Profile.EnabledKeymap {
        Hazkey_Config_Profile.EnabledKeymap.with {
            $0.name = name
            $0.isBuiltIn = true
            $0.filename = name
        }
    }

    // MARK: キーマップの迂回

    func testKeypadDigitsBypassFullwidthNumberKeymap() {
        // 前提: 全角数字のキーマップを含む既定プロファイル
        let shared = makeShared()

        // 実行・検証: 通常のキーは全角数字になり、テンキーの文字は送ったとおりに入る
        XCTAssertEqual(composition(shared, Self.typed("123")), "１２３")
        XCTAssertEqual(composition(shared, Self.keypad("123")), "123")
        XCTAssertEqual(composition(shared, Self.keypad("１２３")), "１２３")
    }

    func testKeypadSymbolsBypassJapaneseSymbolKeymap() {
        // 前提: 和字記号 (「.」→「。」等) と全角基本記号のキーマップを含む既定プロファイル
        let shared = makeShared()

        // 実行・検証: 通常のキーは和字記号になり、テンキーの記号は送ったとおりに入る
        XCTAssertEqual(composition(shared, Self.typed(".")), "。")
        XCTAssertEqual(composition(shared, Self.keypad(".")), ".")
        XCTAssertEqual(composition(shared, Self.keypad("+-*/")), "+-*/")
        XCTAssertEqual(composition(shared, Self.keypad("．＋－＊／")), "．＋－＊／")
    }

    func testKeypadDigitsBypassJISKanaKeymap() {
        // 前提: JISかなのキーマップとかな入力テーブルのプロファイル
        let shared = makeShared { profile in
            profile.enabledKeymaps = [Self.enabledKeymap("JIS Kana")]
            profile.enabledTables = [
                Hazkey_Config_Profile.EnabledInputTable.with {
                    $0.name = "Kana"
                    $0.isBuiltIn = true
                    $0.filename = "Kana"
                }
            ]
        }

        // 実行・検証: 通常の「1」はかなの「ぬ」になり、テンキーの「1」は数字のまま入る
        XCTAssertEqual(composition(shared, Self.typed("1")), "ぬ")
        XCTAssertEqual(composition(shared, Self.keypad("1")), "1")
        XCTAssertEqual(composition(shared, Self.keypad("１")), "１")
    }

    // MARK: 入力テーブル

    func testPendingNIsResolvedByKeypadDigit() {
        // 前提: ローマ字入力の既定プロファイル
        let shared = makeShared()

        // 実行・検証: 未確定の「n」はテンキーの数字で「ん」に確定し、数字は送ったとおりに入る
        XCTAssertEqual(composition(shared, Self.typed("kan") + Self.keypad("1")), "かん1")
        XCTAssertEqual(composition(shared, Self.typed("kan") + Self.keypad("１")), "かん１")
    }

    func testRomajiTableRulesApplyToKeypadCharacters() {
        // 前提: ローマ字入力テーブルに「z．」→「…」の規則がある既定プロファイル
        let shared = makeShared()

        // 実行・検証: 全角のテンキーの「．」は規則に一致して「…」になる
        XCTAssertEqual(composition(shared, Self.typed("z") + Self.keypad("．")), "…")
        // 半角の「.」はテーブルに「z.」の規則が無いため、そのまま並ぶ
        XCTAssertEqual(composition(shared, Self.typed("z") + Self.keypad(".")), "z.")
        // 通常のキーの「.」は和字記号のキーマップで「。」になり「z。」→「…」に一致する
        XCTAssertEqual(composition(shared, Self.typed("z.")), "…")
    }

    func testDirectInputSubModeTakesPriorityOverKeypadInput() {
        // 前提: 直接入力モードの接続セッション
        let shared = makeShared()
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        state.isSubInputMode = true

        // 実行: テンキーの文字を入力する
        XCTAssertEqual(state.inputChar(inputString: "1", bypassKeymap: true).status, .success)

        // 検証: 直接入力として挿入される (入力テーブルの要素にならない)
        XCTAssertEqual(state.composingText.value.convertTarget, "1")
        XCTAssertTrue(state.composingText.value.input.allSatisfy { $0.inputStyle == .direct })
        XCTAssertTrue(state.isSubInputMode)
    }

    func testKeypadInputIsInsertedAsInputTableElement() {
        // 前提: 既定プロファイルの接続セッション
        let shared = makeShared()
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }

        // 実行: テンキーの文字を入力する
        input(state, Self.keypad("1"))

        // 検証: 直接入力ではなく入力テーブルの要素として挿入される
        XCTAssertFalse(state.composingText.value.input.contains { $0.inputStyle == .direct })
    }

    // MARK: 変換

    func testPostalCodeConversionWorksWithKeypadDigits() {
        // 前提: 郵便番号変換を有効にしたプロファイル
        let shared = makeShared { $0.usePostalCodeConversion = true }

        for keys in [Self.keypad("1000001"), Self.keypad("１０００００１"), Self.keypad("100-0001")] {
            let context = keys.map(\.text).joined()
            // 実行: テンキーで郵便番号を入力して変換する
            let result = candidates(shared, keys)

            // 検証: 先頭候補の直後に住所の候補が並ぶ
            XCTAssertEqual(result.candidates.dropFirst().first?.text, Self.chiyodaAddress, context)
        }
    }

    func testNumberCandidatesAppearWithKeypadDigits() {
        // 前提: 既定プロファイル (桁区切りの数字変換は既定で有効)
        let shared = makeShared()

        // 実行: テンキーで数字を入力して変換する
        let texts = candidates(shared, Self.keypad("1000")).candidates.map(\.text)

        // 検証: 送った数字・全角の数字・桁区切りの数字が候補に出る
        XCTAssertEqual(texts.first, "1000")
        XCTAssertTrue(texts.contains("１０００"), "\(texts)")
        XCTAssertTrue(texts.contains("1,000"), "\(texts)")
    }

    func testKanjiNumberCandidatesAppearWithKeypadDigits() {
        // 前提: 既定プロファイル
        let shared = makeShared()

        // 実行: テンキーで半角の数字を入力して変換する
        let hundreds = candidates(shared, Self.keypad("123")).candidates.map(\.text)
        let thousand = candidates(shared, Self.keypad("1000")).candidates.map(\.text)

        // 検証: 漢数字の候補が出る
        XCTAssertTrue(hundreds.contains("百二十三"), "\(hundreds)")
        XCTAssertTrue(thousand.contains("千"), "\(thousand)")
    }

    func testTypoCorrectionIsUnchangedWhenLettersBypassKeymap() {
        // 前提: 誤字訂正を有効にしたプロファイル
        let shared = makeShared { $0.useTypoCorrection = true }
        let prepare: (HazkeyServerState) -> Void = { state in
            state.typoTimeBudget = .seconds(10)
            state.typoEvaluationBudget = .seconds(10)
        }
        _ = candidates(shared, Self.typed("shipppaishita"), prepare: prepare)

        // 実行: 同じ読みを通常のキーと、キーマップを迂回する入力で変換する
        let typed = candidates(shared, Self.typed("shipppaishita"), prepare: prepare)
        let bypassed = candidates(shared, Self.keypad("shipppaishita"), prepare: prepare)

        // 検証: 誤字訂正の候補が同じく提示される (直接入力のように訂正を無効化しない)
        XCTAssertTrue(typed.candidates.contains(where: \.isTypoCorrection))
        XCTAssertEqual(
            bypassed.candidates.filter(\.isTypoCorrection).map(\.text),
            typed.candidates.filter(\.isTypoCorrection).map(\.text))
    }

    func testTypoCorrectionStaysAvailableAfterKeypadDigit() {
        // 前提: 誤字訂正を有効にしたプロファイル
        let shared = makeShared { $0.useTypoCorrection = true }
        let prepare: (HazkeyServerState) -> Void = { state in
            state.typoTimeBudget = .seconds(10)
            state.typoEvaluationBudget = .seconds(10)
        }
        _ = candidates(shared, Self.typed("shipppaishita"), prepare: prepare)

        // 実行: 誤字を含む読みの後にテンキーの数字を入力して変換する
        let result = candidates(shared, Self.typed("shipppaishita") + Self.keypad("1"), prepare: prepare)

        // 検証: テンキーの数字で組成が直接入力扱いにならず、誤字訂正の候補が提示される
        XCTAssertTrue(
            result.candidates.contains { $0.isTypoCorrection && $0.text == "失敗した1" },
            "\(result.candidates.map(\.text))")
    }

    func testSymbolConversionIsUnchangedWhenLettersBypassKeymap() {
        // 前提: 記号変換を有効にしたプロファイル
        let shared = makeShared { $0.specialConversionMode.symbol = true }

        // 実行: 同じ読みを通常のキーと、キーマップを迂回する入力で変換する
        let typed = candidates(shared, Self.typed("yajirusi")).candidates.map(\.text)
        let bypassed = candidates(shared, Self.keypad("yajirusi")).candidates.map(\.text)

        // 検証: 記号の繰り上げを含む候補の並びが同じになる
        XCTAssertTrue(typed.prefix(9).contains("→"), "\(typed)")
        XCTAssertEqual(bypassed, typed)
    }
}

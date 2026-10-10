import XCTest

@testable import hazkey_server

/// カナ種切替 (GetComposingString.CharType.KANA_CYCLE) とホットキー設定の検証
///
/// 表示中の表記から次のカナ種を決めるため、フロントエンドは状態を持たない
final class KanaCycleTests: XCTestCase {
    private func makeState() -> HazkeyServerState {
        let state = HazkeyServerState()
        // Zenzaiモデル不在の環境でも通るようにする (変換は行わない経路)
        state.serverConfig.currentProfile.zenzaiEnable = false
        return state
    }

    private func input(_ state: HazkeyServerState, _ romaji: String) {
        for character in romaji {
            XCTAssertEqual(
                state.inputChar(inputString: String(character)).status, .success)
        }
    }

    private func kanaCycle(_ state: HazkeyServerState, preedit: String) throws -> String {
        let response = state.getComposingString(charType: .kanaCycle, currentPreedit: preedit)
        XCTAssertEqual(response.status, .success)
        guard case .text(let text)? = response.payload else {
            XCTFail("Expected composing text response")
            return ""
        }
        return text
    }

    /// 全角カタカナ → 半角カタカナ → ひらがな → 全角カタカナの順に循環すること
    func testCycleOrderFollowsDisplayedText() {
        let next = { (preedit: String) in
            cycleKanaType(
                hiragana: "かんじ", fullKatakana: "カンジ", halfKatakana: "ｶﾝｼﾞ", preedit: preedit)
        }
        XCTAssertEqual(next("カンジ"), "ｶﾝｼﾞ")
        XCTAssertEqual(next("ｶﾝｼﾞ"), "かんじ")
        XCTAssertEqual(next("かんじ"), "カンジ")
    }

    /// ライブ変換の漢字等、どのカナ種とも一致しない表示からは全角カタカナになること
    func testUnmatchedDisplayStartsWithFullKatakana() {
        let next = { (preedit: String) in
            cycleKanaType(
                hiragana: "かんじ", fullKatakana: "カンジ", halfKatakana: "ｶﾝｼﾞ", preedit: preedit)
        }
        XCTAssertEqual(next("漢字"), "カンジ")
        XCTAssertEqual(next(""), "カンジ")
        XCTAssertEqual(next("kanji"), "カンジ")
    }

    /// 同じ文字列になるカナ種は飛ばし、ひらがなへ戻れなくならないこと
    func testIdenticalKanaTypesAreSkipped() {
        // 全角カタカナと半角カタカナが同じ場合は、ひらがなと交互になる
        XCTAssertEqual(
            cycleKanaType(hiragana: "x", fullKatakana: "y", halfKatakana: "y", preedit: "y"), "x")
        XCTAssertEqual(
            cycleKanaType(hiragana: "x", fullKatakana: "y", halfKatakana: "y", preedit: "x"), "y")
        // 全て同じ場合 (数字だけの組成等) は同じ表記のまま
        XCTAssertEqual(
            cycleKanaType(hiragana: "123", fullKatakana: "123", halfKatakana: "123", preedit: "123"),
            "123")
    }

    /// サーバ状態の組成全体に対して、表示に応じた次のカナ種を返すこと
    func testGetComposingStringCyclesWholeComposingText() throws {
        let state = makeState()
        input(state, "kanji")

        XCTAssertEqual(try kanaCycle(state, preedit: "漢字"), "カンジ")
        XCTAssertEqual(try kanaCycle(state, preedit: "カンジ"), "ｶﾝｼﾞ")
        XCTAssertEqual(try kanaCycle(state, preedit: "ｶﾝｼﾞ"), "かんじ")
        XCTAssertEqual(try kanaCycle(state, preedit: "かんじ"), "カンジ")
    }

    /// 既定プロファイルのカナ種切替ホットキーは[無変換]キーであること
    func testDefaultProfileUsesMuhenkan() throws {
        let response = HazkeyServerConfig.getDefaultProfile()
        let profile = try XCTUnwrap(response.currentConfig.profiles.first)

        XCTAssertTrue(profile.hasKanaCycleHotkey)
        XCTAssertEqual(profile.kanaCycleHotkey, "Muhenkan")
    }

    /// フィールドが無い旧プロファイルは既定値で補い、明示的な空文字列 (無効) は保持すること
    func testNormalizeProfileFillsMissingAndPreservesExplicitEmpty() throws {
        var missing = HazkeyServerConfig.genDefaultConfig()
        missing.clearKanaCycleHotkey()
        var disabled = HazkeyServerConfig.genDefaultConfig()
        disabled.kanaCycleHotkey = ""

        let normalizedMissing = try HazkeyServerConfig.normalizeProfile(missing)
        let normalizedDisabled = try HazkeyServerConfig.normalizeProfile(disabled)

        XCTAssertEqual(normalizedMissing.kanaCycleHotkey, "Muhenkan")
        XCTAssertTrue(normalizedDisabled.hasKanaCycleHotkey)
        XCTAssertEqual(normalizedDisabled.kanaCycleHotkey, "")
    }

    /// 明示的な空文字列がconfig.jsonの保存と読み直しで失われないこと
    func testSavedDisabledHotkeySurvivesReload() throws {
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        guard setenv("XDG_CONFIG_HOME", directory.path, 1) == 0 else {
            XCTFail("Failed to sandbox XDG_CONFIG_HOME")
            return
        }
        defer {
            if let savedConfigHome {
                setenv("XDG_CONFIG_HOME", savedConfigHome, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }

        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.kanaCycleHotkey = ""

        let config = HazkeyServerConfig()
        try config.saveConfig([profile])
        let reloaded = try XCTUnwrap(HazkeyServerConfig.loadConfig().first)

        XCTAssertTrue(reloaded.hasKanaCycleHotkey)
        XCTAssertEqual(reloaded.kanaCycleHotkey, "")
    }
}

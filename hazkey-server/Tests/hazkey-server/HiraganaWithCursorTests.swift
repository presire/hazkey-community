import XCTest

@testable import hazkey_server

/// `HazkeyServerState.getHiraganaWithCursor()` は構造APIであり、表示設定
/// (auxTextMode) に従属してはならない。フロントエンドは preedit のキャレット
/// 位置をこの3分割から算出するため、設定によって空が返るとキャレットが消える。
/// AUXの表示・非表示の判断はフロントエンド側
/// (hazkey-frontend-common/composing_cursor_view.h —
/// hazkey::frontend::shouldShowAuxText) が行う。
final class HiraganaWithCursorTests: XCTestCase {
    private func makeState(
        auxTextMode: Hazkey_Config_Profile.AuxTextMode
    ) -> HazkeyServerState {
        let state = HazkeyServerState()
        // Zenzai モデル不在の環境でも通るようにする (変換は行わない経路だが、
        // 他テストと同じ前提に揃えておく)。
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.auxTextMode = auxTextMode
        return state
    }

    private func split(
        _ state: HazkeyServerState
    ) -> (before: String, onCursor: String, after: String) {
        let response = state.getHiraganaWithCursor()
        XCTAssertEqual(response.status, .success)
        let parts = response.textWithCursor
        return (parts.beforeCursosr, parts.onCursor, parts.afterCursor)
    }

    private func inputHiragana(_ state: HazkeyServerState, _ romaji: String) {
        for character in romaji {
            XCTAssertEqual(
                state.inputChar(inputString: String(character)).status, .success)
        }
    }

    /// auxTextMode が AUX_TEXT_DISABLED でも、カーソルが中間にあれば実際の
    /// 3分割が返ること。
    func testDisabledModeStillReturnsRealSplit() {
        let state = makeState(auxTextMode: .auxTextDisabled)
        inputHiragana(state, "aiu")
        XCTAssertEqual(state.moveCursor(offset: -1).status, .success)

        let parts = split(state)
        XCTAssertEqual(parts.before, "あい")
        XCTAssertEqual(parts.onCursor, "う")
        XCTAssertEqual(parts.after, "")
    }

    /// auxTextMode が AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END で、カーソルが末尾
    /// でも beforeCursosr に全文が入ること (旧実装は3フィールドとも空にしていた)。
    func testShowWhenCursorNotAtEndStillReturnsFullTextAtEnd() {
        let state = makeState(auxTextMode: .auxTextShowWhenCursorNotAtEnd)
        inputHiragana(state, "aiu")

        let parts = split(state)
        XCTAssertEqual(parts.before, "あいう")
        XCTAssertEqual(parts.onCursor, "")
        XCTAssertEqual(parts.after, "")
    }

    /// 空の composition では3フィールドとも空であること。
    func testEmptyCompositionReturnsAllEmpty() {
        let state = makeState(auxTextMode: .auxTextShowAlways)

        let parts = split(state)
        XCTAssertEqual(parts.before, "")
        XCTAssertEqual(parts.onCursor, "")
        XCTAssertEqual(parts.after, "")
    }

    /// カーソルが中間にあるときの3分割。どの auxTextMode でも同じ結果になること。
    func testMiddleCursorSplitIsIndependentOfAuxTextMode() {
        let modes: [Hazkey_Config_Profile.AuxTextMode] = [
            .unspecified,
            .auxTextDisabled,
            .auxTextShowAlways,
            .auxTextShowWhenCursorNotAtEnd,
        ]
        for mode in modes {
            let state = makeState(auxTextMode: mode)
            inputHiragana(state, "aiue")
            XCTAssertEqual(state.moveCursor(offset: -3).status, .success)

            let parts = split(state)
            XCTAssertEqual(parts.before, "あ", "mode=\(mode)")
            XCTAssertEqual(parts.onCursor, "い", "mode=\(mode)")
            XCTAssertEqual(parts.after, "うえ", "mode=\(mode)")
        }
    }

    /// 先頭 (cursorPos == 0) では beforeCursosr が空で、onCursor が先頭文字。
    /// moveCursor はサーバ側でクランプされるため、範囲外へは出ない。
    func testCursorAtHeadClampsAndSplits() {
        let state = makeState(auxTextMode: .auxTextShowWhenCursorNotAtEnd)
        inputHiragana(state, "aiu")
        XCTAssertEqual(state.moveCursor(offset: -1024).status, .success)

        let parts = split(state)
        XCTAssertEqual(parts.before, "")
        XCTAssertEqual(parts.onCursor, "あ")
        XCTAssertEqual(parts.after, "いう")
    }
}

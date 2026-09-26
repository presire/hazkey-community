/**
 * @file hazkey_state_test.cpp
 * @brief IBusフロントエンドの候補インデックス計算のテスト
 *
 * fcitx5-hazkey/src/hazkey_candidate_selection_test.cppのIBus側対応版:
 * IBusLookupTableはページ内選択インデックス (数字キーと候補クリック) で候補を持ち、一方サーバのprefix-complete RPCは全体インデックスを受け取る
 * HazkeyState::pageLocalToGlobalIndex()は、selectDigit()とcandidateClicked()の両方が使用する単一の純粋な写像である
 *
 * IBusデーモン、エンジンインスタンス、hazkey-serverは不要:
 * 純粋なstatic写像だけを実行するため、実行中のセッションを妨げることはない
 */
#include <cassert>
#include <iostream>
#include <unordered_set>
#include "composing_cursor_view.h"
#include "hazkey_frontend.h"
#include "hazkey_state.h"
#include "live_convert_mode.h"

namespace {

using hazkey::ibus::HazkeyState;

/**
 * @brief 複数ページにまたがるページ内位置から全体位置への解決を検証する
 *
 * 前提として13候補を5件ずつ表示する (ページは5/5/3件)
 * ページ0ではページ内0から4が全体0から4に解決し、ページ内5は拒否される
 * ページ1 (カーソル7) ではページ内0から4が全体5から9に解決する
 *
 * 最終の部分ページ (カーソル12) では、ページ内0から2が全体10から12に解決し、存在しない枠へのページ内3は後ろのページへ通り抜けず拒否される
 * 範囲外の全体カーソルは折り返さず拒否する
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testMultiPageResolution() {
    // 前提: 13候補を5件ずつ表示 (ページは 5 / 5 / 3 件)
    // 実行・検証: ページ0ではページ内0..4が全体0..4に解決し、ページ内5は拒否
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 0, 0) == 0);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 0, 4) == 4);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 0, 5) == -1);

    // 実行・検証: ページ1 (カーソル7) ではページ内0..4が全体5..9に解決する
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 0) == 5);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 2) == 7);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 4) == 9);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 5) == -1);

    // 実行・検証: 最終の部分ページ (カーソル12 -> pageStart10、候補3件) では、ページ内0..2が全体10..12に解決する
    // ページ内3は存在しない枠への数字キーで、後ろのページへ通り抜けてはならない
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 12, 0) == 10);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 12, 2) == 12);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 12, 3) == -1);

    // 検証: 範囲外の全体カーソルは折り返さず拒否する。
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 13, 0) == -1);

    std::cout << "[PASS] multi-page page-local -> global resolution\n";
}

/**
 * @brief サーバが返すsuggest/非suggestのページ形状での解決を検証する
 *
 * 前提として非suggest変換 (page_size 9) で候補10件を置く
 * キー"0" (ページ内9) がページ0の10件目を選ばず、そのリストのページ1は単一候補 (全体9) になる
 * 1ページにちょうど収まるsuggestリスト (page_size 3) では範囲内が解決し範囲外が拒否される
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testServerPageShapes() {
    // 前提: 非suggest変換 (page_size 9) で候補10件
    // 検証: キー"0" (ページ内9) がページ0の10件目を選んではならない
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 0, 8) == 8);
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 0, 9) == -1);

    // 検証: そのリストのページ1は単一候補 (全体9)
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 9, 0) == 9);
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 9, 1) == -1);

    // 前提: 1ページにちょうど収まるsuggestリスト (page_size 3)
    assert(HazkeyState::pageLocalToGlobalIndex(3, 3, 0, 2) == 2);
    assert(HazkeyState::pageLocalToGlobalIndex(3, 3, 0, 3) == -1);

    std::cout << "[PASS] server page shapes (suggest/non-suggest)\n";
}

/**
 * @brief 不正な入力値を全て拒否することを検証する
 *
 * ページ件数・候補総数・全体カーソル・ページ内位置のいずれかが不正 (0以下または範囲外) の場合、写像は-1を返す
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testInvalidInput() {
    assert(HazkeyState::pageLocalToGlobalIndex(0, 5, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(-1, 5, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 0, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, -1, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 5, -1, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 5, 0, -1) == -1);

    std::cout << "[PASS] invalid input rejected\n";
}

/**
 * @brief ライブ変換トグルが直前のONモードを記憶・復元することを検証する
 *
 * fcitx5-hazkey-communityのlive_convert_modeポリシーの移植である
 * 前提として、ホットキーはONからDISABLEDへの切替だけを行う
 * OFFへのトグルでは、現在のONモードを記憶してDISABLEDを返し、ONへのトグルでは記憶したモードを変更せず復元する
 * ALWAYSは、FOR_MULTIPLE_CHARSとは独立に復元される
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testLiveConvertModeTransition() {
    // fcitx5-hazkey-communityのlive_convert_modeポリシーの移植 (Phase C):
    // ホットキーは、ON<->DISABLEDの切り替えだけを行い、直前のONモードを復元する
    using M = hazkey::config::Profile_AutoConvertMode;
    using hazkey::ibus::computeNextAutoConvertMode;

    // OFFへのトグル:
    // 現在のONモードを記憶して、DISABLEDを返す
    M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
    assert(computeNextAutoConvertMode(
               M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS,
               remembered) == M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED);
    assert(remembered == M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);

    // ONへのトグル:
    // 記憶したモードを変更せず復元する
    assert(computeNextAutoConvertMode(
               M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED,
               remembered) ==
           M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);
    assert(remembered == M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);

    // ALWAYSは、FOR_MULTIPLE_CHARSとは独立に復元される
    M rememberedAlways = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
    assert(computeNextAutoConvertMode(
               M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED,
               rememberedAlways) ==
           M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);

    std::cout << "[PASS] live-convert mode toggle transition\n";
}

/**
 * @brief Fcitx 5形式ホットキー文字列のパースと照合を検証する
 *
 * 前提として、hazkey-community-settingsが書くFcitx 5形式の文字列はIBusのkeyvalと完全一致モディファイアマスクへパースされる
 * 英字の大文字小文字は区別せず、Mod4はSuperへ畳む
 *
 * プロファイル値が空なら既定文字列へフォールバックし、MetaはSuperとは別の独自マスクを持つ
 * 不明トークン・キー2つ以上・キー欠落、およびパース不能や空のspecは決して一致しないspecを作る
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testHotkeyParsingAndMatching() {
    // Fcitx 5形式のホットキー文字列 (hazkey-community-settingsが書く) は、IBusのkeyval + 完全一致モディファイアマスクへパースされる
    // 英字の大文字小文字は区別せず、Mod4は[Super]へ畳む
    const auto live = HazkeyState::parseHotkey("Control+Shift+L", "F5");
    assert(live.keyval == IBUS_KEY_l);
    assert(live.modifiers == (IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK, live));
    // 大文字keyval ([Shift] + [英字]) も一致する
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_L, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK, live));
    // モディファイアの完全一致: 不足・過剰なモディファイアは一致しない
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_CONTROL_MASK, live));
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK | IBUS_MOD1_MASK, live));
    // ロックキーは無視する
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK | IBUS_LOCK_MASK, live));

    // プロファイル値が空なら既定文字列へフォールバックする。
    const auto accept = HazkeyState::parseHotkey("", "F5");
    assert(accept.keyval == IBUS_KEY_F5);
    assert(accept.modifiers == 0);
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_F5, 0, accept));
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_F4, 0, accept));

    // [Control] + [Alt] + [Z] (Zenzaiの既定値)
    const auto zenzai = HazkeyState::parseHotkey("Control+Alt+Z", "F5");
    assert(zenzai.modifiers == (IBUS_CONTROL_MASK | IBUS_MOD1_MASK));
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_z, IBUS_CONTROL_MASK | IBUS_MOD1_MASK, zenzai));

    // クライアントが[SUPER]と報告しても、Mod4と報告しても、[Super]に一致する
    const auto super = HazkeyState::parseHotkey("Super+L", "F5");
    assert(super.modifiers == IBUS_SUPER_MASK);
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_MOD4_MASK, super));
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_SUPER_MASK, super));

    // モディファイアトークンは大文字小文字を区別しない ("Ctrl" == "Control")
    const auto lower = HazkeyState::parseHotkey("ctrl+shift+l", "F5");
    assert(lower.keyval == IBUS_KEY_l);
    assert(lower.modifiers == (IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));

    // IBusのkeysym名と綴りが異なるQt PortableTextの表記
    assert(HazkeyState::parseHotkey("Space", "F5").keyval == IBUS_KEY_space);
    assert(HazkeyState::parseHotkey("PgUp", "F5").keyval == IBUS_KEY_Page_Up);
    assert(HazkeyState::parseHotkey("Esc", "F5").keyval == IBUS_KEY_Escape);

    // [Meta]は独自マスクを持つ ([Super]とは別)
    const auto meta = HazkeyState::parseHotkey("Meta+L", "F5");
    assert(meta.modifiers == IBUS_META_MASK);
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_META_MASK, meta));

    // 閉鎖的に失敗させる:
    // 不明トークン、キー2つ以上、キー欠落のいずれも、決して一致しないspecを作る
    assert(HazkeyState::parseHotkey("Bogus+L", "F5").keyval == 0);
    assert(HazkeyState::parseHotkey("L+M", "F5").keyval == 0);
    assert(HazkeyState::parseHotkey("Control+Shift", "F5").keyval == 0);

    // パース不能・空の specは決して一致しない
    const auto unset = HazkeyState::parseHotkey("", "");
    assert(unset.keyval == 0);
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_l, 0, unset));

    std::cout << "[PASS] hotkey parse/match\n";
}

/**
 * @brief [Alt]と数字1から9の厳密な組み合わせ判定を検証する
 *
 * FcitxのisAltDigitKeyEvent()に対応する
 * 前提としてちょうどAltと1から9だけが選択になり、[Alt]と[0]や他のモディファイア組み合わせは選択にならない
 *
 * ロックキーは無視し、Mod4は[Super]へ畳むため、Mod4と数字は[Alt]にならない
 * [AltGr]相当のMod5 / Mod3は[Alt]に含まれない
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testAltDigitKeyPredicate() {
    // [Alt] + 数字の候補選択 (FcitxのisAltDigitKeyEvent()):
    // [Alt] + [1]..[9], [Alt] + [0]や他のモディファイア組み合わせは選択にならない
    for (guint k = IBUS_KEY_1; k <= IBUS_KEY_9; ++k) {
        assert(HazkeyState::isAltDigitKey(k, IBUS_MOD1_MASK));
    }
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_0, IBUS_MOD1_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD1_MASK | IBUS_SHIFT_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD1_MASK | IBUS_CONTROL_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, 0));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_a, IBUS_MOD1_MASK));
    // 他のホットキー述語と同様にロックキーは無視する
    assert(HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD1_MASK | IBUS_LOCK_MASK));
    // Mod4は[Super]へ畳むため、Mod4 + [数字]は[Alt]にならない
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD4_MASK));
    // [AltGr]相当のMod5 (ISO_Level3_Shift) / Mod3は[Alt]に含まれない
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD1_MASK | IBUS_MOD5_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD1_MASK | IBUS_MOD3_MASK));

    std::cout << "[PASS] Alt-digit predicate\n";
}

/**
 * @brief [Ctrl]と[U] / [I] / [O] / [P] / [T]の直接変換ショートカット判定を検証する
 *
 * FcitxのctrlShortcutHandler()に対応する
 * 前提として、[Ctrl]のみが対象で、[Ctrl]と[Shift]や[Alt]の組み合わせやモディファイア無しはショートカットでない
 *
 * クライアントが[Ctrl]と英字をシフト無しの小文字keyvalで報告するため大文字小文字を区別せず照合する
 *
 * ショートカットでない英字は、アプリケーション側に残り、ロックキーは無視する
 * [AltGr]相当のMod5 / Mod3は、[Ctrl]に含まれない
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testDirectConversionShortcut() {
    // [Ctrl] + [U] / [I] / [O] / [P] / [T]キーの直接変換 (FcitxのctrlShortcutHandler())
    // 大文字小文字を区別せず照合するのは、クライアントが[Ctrl] + [英字]をシフト無しの小文字keyvalで報告するため
    const guint shortcuts[] = {IBUS_KEY_u, IBUS_KEY_i, IBUS_KEY_o, IBUS_KEY_p, IBUS_KEY_t};
    for (guint k : shortcuts) {
        assert(HazkeyState::isDirectConversionShortcut(k, IBUS_CONTROL_MASK));
        assert(HazkeyState::isDirectConversionShortcut(
            k - 'a' + 'A', IBUS_CONTROL_MASK));
    }

    // [Ctrl]のみ:
    // [Ctrl] + [Shift] / [Alt]やモディファイア無しはショートカットでない
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_MOD1_MASK));
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, 0));
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_MOD1_MASK));

    // ショートカットでない英字はアプリケーション側に残る
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_x, IBUS_CONTROL_MASK));
    // ロックキーは無視する
    assert(HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_LOCK_MASK));
    // [AltGr]相当のMod5 (ISO_Level3_Shift) / Mod3は[Ctrl]に含まれない
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_MOD5_MASK));
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_MOD3_MASK));

    std::cout << "[PASS] Ctrl direct-conversion shortcut predicate\n";
}

/**
 * @brief AuxUpとAuxDownの単一補助テキスト枠への結合を検証する
 *
 * 前提としてfcitxはAuxUpとAuxDownが別パネルだがIBusは補助枠が1つしかないため結合する
 * 既存のフォーカス中表示"[n/total] Deletable"はバイト単位で同一に保つ
 *
 * 組成中は生ひらがなAuxUpとTabヒントを結合し、空の生ひらがなAuxUp (auxTextMode無効または組成末尾のカーソル) はAuxDownの前に先行スペースを残さない
 * AuxUpのみまたは両方無しの場合はそのまま返す
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testAuxiliaryTextJoin() {
    // Fcitxは、AuxUp / AuxDownが別パネルだが、IBusは補助枠が1つしかないため、HazkeyState::joinAuxiliaryText()で結合する
    // 既存のフォーカス中表示"[n/total] Deletable"は、バイト単位で同一に保つ
    assert(HazkeyState::joinAuxiliaryText("[1/3]", "Deletable") == "[1/3] Deletable");

    // 組成中 (フォーカス無し): 生ひらがなAuxUp + Tabヒント
    assert(HazkeyState::joinAuxiliaryText("あい", "[Press Tab to Select]") == "あい [Press Tab to Select]");

    // 空の生ひらがなAuxUp (auxTextMode無効、または組成末尾のカーソル) は、AuxDownの前に先行スペースを残してはならない
    assert(HazkeyState::joinAuxiliaryText("", "[Press Tab to Select]") == "[Press Tab to Select]");
    assert(HazkeyState::joinAuxiliaryText("", "[Direct Input]") == "[Direct Input]");

    // AuxUpのみ、または両方無しの場合
    assert(HazkeyState::joinAuxiliaryText("あい", "") == "あい");
    assert(HazkeyState::joinAuxiliaryText("", "") == "");

    std::cout << "[PASS] auxiliary text join (no leading space when empty)\n";
}

/**
 * @brief ZenzaiトグルヒントのAuxDownへの重ね合わせを検証する
 *
 * ibus-rimeのstatus_hint方式による
 * 前提として待機中のトグルはAuxDownが空なのでヒント単体がそのまま見え (空文字列や先行スペース付きでは不可)、AuxDownがあるときはそれを消さず前に付ける
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testZenzaiHintOverlay() {
    // Zenzaiトグルヒント (ibus-rimeのstatus_hint方式) は、同じ結合でAuxDownへ重ねる
    // 待機中のトグルはAuxDownが空なので、ヒント単体が見えなければならず (空文字列や先行スペース付きでは不可)、
    // AuxDownがある時はそれを消さず前に付ける
    assert(HazkeyState::joinAuxiliaryText("Zenzai enabled", "") == "Zenzai enabled");
    assert(HazkeyState::joinAuxiliaryText("Zenzai disabled", "") == "Zenzai disabled");
    assert(HazkeyState::joinAuxiliaryText("Zenzai enabled", "[Direct Input]") == "Zenzai enabled [Direct Input]");
    assert(HazkeyState::joinAuxiliaryText("Zenzai enabled", "[Press Tab to Select]") == "Zenzai enabled [Press Tab to Select]");

    std::cout << "[PASS] zenzai hint overlays AuxDown\n";
}

/**
 * @brief ライブ変換トグルヒントのAuxDownへの重ね合わせを検証する
 *
 * 前提としてライブ変換トグルは共有の一時ヒントを再利用するためZenzaiヒントと同じ結合で重ねる
 * 待機中は単体で見え、既存AuxDownの前にそれを消さず付ける
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testLiveConvertHintOverlay() {
    // ライブ変換トグルは共有の一時ヒントを再利用するため、同じ結合でAuxDownへ重ねる:
    // 待機中は単体で見え、既存AuxDownの前にそれを消さず付ける
    assert(HazkeyState::joinAuxiliaryText("Live conversion enabled", "") == "Live conversion enabled");
    assert(HazkeyState::joinAuxiliaryText("Live conversion disabled", "") == "Live conversion disabled");
    assert(HazkeyState::joinAuxiliaryText("Live conversion enabled", "[Direct Input]") == "Live conversion enabled [Direct Input]");
    assert(HazkeyState::joinAuxiliaryText("Live conversion disabled", "[Press Tab to Select]") == "Live conversion disabled [Press Tab to Select]");

    std::cout << "[PASS] live conversion hint overlays AuxDown\n";
}

/**
 * @brief Shift単体押下相当のモディファイア状態判定を検証する
 *
 * ShiftリリースがRELEASE (直接入力をトグル) とCANCELのどちらを送るかを決める
 * 前提として、ツールキットが[Shift]のKeyPressをShift適用前の採取state (state 0) で報告しても単体の[Shift]を検出しなければならない
 * 単体の[Shift]ではSHIFTビットの有無を問わず、ロックキーは無視する
 *
 * 他のモディファイアがあれば単体ではなく、Mod4は[Super]へ畳み、[AltGr]相当のMod5 / Mod3は単体[Shift]の条件を満たさない
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testLoneShiftModifierState() {
    // [Shift]キーリリースがRELEASE (直接入力をトグル) と CANCELのどちらを送るかを決める
    // ツールキットが[Shift]のKeyPressを[Shift]適用前の採取state (state 0) で報告しても、単体の[Shift]を検出しなければならない
    using hazkey::ibus::isLoneShiftModifierState;

    // 単体の[Shift]
    // SHIFTビットの有無は問わない
    assert(isLoneShiftModifierState(IBUS_SHIFT_MASK));
    assert(isLoneShiftModifierState(0));

    // ロックキーは無視する
    assert(isLoneShiftModifierState(IBUS_SHIFT_MASK | IBUS_LOCK_MASK));

    // 他のモディファイアが ([Shift]より先に) あれば単体ではない
    assert(!isLoneShiftModifierState(IBUS_CONTROL_MASK));
    assert(!isLoneShiftModifierState(IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));
    assert(!isLoneShiftModifierState(IBUS_MOD1_MASK));
    assert(!isLoneShiftModifierState(IBUS_MOD1_MASK | IBUS_SHIFT_MASK));
    assert(!isLoneShiftModifierState(IBUS_SUPER_MASK));
    assert(!isLoneShiftModifierState(IBUS_META_MASK));

    // Mod4は[Super]へ畳む
    assert(!isLoneShiftModifierState(IBUS_MOD4_MASK));

    // [AltGr]相当のMod5 / Mod3は単体[Shift]の条件を満たさない
    assert(!isLoneShiftModifierState(IBUS_SHIFT_MASK | IBUS_MOD5_MASK));
    assert(!isLoneShiftModifierState(IBUS_SHIFT_MASK | IBUS_MOD3_MASK));

    std::cout << "[PASS] lone-Shift modifier state predicate\n";
}

/**
 * @brief 候補モードにおける[Alt]と[Shift]と[Space]や[Tab]の無操作組み合わせ判定を検証する
 *
 * 前提としてFcitxのちょうどAltとShiftな候補モードNOP組み合わせを置く
 * [Alt]と[Shift]の[Space]と[Tab]だけを消費する
 *
 * [Shift]と[Tab]は、IBusクライアントからISO_Left_Tabとして報告されることが多いため含め、
 * [Alt]無しのISO_Left_Tabや余分なモディファイア付き、対象外キーは消費しない
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testAltShiftSpaceOrTabPredicate() {
    // 前提: Fcitxの[Alt] + [Shift]キーな候補モードNOP組み合わせ
    // 実行・検証: [Alt] + [Shift]の[Space]と[Tab]だけを消費する
    const guint altShift = IBUS_MOD1_MASK | IBUS_SHIFT_MASK;
    assert(HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_space, altShift));
    assert(HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_Tab, altShift));
    // [Shift] + [Tab]キーは、IBusクライアントからISO_Left_Tabとして報告されることが多い
    assert(HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_ISO_Left_Tab, altShift));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_ISO_Left_Tab, IBUS_SHIFT_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_space, altShift | IBUS_CONTROL_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_Tab, altShift | IBUS_SUPER_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_space, altShift | IBUS_MOD5_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_Return, altShift));

    std::cout << "[PASS] Alt+Shift Space/Tab no-op predicate\n";
}

/**
 * @brief IBusページ内枠向けのFcitx互換数字ラベルを検証する
 *
 * 前提としてfcitxのdefaultSelectionKeysに対応するIBusページ内枠を置く
 * 枠0から8に1から9を付け、枠9に0を付け、それ以外の番号は空にする
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testSelectionLabels() {
    // 前提: FcitxのdefaultSelectionKeysに対応するIBusページ内枠
    // 実行・検証: 枠0..9に1..9、0を付け、それ以外の番号は空にする
    for (int index = 0; index < 9; ++index) {
        assert(HazkeyState::selectionLabelForIndex(index) ==
               std::to_string(index + 1));
    }
    assert(HazkeyState::selectionLabelForIndex(9) == "0");
    assert(HazkeyState::selectionLabelForIndex(-1).empty());
    assert(HazkeyState::selectionLabelForIndex(10).empty());

    std::cout << "[PASS] Fcitx-compatible candidate selection labels\n";
}

/**
 * @brief IBusケーパビリティの利用可否ゲートを検証する
 *
 * 前提としてset_capabilitiesを呼ばないレガシークライアントでは従来の全capabilityありの挙動を保つ
 * 明示のcapability集合では通知された機能だけが利用可能になる
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testCapabilityAvailability() {
    // 前提: set_capabilitiesを呼ばないレガシークライアント
    // 実行・検証: 従来の全capabilityありの挙動を保つ
    assert(HazkeyState::capabilityIsAvailable(
        0, false, IBUS_CAP_SURROUNDING_TEXT));

    // 前提: 明示のcapability集合
    // 実行・検証: 通知された機能だけが利用可能になる
    assert(HazkeyState::capabilityIsAvailable(IBUS_CAP_SURROUNDING_TEXT, true, IBUS_CAP_SURROUNDING_TEXT));
    assert(!HazkeyState::capabilityIsAvailable(IBUS_CAP_PREEDIT_TEXT, true, IBUS_CAP_SURROUNDING_TEXT));

    std::cout << "[PASS] capability availability gate\n";
}

/**
 * @brief roundがFALSEのIBus候補テーブル移動と等価な純粋計算を検証する
 *
 * 前提として候補テーブルはメインループ上で構築されるようになったため、roundがFALSEのページとカーソル移動を純粋な計算として再実装している
 * これらの表明は、挙動をIBusのibus_lookup_table_{page,cursor}_{up,down}()に固定する
 * カーソルは末尾で折り返し、最終ページ上ではそのページ先頭に留まり、prevPageは1ページ分引いてからそのページ先頭へ正規化する
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testLookupPageArithmetic() {
    // カーソルの折り返し (round=FALSE -> 呼び出し元が先頭 / 末尾へ折り返す)
    assert(HazkeyState::advanceCursorIndex(0, 3) == 1);
    assert(HazkeyState::advanceCursorIndex(2, 3) == 0);
    assert(HazkeyState::advanceCursorIndex(-1, 3) == 0);
    assert(HazkeyState::advanceCursorIndex(0, 0) == 0);
    assert(HazkeyState::backCursorIndex(0, 3) == 2);
    assert(HazkeyState::backCursorIndex(2, 3) == 1);
    assert(HazkeyState::backCursorIndex(-1, 3) == 0);

    // 13候補、1ページ 5件 -> ページは[0..4][5..9][10..12]
    assert(HazkeyState::nextPageStart(0, 5, 13) == 5);
    assert(HazkeyState::nextPageStart(4, 5, 13) == 5);
    assert(HazkeyState::nextPageStart(7, 5, 13) == 10);
    // 最終ページ上ではこのページの先頭に留まる。
    assert(HazkeyState::nextPageStart(12, 5, 13) == 10);

    // 最終ページ上では、prevPageはカーソルから1ページ分引いてからそのページ先頭へ正規化する (IBusの[page_up]の意味)
    assert(HazkeyState::prevPageStart(12, 5) == 5);
    assert(HazkeyState::prevPageStart(7, 5) == 0);
    assert(HazkeyState::prevPageStart(3, 5) == 0);

    std::cout << "[PASS] lookup page/cursor arithmetic\n";
}

/**
 * @brief 同期的消費判定が保守的かつ精密であることを検証する
 *
 * 前提としてワーカーが後で転送するキーにTRUEを返してもよいが、動作中の組成や候補リストが所有するキーにFALSEを返してはならない
 * 待機中は印字可能キーをIMEが所有し、[Enter]と[Esc]と[矢印]やリリースと[Shift]、ショートカットでない[Ctrl]組み合わせはアプリケーション側に残す
 *
 * 組成中は確定や取消や直接変換や[Alt]と[数字]をIMEが所有し、候補モードは移動と確定キーをControl分岐より先に扱う
 * プロファイル読み込み前はモディファイア付き組み合わせを暫定的に消費する
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testConsumeDecision() {
    using hazkey::ibus::HazkeyFrontend;
    using hazkey::ibus::HazkeyState;

    HazkeyFrontend::DecisionInput idle;
    idle.profileLoaded = true;
    idle.liveConvert = HazkeyState::parseHotkey("", "Control+Shift+L");
    idle.zenzaiToggle = HazkeyState::parseHotkey("", "Control+Alt+Z");
    idle.acceptPrediction = HazkeyState::parseHotkey("", "F5");
    idle.deleteLearning = HazkeyState::parseHotkey("", "Control+D");

    // 印字可能キーは常にIMEが所有する
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_a, 0, idle));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_space, 0, idle));
    // 待機中のReturn/Escape/矢印はアプリケーション側
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Return, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Escape, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Left, 0, idle));
    // リリースと[Shift]キーは消費しない
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_a, IBUS_RELEASE_MASK, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Shift_L, 0, idle));
    // ショートカットでない[Ctrl]組み合わせはアプリケーション側に残る
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_c, IBUS_CONTROL_MASK, idle));

    auto composing = idle;
    composing.composing = true;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Return, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Escape, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_u, IBUS_CONTROL_MASK, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_1, IBUS_MOD1_MASK, composing));
    // 組成が無ければ、[Alt] + [数字]キーは選択にならない
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_1, IBUS_MOD1_MASK, idle));

    auto candidate = idle;
    candidate.listFocused = true;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_d, IBUS_CONTROL_MASK, candidate));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_3, 0, candidate));
    // 候補モードは移動/確定キーをControl分岐より先に扱う
    // (HazkeyState::candidateKeyEvent に対応) ため、[Ctrl]+ [Enter]キーと[Ctrl] + [F6]キーはIMEのキーになる
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Return, IBUS_CONTROL_MASK, candidate));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_F6, IBUS_CONTROL_MASK, candidate));
    // [Ctrl] + [英字]キーはショートカットでなくアプリケーション側
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_x, IBUS_CONTROL_MASK, candidate));
    // 候補モードの[Alt] + [英字]キーはアプリケーションへ転送する
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_x, IBUS_MOD1_MASK, candidate));

    // プロファイル読み込み前は、モディファイア付き組み合わせは暫定的に消費する
    HazkeyFrontend::DecisionInput unloaded;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_c, IBUS_CONTROL_MASK, unloaded));

    std::cout << "[PASS] synchronous consume decision\n";
}

/**
 * @brief HomeとEndを組成中のみ消費することを検証する
 *
 * [Home]と[End]キーは、組成カーソルを動かす (fcitx5-hazkey-communityも同じく消費する) ため、組成中はアプリケーションへ届けてはならない
 * 組成が無ければテンキー版を含め届け続けなければならず、さもないと全テキスト欄でキャレットキーが飲み込まれる
 *
 * [Left]と[Right]キーは従来どおり待機中は、アプリケーション側で組成中はIME側になり、
 * 組成中でもモディファイア付きの[Home]と[End]はIMEのキーでない ([Ctrl]と[Home]は文書単位のアプリケーションショートカット)
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testHomeEndConsumeDecision() {
    using hazkey::ibus::HazkeyFrontend;
    using hazkey::ibus::HazkeyState;

    HazkeyFrontend::DecisionInput idle;
    idle.profileLoaded = true;
    idle.liveConvert = HazkeyState::parseHotkey("", "Control+Shift+L");
    idle.zenzaiToggle = HazkeyState::parseHotkey("", "Control+Alt+Z");
    idle.acceptPrediction = HazkeyState::parseHotkey("", "F5");
    idle.deleteLearning = HazkeyState::parseHotkey("", "Control+D");

    // 待機中:
    // テンキー版を含め、[Home] / [End]キーはアプリケーション側
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Home, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_End, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_KP_Home, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_KP_End, 0, idle));

    // 組成中:
    // IMEが所有し、開いた組成の下でアプリケーションのカーソルが動かないようにする
    auto composing = idle;
    composing.composing = true;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Home, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_End, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_KP_Home, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_KP_End, 0, composing));

    // [Left] / [Right]キーは従来どおり:
    // 待機中はアプリケーション側、組成中はIME側 (一時停止モードを駆動するカーソル移動キー)
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Right, 0, idle));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Left, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Right, 0, composing));

    // 組成中でも[Home] / [End]キーのモディファイア付きは、IMEのキーでない
    // ([Ctrl] + [Home]キーは、文書単位のアプリケーションショートカット)
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Home, IBUS_CONTROL_MASK, composing));

    std::cout << "[PASS] Home/End consumed only while composing\n";
}

/**
 * @brief 一時停止モード規則が共有モジュール由来であることを検証する
 *
 * 共有の一時停止モード規則こそIBusフロントエンドが使うべきものであり、独自再実装は両フロントエンドの乖離を招く
 *
 * 前提として末尾ではカーソルが末尾にあり、最終文字上や途中では末尾にないことを確認する
 * IBusは文字数オフセットを受け取るためかなは1文字ずつ数える
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testPauseModeRulesAreShared() {
    using hazkey::frontend::caretCharOffset;
    using hazkey::frontend::composingTextOf;
    using hazkey::frontend::ComposingTextWithCursor;
    using hazkey::frontend::cursorAtEnd;

    const ComposingTextWithCursor atEnd{"あいう", "", ""};
    assert(cursorAtEnd(atEnd));

    // 最終文字上は末尾ではないため、ライブ変換は一時停止のまま。
    const ComposingTextWithCursor onLast{"あい", "う", ""};
    assert(!cursorAtEnd(onLast));
    // IBus は文字数オフセットを受け取るため、かなは1文字ずつ数える。
    assert(caretCharOffset(onLast) == 2);
    assert(composingTextOf(onLast) == "あいう");

    const ComposingTextWithCursor middle{"あ", "い", "うえ"};
    assert(!cursorAtEnd(middle));
    assert(caretCharOffset(middle) == 1);
    assert(composingTextOf(middle) == "あいうえ");

    std::cout << "[PASS] pause-mode rules come from the shared module\n";
}

/**
 * @brief 未処理キーの転送時における押下とリリースの対付けを検証する
 *
 * ワーカーが処理しなかった押下は転送して覚え、対応するリリースと対にできる
 * IMEが消費した押下は転送しないため、そのリリースはアプリケーションへ届く幽霊キー押下にならないよう破棄する
 * 転送した押下の最初のリリースだけを転送し、異なるキーの押下とリリースは独立に対にして無関係なリリースが来ても保留中の押下は残る
 *
 * @internal 匿名名前空間内の実装専用テスト
 */
void testForwardedKeyPairing() {
    using hazkey::ibus::HazkeyFrontend;

    std::unordered_set<guint> pending;

    // ワーカーが処理しなかった押下は転送して覚え、対応するリリースと対にできる
    assert(HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_a, pending));
    assert(pending.count(IBUS_KEY_a) == 1);
    assert(HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_a, pending));
    assert(pending.empty());

    // IMEが消費した押下は転送しないため、そのリリースはアプリケーションへ届く
    // 幽霊キー押下にならないよう破棄する (端末に紛れ込むASCIIの退行)
    assert(!HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_b, pending));
    assert(pending.empty());

    // 転送した押下の最初のリリースだけを転送する
    assert(HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_c, pending));
    assert(HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_c, pending));
    assert(!HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_c, pending));

    // 異なるキーの押下とリリースは独立に対にし、無関係なリリースが来ても保留中の押下は残る
    assert(HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_d, pending));
    assert(HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_e, pending));
    assert(HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_e, pending));
    assert(pending.count(IBUS_KEY_d) == 1);
    assert(HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_d, pending));
    assert(pending.empty());

    std::cout << "[PASS] forwarded key press/release pairing\n";
}

}  // namespace

/**
 * @brief 全てのHazkeyState候補インデックステストを実行する
 *
 * 各テスト関数を順に呼び出し、全て通過すれば候補インデックス計算が正しいことを報告する
 *
 * @return 全テスト通過時は0
 */
int main() {
    testMultiPageResolution();
    testServerPageShapes();
    testInvalidInput();
    testLiveConvertModeTransition();
    testHotkeyParsingAndMatching();
    testAltDigitKeyPredicate();
    testDirectConversionShortcut();
    testAuxiliaryTextJoin();
    testZenzaiHintOverlay();
    testLiveConvertHintOverlay();
    testLoneShiftModifierState();
    testAltShiftSpaceOrTabPredicate();
    testSelectionLabels();
    testCapabilityAvailability();
    testLookupPageArithmetic();
    testConsumeDecision();
    testHomeEndConsumeDecision();
    testPauseModeRulesAreShared();
    testForwardedKeyPairing();
    std::cout << "\nAll HazkeyState candidate-index tests passed.\n";
    return 0;
}

// Tests for the IBus frontend's candidate index arithmetic.
//
// Mirrors fcitx5-hazkey/src/hazkey_candidate_selection_test.cpp for the IBus
// side: the IBusLookupTable carries candidates with a page-local selection
// index (number keys and candidate clicks), while the server's prefix-complete
// RPC takes a global index. HazkeyState::pageLocalToGlobalIndex() is the single
// pure mapping used by both selectDigit() and candidateClicked().
//
// No IBus daemon, engine instance, or hazkey-server is needed: only the pure
// static mapper is exercised, so this test cannot disturb a live session.
#include <cassert>
#include <iostream>
#include <unordered_set>

#include "hazkey_frontend.h"
#include "hazkey_state.h"
#include "live_convert_mode.h"

namespace {

using hazkey::ibus::HazkeyState;

void testMultiPageResolution() {
    // Given: 13 candidates displayed 5 at a time (pages 5 / 5 / 3).
    // When/Then: page 0 resolves locals 0..4 to globals 0..4, rejects local 5.
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 0, 0) == 0);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 0, 4) == 4);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 0, 5) == -1);

    // When/Then: page 1 (cursor 7) resolves locals 0..4 to globals 5..9.
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 0) == 5);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 2) == 7);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 4) == 9);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 7, 5) == -1);

    // When/Then: the final partial page (cursor 12 -> pageStart 10, 3
    // candidates) resolves locals 0..2 to globals 10..12; local 3 is a number
    // key for an absent slot and must NOT fall through to a later page.
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 12, 0) == 10);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 12, 2) == 12);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 12, 3) == -1);

    // Then: an out-of-range global cursor is rejected rather than wrapped.
    assert(HazkeyState::pageLocalToGlobalIndex(5, 13, 13, 0) == -1);

    std::cout << "[PASS] multi-page page-local -> global resolution\n";
}

void testServerPageShapes() {
    // Given: non-suggest conversion (page_size 9) with 10 candidates.
    // Then: key "0" (local 9) must not select the 10th candidate on page 0.
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 0, 8) == 8);
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 0, 9) == -1);

    // Then: page 1 of that list is a single candidate (global 9).
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 9, 0) == 9);
    assert(HazkeyState::pageLocalToGlobalIndex(9, 10, 9, 1) == -1);

    // Given: a suggest list (page_size 3) that exactly fills one page.
    assert(HazkeyState::pageLocalToGlobalIndex(3, 3, 0, 2) == 2);
    assert(HazkeyState::pageLocalToGlobalIndex(3, 3, 0, 3) == -1);

    std::cout << "[PASS] server page shapes (suggest/non-suggest)\n";
}

void testInvalidInput() {
    assert(HazkeyState::pageLocalToGlobalIndex(0, 5, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(-1, 5, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 0, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, -1, 0, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 5, -1, 0) == -1);
    assert(HazkeyState::pageLocalToGlobalIndex(5, 5, 0, -1) == -1);

    std::cout << "[PASS] invalid input rejected\n";
}

void testLiveConvertModeTransition() {
    // Port of fcitx5-hazkey's live_convert_mode policy (Phase C): the hotkey
    // only ever switches ON<->DISABLED and restores whichever ON mode was last
    // active.
    using M = hazkey::config::Profile_AutoConvertMode;
    using hazkey::ibus::computeNextAutoConvertMode;

    // Toggle OFF: remembers the current ON mode and returns DISABLED.
    M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
    assert(computeNextAutoConvertMode(
               M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS,
               remembered) == M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED);
    assert(remembered ==
           M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);

    // Toggle ON: restores the remembered mode without changing it.
    assert(computeNextAutoConvertMode(
               M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED,
               remembered) ==
           M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);
    assert(remembered ==
           M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);

    // ALWAYS is restored independently of FOR_MULTIPLE_CHARS.
    M rememberedAlways = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
    assert(computeNextAutoConvertMode(
               M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED,
               rememberedAlways) ==
           M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);

    std::cout << "[PASS] live-convert mode toggle transition\n";
}

void testHotkeyParsingAndMatching() {
    // fcitx5-style hotkey strings (written by hazkey-settings) parse into an
    // IBus keyval + exact modifier mask, with case-insensitive letter matching
    // and Mod4 folded into Super (Phase C loadServerProfile()).
    const auto live = HazkeyState::parseHotkey("Control+Shift+L", "F5");
    assert(live.keyval == IBUS_KEY_l);
    assert(live.modifiers == (IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));
    assert(HazkeyState::hotkeyMatches(
        IBUS_KEY_l, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK, live));
    // Uppercase keyvals (Shift+letter) match too.
    assert(HazkeyState::hotkeyMatches(
        IBUS_KEY_L, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK, live));
    // Exact modifier match: missing/extra modifiers do not match.
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_CONTROL_MASK, live));
    assert(!HazkeyState::hotkeyMatches(
        IBUS_KEY_l, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK | IBUS_MOD1_MASK,
        live));
    // Lock keys are ignored.
    assert(HazkeyState::hotkeyMatches(
        IBUS_KEY_l, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK | IBUS_LOCK_MASK,
        live));

    // Empty profile value falls back to the default string.
    const auto accept = HazkeyState::parseHotkey("", "F5");
    assert(accept.keyval == IBUS_KEY_F5);
    assert(accept.modifiers == 0);
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_F5, 0, accept));
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_F4, 0, accept));

    // Control+Alt+Z (Zenzai default).
    const auto zenzai = HazkeyState::parseHotkey("Control+Alt+Z", "F5");
    assert(zenzai.modifiers == (IBUS_CONTROL_MASK | IBUS_MOD1_MASK));
    assert(HazkeyState::hotkeyMatches(
        IBUS_KEY_z, IBUS_CONTROL_MASK | IBUS_MOD1_MASK, zenzai));

    // Super is matched whether the client reports SUPER or Mod4.
    const auto super = HazkeyState::parseHotkey("Super+L", "F5");
    assert(super.modifiers == IBUS_SUPER_MASK);
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_MOD4_MASK, super));
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_SUPER_MASK, super));

    // Modifier tokens are matched case-insensitively ("Ctrl" == "Control").
    const auto lower = HazkeyState::parseHotkey("ctrl+shift+l", "F5");
    assert(lower.keyval == IBUS_KEY_l);
    assert(lower.modifiers == (IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));

    // Qt PortableText spellings that differ from the IBus keysym names.
    assert(HazkeyState::parseHotkey("Space", "F5").keyval == IBUS_KEY_space);
    assert(HazkeyState::parseHotkey("PgUp", "F5").keyval == IBUS_KEY_Page_Up);
    assert(HazkeyState::parseHotkey("Esc", "F5").keyval == IBUS_KEY_Escape);

    // Meta keeps its own mask (distinct from Super).
    const auto meta = HazkeyState::parseHotkey("Meta+L", "F5");
    assert(meta.modifiers == IBUS_META_MASK);
    assert(HazkeyState::hotkeyMatches(IBUS_KEY_l, IBUS_META_MASK, meta));

    // Fail closed: an unknown token, more than one key token, or a missing
    // key token produces a spec that never matches.
    assert(HazkeyState::parseHotkey("Bogus+L", "F5").keyval == 0);
    assert(HazkeyState::parseHotkey("L+M", "F5").keyval == 0);
    assert(HazkeyState::parseHotkey("Control+Shift", "F5").keyval == 0);

    // An unparsable/empty spec never matches.
    const auto unset = HazkeyState::parseHotkey("", "");
    assert(unset.keyval == 0);
    assert(!HazkeyState::hotkeyMatches(IBUS_KEY_l, 0, unset));

    std::cout << "[PASS] hotkey parse/match\n";
}

void testAltDigitKeyPredicate() {
    // Alt+digit candidate selection (fcitx isAltDigitKeyEvent()): exactly Alt
    // plus 1..9. Alt+0 and any other modifier combination are not selections.
    for (guint k = IBUS_KEY_1; k <= IBUS_KEY_9; ++k) {
        assert(HazkeyState::isAltDigitKey(k, IBUS_MOD1_MASK));
    }
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_0, IBUS_MOD1_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1,
                                       IBUS_MOD1_MASK | IBUS_SHIFT_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1,
                                       IBUS_MOD1_MASK | IBUS_CONTROL_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, 0));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_a, IBUS_MOD1_MASK));
    // Lock keys are ignored like every other hotkey predicate.
    assert(HazkeyState::isAltDigitKey(IBUS_KEY_1,
                                      IBUS_MOD1_MASK | IBUS_LOCK_MASK));
    // Mod4 folds to Super, so Mod4+digit is not Alt.
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1, IBUS_MOD4_MASK));
    // AltGr-like Mod5 (ISO_Level3_Shift) / Mod3 are not part of "exactly Alt".
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1,
                                       IBUS_MOD1_MASK | IBUS_MOD5_MASK));
    assert(!HazkeyState::isAltDigitKey(IBUS_KEY_1,
                                       IBUS_MOD1_MASK | IBUS_MOD3_MASK));

    std::cout << "[PASS] Alt-digit predicate\n";
}

void testDirectConversionShortcut() {
    // Ctrl+U/I/O/P/T direct conversion (fcitx ctrlShortcutHandler()), matched
    // case-insensitively because clients report Ctrl+letter as the unshifted
    // lowercase keyval.
    const guint shortcuts[] = {IBUS_KEY_u, IBUS_KEY_i, IBUS_KEY_o, IBUS_KEY_p,
                               IBUS_KEY_t};
    for (guint k : shortcuts) {
        assert(HazkeyState::isDirectConversionShortcut(k, IBUS_CONTROL_MASK));
        assert(HazkeyState::isDirectConversionShortcut(
            k - 'a' + 'A', IBUS_CONTROL_MASK));
    }
    // Exact Ctrl only: Ctrl+Shift/Alt and no modifier are not shortcuts.
    assert(!HazkeyState::isDirectConversionShortcut(
        IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));
    assert(!HazkeyState::isDirectConversionShortcut(
        IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_MOD1_MASK));
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, 0));
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_u, IBUS_MOD1_MASK));
    // A non-shortcut letter stays with the application.
    assert(!HazkeyState::isDirectConversionShortcut(IBUS_KEY_x,
                                                    IBUS_CONTROL_MASK));
    // Lock keys are ignored.
    assert(HazkeyState::isDirectConversionShortcut(
        IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_LOCK_MASK));
    // AltGr-like Mod5 (ISO_Level3_Shift) / Mod3 are not part of "exactly Ctrl".
    assert(!HazkeyState::isDirectConversionShortcut(
        IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_MOD5_MASK));
    assert(!HazkeyState::isDirectConversionShortcut(
        IBUS_KEY_u, IBUS_CONTROL_MASK | IBUS_MOD3_MASK));

    std::cout << "[PASS] Ctrl direct-conversion shortcut predicate\n";
}

void testAuxiliaryTextJoin() {
    // fcitx has separate AuxUp/AuxDown panels; IBus has one aux slot, so the
    // two are joined by HazkeyState::joinAuxiliaryText(). The existing focused
    // display "[n/total] Deletable" must stay byte-identical.
    assert(HazkeyState::joinAuxiliaryText("[1/3]", "Deletable") ==
           "[1/3] Deletable");

    // Composing (unfocused): raw hiragana AuxUp + the Tab hint.
    assert(HazkeyState::joinAuxiliaryText("あい", "[Press Tab to Select]") ==
           "あい [Press Tab to Select]");

    // An EMPTY raw-hiragana AuxUp (auxTextMode disabled, or cursor at the end
    // of the composition) must not leave a leading space before AuxDown.
    assert(HazkeyState::joinAuxiliaryText("", "[Press Tab to Select]") ==
           "[Press Tab to Select]");
    assert(HazkeyState::joinAuxiliaryText("", "[Direct Input]") ==
           "[Direct Input]");

    // Only AuxUp present, or neither present.
    assert(HazkeyState::joinAuxiliaryText("あい", "") == "あい");
    assert(HazkeyState::joinAuxiliaryText("", "") == "");

    std::cout << "[PASS] auxiliary text join (no leading space when empty)\n";
}

void testLoneShiftModifierState() {
    // Drives whether a Shift release sends RELEASE (toggles Direct Input) or
    // CANCEL. A lone Shift must be detected even when the toolkit reports the
    // Shift KeyPress with the state sampled BEFORE Shift is applied (state 0).
    using hazkey::ibus::isLoneShiftModifierState;

    // Lone Shift, with or without the SHIFT bit present.
    assert(isLoneShiftModifierState(IBUS_SHIFT_MASK));
    assert(isLoneShiftModifierState(0));
    // Lock keys are ignored.
    assert(isLoneShiftModifierState(IBUS_SHIFT_MASK | IBUS_LOCK_MASK));

    // Any other modifier (present before Shift) means it is not lone.
    assert(!isLoneShiftModifierState(IBUS_CONTROL_MASK));
    assert(!isLoneShiftModifierState(IBUS_CONTROL_MASK | IBUS_SHIFT_MASK));
    assert(!isLoneShiftModifierState(IBUS_MOD1_MASK));
    assert(!isLoneShiftModifierState(IBUS_MOD1_MASK | IBUS_SHIFT_MASK));
    assert(!isLoneShiftModifierState(IBUS_SUPER_MASK));
    assert(!isLoneShiftModifierState(IBUS_META_MASK));
    // Mod4 folds into Super.
    assert(!isLoneShiftModifierState(IBUS_MOD4_MASK));
    // AltGr-like Mod5 / Mod3 disqualify a lone Shift.
    assert(!isLoneShiftModifierState(IBUS_SHIFT_MASK | IBUS_MOD5_MASK));
    assert(!isLoneShiftModifierState(IBUS_SHIFT_MASK | IBUS_MOD3_MASK));

    std::cout << "[PASS] lone-Shift modifier state predicate\n";
}

void testAltShiftSpaceOrTabPredicate() {
    // Given: Fcitx's exact Alt+Shift candidate-mode no-op combination.
    // When/Then: only Space and Tab with exactly Alt+Shift are consumed.
    const guint altShift = IBUS_MOD1_MASK | IBUS_SHIFT_MASK;
    assert(HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_space, altShift));
    assert(HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_Tab, altShift));
    // Shift+Tab is often reported as ISO_Left_Tab by IBus clients.
    assert(HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_ISO_Left_Tab, altShift));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_ISO_Left_Tab,
                                              IBUS_SHIFT_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(
        IBUS_KEY_space, altShift | IBUS_CONTROL_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(
        IBUS_KEY_Tab, altShift | IBUS_SUPER_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(
        IBUS_KEY_space, altShift | IBUS_MOD5_MASK));
    assert(!HazkeyState::isAltShiftSpaceOrTab(IBUS_KEY_Return, altShift));

    std::cout << "[PASS] Alt+Shift Space/Tab no-op predicate\n";
}

void testSelectionLabels() {
    // Given: IBus page-local slots matching fcitx defaultSelectionKeys.
    // When/Then: slots 0..9 receive 1..9,0 and all other indices are blank.
    for (int index = 0; index < 9; ++index) {
        assert(HazkeyState::selectionLabelForIndex(index) ==
               std::to_string(index + 1));
    }
    assert(HazkeyState::selectionLabelForIndex(9) == "0");
    assert(HazkeyState::selectionLabelForIndex(-1).empty());
    assert(HazkeyState::selectionLabelForIndex(10).empty());

    std::cout << "[PASS] Fcitx-compatible candidate selection labels\n";
}

void testCapabilityAvailability() {
    // Given: legacy clients that never call set_capabilities.
    // When/Then: retain the pre-existing all-capabilities behavior.
    assert(HazkeyState::capabilityIsAvailable(
        0, false, IBUS_CAP_SURROUNDING_TEXT));

    // Given: an explicit capability set.
    // When/Then: only advertised features are available.
    assert(HazkeyState::capabilityIsAvailable(
        IBUS_CAP_SURROUNDING_TEXT, true, IBUS_CAP_SURROUNDING_TEXT));
    assert(!HazkeyState::capabilityIsAvailable(
        IBUS_CAP_PREEDIT_TEXT, true, IBUS_CAP_SURROUNDING_TEXT));

    std::cout << "[PASS] capability availability gate\n";
}

// The lookup table is now built on the main loop, so its round=FALSE
// page/cursor movement is re-implemented as pure arithmetic. These assertions
// pin the behavior to IBus's ibus_lookup_table_{page,cursor}_{up,down}().
void testLookupPageArithmetic() {
    // Cursor wrap (round=FALSE -> the caller wraps to first/last).
    assert(HazkeyState::advanceCursorIndex(0, 3) == 1);
    assert(HazkeyState::advanceCursorIndex(2, 3) == 0);
    assert(HazkeyState::advanceCursorIndex(-1, 3) == 0);
    assert(HazkeyState::advanceCursorIndex(0, 0) == 0);
    assert(HazkeyState::backCursorIndex(0, 3) == 2);
    assert(HazkeyState::backCursorIndex(2, 3) == 1);
    assert(HazkeyState::backCursorIndex(-1, 3) == 0);

    // 13 candidates, 5 per page -> pages [0..4][5..9][10..12].
    assert(HazkeyState::nextPageStart(0, 5, 13) == 5);
    assert(HazkeyState::nextPageStart(4, 5, 13) == 5);
    assert(HazkeyState::nextPageStart(7, 5, 13) == 10);
    // Already on the last page: stay on this page's start.
    assert(HazkeyState::nextPageStart(12, 5, 13) == 10);

    // On the last page, prevPage subtracts one page size from the cursor and
    // then normalizes to that page's start (IBus page_up semantics).
    assert(HazkeyState::prevPageStart(12, 5) == 5);
    assert(HazkeyState::prevPageStart(7, 5) == 0);
    assert(HazkeyState::prevPageStart(3, 5) == 0);

    std::cout << "[PASS] lookup page/cursor arithmetic\n";
}

// The synchronous consume decision must be conservative but precise for the
// common cases: it may return TRUE for a key the worker later forwards, but it
// must never return FALSE for a key an active composition/candidate list owns.
void testConsumeDecision() {
    using hazkey::ibus::HazkeyFrontend;
    using hazkey::ibus::HazkeyState;

    HazkeyFrontend::DecisionInput idle;
    idle.profileLoaded = true;
    idle.liveConvert = HazkeyState::parseHotkey("", "Control+Shift+L");
    idle.zenzaiToggle = HazkeyState::parseHotkey("", "Control+Alt+Z");
    idle.acceptPrediction = HazkeyState::parseHotkey("", "F5");
    idle.deleteLearning = HazkeyState::parseHotkey("", "Control+D");

    // Printable keys are always IME-owned.
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_a, 0, idle));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_space, 0, idle));
    // Idle Return/Escape/arrows belong to the application.
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Return, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Escape, 0, idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Left, 0, idle));
    // Release and Shift are never consumed.
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_a, IBUS_RELEASE_MASK,
                                             idle));
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_Shift_L, 0, idle));
    // A non-shortcut control combo stays with the application.
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_c, IBUS_CONTROL_MASK,
                                             idle));

    auto composing = idle;
    composing.composing = true;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Return, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Escape, 0, composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_u, IBUS_CONTROL_MASK,
                                            composing));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_1, IBUS_MOD1_MASK,
                                            composing));
    // Alt+digit is not a selection without a composition.
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_1, IBUS_MOD1_MASK, idle));

    auto candidate = idle;
    candidate.listFocused = true;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_d, IBUS_CONTROL_MASK,
                                            candidate));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_3, 0, candidate));
    // Candidate mode handles its navigation/commit keys BEFORE the Control
    // branch (mirrors HazkeyState::candidateKeyEvent), so Ctrl+Return and
    // Ctrl+F6 are IME keys...
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_Return, IBUS_CONTROL_MASK,
                                            candidate));
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_F6, IBUS_CONTROL_MASK,
                                            candidate));
    // ...while Ctrl+<letter> is not a shortcut and belongs to the application.
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_x, IBUS_CONTROL_MASK,
                                             candidate));
    // Alt+letter is forwarded to the application in candidate mode.
    assert(!HazkeyFrontend::decideConsumeKey(IBUS_KEY_x, IBUS_MOD1_MASK,
                                             candidate));

    // Before the profile loads, any modifier combo is provisionally consumed.
    HazkeyFrontend::DecisionInput unloaded;
    assert(HazkeyFrontend::decideConsumeKey(IBUS_KEY_c, IBUS_CONTROL_MASK,
                                            unloaded));

    std::cout << "[PASS] synchronous consume decision\n";
}

void testForwardedKeyPairing() {
    using hazkey::ibus::HazkeyFrontend;

    std::unordered_set<guint> pending;

    // A press the worker did not handle is forwarded and remembered, so its own
    // release can be paired with it.
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_a, pending));
    assert(pending.count(IBUS_KEY_a) == 1);
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_a, pending));
    assert(pending.empty());

    // A press the IME consumed is never forwarded, so its release must be
    // dropped instead of reaching the application as a phantom key press (this
    // is the stray-ASCII-in-a-terminal regression).
    assert(
        !HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_b, pending));
    assert(pending.empty());

    // Only the first release of a forwarded press is forwarded.
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_c, pending));
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_c, pending));
    assert(
        !HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_c, pending));

    // Presses and releases of different keys are paired independently, and a
    // pending press survives an unrelated release.
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_d, pending));
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(false, IBUS_KEY_e, pending));
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_e, pending));
    assert(pending.count(IBUS_KEY_d) == 1);
    assert(
        HazkeyFrontend::shouldForwardUnhandledKey(true, IBUS_KEY_d, pending));
    assert(pending.empty());

    std::cout << "[PASS] forwarded key press/release pairing\n";
}

}  // namespace

int main() {
    testMultiPageResolution();
    testServerPageShapes();
    testInvalidInput();
    testLiveConvertModeTransition();
    testHotkeyParsingAndMatching();
    testAltDigitKeyPredicate();
    testDirectConversionShortcut();
    testAuxiliaryTextJoin();
    testLoneShiftModifierState();
    testAltShiftSpaceOrTabPredicate();
    testSelectionLabels();
    testCapabilityAvailability();
    testLookupPageArithmetic();
    testConsumeDecision();
    testForwardedKeyPairing();
    std::cout << "\nAll HazkeyState candidate-index tests passed.\n";
    return 0;
}

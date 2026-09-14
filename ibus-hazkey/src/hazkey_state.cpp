#include "hazkey_state.h"

#include <algorithm>

#include "live_convert_mode.h"

// Supported ibus floor is 1.5.32 (Debian 13 Trixie; Fedora 44 and openSUSE
// Leap 16 ship 1.5.34 / 1.5.33). IBUS_ATTR_TYPE_HINT, which lets the panel
// render the preedit selection with its own styling, exists only since
// 1.5.33, so it is applied opportunistically. On 1.5.32 the selection is
// still visible through the plain IBUS_ATTR_TYPE_UNDERLINE attribute that
// every guarded site sets unconditionally next to the hint.
#if IBUS_CHECK_VERSION(1, 5, 33)
#define HAZKEY_IBUS_HAS_ATTR_TYPE_HINT 1
#else
#define HAZKEY_IBUS_HAS_ATTR_TYPE_HINT 0
#endif

namespace hazkey::ibus {

namespace {

HazkeyServerConnector& sharedServerConnector() {
    static HazkeyServerConnector connector;
    return connector;
}

// gettext lookup in the engine's own domain (installed as
// <datadir>/locale/<lang>/LC_MESSAGES/ibus-hazkey.mo). The IBus panel uses the
// same domain for the engine <longname>/<description>.
const char* tr(const char* messageId) {
    return g_dgettext("ibus-hazkey", messageId);
}

// IBus clients/toolkits report Super under different masks (X11 commonly sends
// Mod4). Fold Mod4 into IBUS_SUPER_MASK so a "Super" hotkey matches either
// encoding, and ignore lock keys (CapsLock / NumLock).
guint normalizeHotkeyModifiers(guint state) {
    guint modifiers =
        state & (IBUS_SHIFT_MASK | IBUS_CONTROL_MASK | IBUS_MOD1_MASK |
                 IBUS_MOD4_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK |
                 IBUS_META_MASK);
    if ((modifiers & IBUS_MOD4_MASK) != 0) {
        // Replace (not OR) Mod4 so a "Super" spec matches a Mod4-encoded event
        // and vice versa.
        modifiers &= ~IBUS_MOD4_MASK;
        modifiers |= IBUS_SUPER_MASK;
    }
    return modifiers;
}

// hazkey-settings stores hotkeys as fcitx5 key strings with an uppercase key
// letter (e.g. "Control+D"); IBus reports Ctrl+letter as the unshifted
// lowercase keyval on most clients. Compare letters case-insensitively.
guint normalizeHotkeyKeyval(guint keyval) {
    if (keyval >= 'A' && keyval <= 'Z') {
        return keyval - 'A' + 'a';
    }
    return keyval;
}

// Mod3 (Mode_switch) / Mod5 (ISO_Level3_Shift = AltGr) are keysym-group
// selectors, not part of the fcitx KeyState set the exact-modifier predicates
// model. Rejecting them keeps "exactly Alt" / "exactly Ctrl" honest: e.g.
// AltGr+digit must not be read as an Alt+digit candidate selection, and
// Ctrl+AltGr+U must not be read as the Ctrl+U direct conversion.
bool hasAltGrLikeModifier(guint state) {
    return (state & (IBUS_MOD3_MASK | IBUS_MOD5_MASK)) != 0;
}

std::string asciiLower(const std::string& value) {
    std::string lowered = value;
    for (char& c : lowered) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    return lowered;
}

// Qt QKeySequence::PortableText (what hazkey-settings stores) spells some
// keys differently from the X11/IBus keysym names accepted by
// ibus_keyval_from_name(). Map the differing spellings; everything else
// (letters, digits, F1-F35, arrows) is looked up directly.
guint keyvalFromHotkeyToken(const std::string& token) {
    static const struct {
        const char* qt;
        const char* keysym;
    } kAliases[] = {
        {"Space", "space"},        {"Esc", "Escape"},
        {"Backspace", "BackSpace"}, {"Enter", "Return"},
        {"Ins", "Insert"},         {"Del", "Delete"},
        {"PgUp", "Page_Up"},       {"PgDown", "Page_Down"},
        {"CapsLock", "Caps_Lock"}, {"NumLock", "Num_Lock"},
        {"ScrollLock", "Scroll_Lock"},
    };
    for (const auto& alias : kAliases) {
        if (token == alias.qt) {
            return ibus_keyval_from_name(alias.keysym);
        }
    }
    return ibus_keyval_from_name(token.c_str());
}

}  // namespace

bool isLoneShiftModifierState(guint state) {
    const guint heldModifiers = normalizeHotkeyModifiers(state);
    return (heldModifiers == IBUS_SHIFT_MASK || heldModifiers == 0) &&
           !hasAltGrLikeModifier(state);
}

HazkeyState::HazkeyState(IBusEngine* engine)
    : engine_(engine), server_(sharedServerConnector()) {
    // Seed the built-in defaults so the hotkeys still work if the first
    // getServerConfig() is slow or fails; loadServerProfile() overwrites them
    // once the server profile is available.
    liveConvertHotkey_ = parseHotkey("", "Control+Shift+L");
    acceptPredictionHotkey_ = parseHotkey("", "F5");
    zenzaiToggleHotkey_ = parseHotkey("", "Control+Alt+Z");
    deleteLearningHotkey_ = parseHotkey("", "Control+D");
    // The server composition is NOT reset here: newComposingText() is sent
    // from resetState() on focusIn()/enable(), so constructing a state for a
    // non-focused input context cannot clobber the shared singleton
    // connector's live composition.
}

HazkeyState::~HazkeyState() {
    // A pending coalesced refresh must never fire after the state is gone.
    cancelPendingRefresh();
    g_clear_object(&lookupTable_);
}

HazkeyState::HotkeySpec HazkeyState::parseHotkey(
    const std::string& keyString, const std::string& fallback) {
    const std::string& spec = keyString.empty() ? fallback : keyString;
    HotkeySpec hotkey;
    bool sawKeyToken = false;
    bool invalid = false;
    size_t position = 0;
    while (position <= spec.size()) {
        const size_t next = spec.find('+', position);
        const std::string token =
            spec.substr(position, next == std::string::npos
                                      ? std::string::npos
                                      : next - position);
        if (!token.empty()) {
            const std::string lowered = asciiLower(token);
            if (lowered == "control" || lowered == "ctrl") {
                hotkey.modifiers |= IBUS_CONTROL_MASK;
            } else if (lowered == "shift") {
                hotkey.modifiers |= IBUS_SHIFT_MASK;
            } else if (lowered == "alt" || lowered == "mod1") {
                hotkey.modifiers |= IBUS_MOD1_MASK;
            } else if (lowered == "super") {
                hotkey.modifiers |= IBUS_SUPER_MASK;
            } else if (lowered == "meta") {
                hotkey.modifiers |= IBUS_META_MASK;
            } else if (lowered == "hyper") {
                hotkey.modifiers |= IBUS_HYPER_MASK;
            } else if (sawKeyToken) {
                invalid = true;  // a hotkey has exactly one non-modifier key
            } else {
                const guint keyval = keyvalFromHotkeyToken(token);
                if (keyval == 0 || keyval == IBUS_KEY_VoidSymbol) {
                    invalid = true;
                } else {
                    hotkey.keyval = normalizeHotkeyKeyval(keyval);
                    sawKeyToken = true;
                }
            }
        }
        if (next == std::string::npos) {
            break;
        }
        position = next + 1;
    }
    if (!sawKeyToken || invalid) {
        return HotkeySpec{};  // fail closed: a malformed spec never matches
    }
    return hotkey;
}

bool HazkeyState::hotkeyMatches(guint keyval, guint state,
                                const HotkeySpec& hotkey) {
    if (hotkey.keyval == 0) {
        return false;
    }
    if (normalizeHotkeyKeyval(keyval) != hotkey.keyval) {
        return false;
    }
    return normalizeHotkeyModifiers(state) == hotkey.modifiers;
}

bool HazkeyState::isAltDigitKey(guint keyval, guint state) {
    // fcitx's isAltDigitKeyEvent() requires KeyState::Alt exactly (so Alt+Shift
    // / Ctrl+Alt are not selections) and a 1-9 symbol (Alt+0 selects nothing).
    // AltGr-like modifiers are not part of that set (see hasAltGrLikeModifier).
    // normalizeHotkeyModifiers() folds Mod4->Super and drops lock keys, which
    // is the same normalization hotkeyMatches() uses.
    if (hasAltGrLikeModifier(state)) {
        return false;
    }
    if (normalizeHotkeyModifiers(state) != IBUS_MOD1_MASK) {
        return false;
    }
    return keyval >= IBUS_KEY_1 && keyval <= IBUS_KEY_9;
}

bool HazkeyState::isDirectConversionShortcut(guint keyval, guint state) {
    // fcitx's ctrlShortcutHandler() is reached only for KeyState::Ctrl exactly;
    // AltGr-like modifiers keep the key with the application.
    if (hasAltGrLikeModifier(state)) {
        return false;
    }
    if (normalizeHotkeyModifiers(state) != IBUS_CONTROL_MASK) {
        return false;
    }
    switch (normalizeHotkeyKeyval(keyval)) {
        case IBUS_KEY_u:
        case IBUS_KEY_i:
        case IBUS_KEY_o:
        case IBUS_KEY_p:
        case IBUS_KEY_t:
            return true;
        default:
            return false;
    }
}

std::string HazkeyState::joinAuxiliaryText(const std::string& auxUp,
                                           const std::string& auxDown) {
    // IBus exposes a single auxiliary-text slot where fcitx has separate AuxUp
    // and AuxDown panels, so the two are joined here. The separator is a single
    // space ONLY when both parts are non-empty: an empty raw-hiragana AuxUp
    // (auxTextMode disabled, or the cursor at the end of the composition)
    // must not leave a leading space before AuxDown.
    if (auxUp.empty()) {
        return auxDown;
    }
    if (auxDown.empty()) {
        return auxUp;
    }
    return auxUp + " " + auxDown;
}

gboolean HazkeyState::processKeyEvent(guint keyval, guint keycode,
                                      guint state) {
    (void)keycode;
    const gboolean isRelease = (state & IBUS_RELEASE_MASK) != 0;
    const gboolean shiftKey =
        (keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R);
    if (isRelease) {
        if (shiftKey) {
            // A lone Shift tap toggles the server's sub-input (direct) mode, so
            // the AuxDown "[Direct Input]" indicator must be recomputed now
            // instead of staying stale until the next key event. fcitx's
            // keyEvent() likewise calls setAuxDownText() on its Shift branch
            // before returning, and shiftKeyEvent() invalidates the connector
            // cache so currentInputModeIsDirect() below reads the new mode.
            server_.shiftKeyEvent(true, shiftPressedAlone_);
            shiftPressedAlone_ = false;
            updateAuxiliaryText();
        }
        return FALSE;
    }
    if (shiftKey) {
        // "Lone Shift" = no modifier other than Shift is active. Do NOT require
        // the SHIFT bit itself to be present: a modifier key's own KeyPress is
        // often reported with the state sampled *before* that modifier is
        // applied, so `state` can legitimately be 0 here for a lone Shift.
        shiftPressedAlone_ = isLoneShiftModifierState(state);
        server_.shiftKeyEvent(false);
        return FALSE;
    }
    shiftPressedAlone_ = false;

    if (!serverProfileLoaded_) {
        loadServerProfile();
    }

    // Global toggles are matched before the modifier-passthrough filter so a
    // configured Control/Alt combo is consumed by hazkey rather than forwarded.
    if (hotkeyMatches(keyval, state, liveConvertHotkey_)) {
        handleLiveConvertToggle();
        updateAuxiliaryText();
        return TRUE;
    }
    if (hotkeyMatches(keyval, state, zenzaiToggleHotkey_)) {
        handleZenzaiToggle();
        return TRUE;
    }

    const std::string composingText = server_.getComposingText(
        hazkey::commands::GetComposingString_CharType_HIRAGANA, preeditText_);

    gboolean handled = FALSE;
    if (listVisible_ && cursorIndex_ >= 0) {
        // The focused candidate list owns the modifier combinations it needs
        // (learning-data delete), so it is dispatched before the filter below.
        handled = candidateKeyEvent(keyval, state);
    } else if (!composingText.empty() && isAltDigitKey(keyval, state)) {
        // Unfocused suggest list: fcitx's preeditKeyEvent() Alt-digit branch
        // resolves the deferred refresh, then completes the page-local
        // candidate. The key is consumed even when the digit names no
        // candidate, matching fcitx's filterAndAccept().
        selectPageLocalAltDigit(keyval, /*flushFirst=*/true);
        handled = TRUE;
    } else if (!composingText.empty() &&
               isDirectConversionShortcut(keyval, state)) {
        // fcitx's preeditKeyEvent() default branch routes an exact Ctrl combo
        // to ctrlShortcutHandler(): Ctrl+U/I/O/P/T converts the composition in
        // place. Handled before the modifier passthrough below, which would
        // otherwise forward it to the application.
        ctrlShortcutHandler(keyval);
        handled = TRUE;
    } else if ((state & (IBUS_CONTROL_MASK | IBUS_MOD1_MASK |
                         IBUS_SUPER_MASK | IBUS_HYPER_MASK | IBUS_META_MASK |
                         IBUS_MOD4_MASK)) != 0) {
        return FALSE;
    } else if (!composingText.empty()) {
        handled = preeditKeyEvent(keyval, state);
    } else {
        handled = noPreeditKeyEvent(keyval, state);
    }

    if (handled) {
        updateAuxiliaryText();
    }
    return handled;
}

gboolean HazkeyState::noPreeditKeyEvent(guint keyval, guint state) {
    const gboolean shift = (state & IBUS_SHIFT_MASK) != 0;
    if (keyval == IBUS_KEY_space) {
        if (shift) {
            commitText(" ");
            resetState();
        } else {
            updateSurroundingText();
            server_.inputChar(" ");
            commitText(server_.getComposingText(
                hazkey::commands::GetComposingString_CharType_HIRAGANA, ""));
            resetState();
        }
        return TRUE;
    }
    if (isInputableKey(keyval)) {
        updateSurroundingText();
        server_.inputChar(utf8FromKeyval(keyval));
        // Display-only refresh: coalesce rapid successive keystrokes (the
        // inputChar RPC above stays synchronous/ordered).
        scheduleCandidateRefresh(/*isSuggest=*/true);
        return TRUE;
    }
    return FALSE;
}

gboolean HazkeyState::preeditKeyEvent(guint keyval, guint state) {
    const gboolean shift = (state & IBUS_SHIFT_MASK) != 0;
    switch (keyval) {
        case IBUS_KEY_Return:
        case IBUS_KEY_KP_Enter:
        case IBUS_KEY_ISO_Enter:
            commitPreedit();
            if (livePreeditIndex_ >= 0) {
                server_.completePrefix(livePreeditIndex_);
            }
            resetState();
            return TRUE;
        case IBUS_KEY_BackSpace:
            server_.deleteLeft();
            showPreeditCandidateList();
            return TRUE;
        case IBUS_KEY_Delete:
            server_.deleteRight();
            showPreeditCandidateList();
            return TRUE;
        case IBUS_KEY_F6:
        case IBUS_KEY_F7:
        case IBUS_KEY_F8:
        case IBUS_KEY_F9:
        case IBUS_KEY_F10:
            functionKeyHandler(keyval);
            return TRUE;
        case IBUS_KEY_Escape:
            resetState();
            return TRUE;
        case IBUS_KEY_space:
            if (!isDirectConversionMode_ && shift) {
                updateSurroundingText();
                server_.inputChar(" ");
                // Display-only refresh: coalesce (see
                // scheduleCandidateRefresh()).
                scheduleCandidateRefresh(/*isSuggest=*/true);
            } else {
                showNonPredictCandidateList();
            }
            return TRUE;
        case IBUS_KEY_Henkan:
            showNonPredictCandidateList();
            return TRUE;
        case IBUS_KEY_Up:
        case IBUS_KEY_Down:
        case IBUS_KEY_Tab:
            if (!listVisible_) {
                showNonPredictCandidateList();
            } else {
                focusCandidates();
            }
            return TRUE;
        case IBUS_KEY_ISO_Left_Tab:
            showNonPredictCandidateList();
            return TRUE;
        case IBUS_KEY_Left:
            if (shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(false);
            } else {
                // fcitx's preeditKeyEvent() only records the cursor move; it
                // does NOT refresh the candidate list. The visible effect is
                // the AuxUp raw-hiragana cursor, updated by the keyEvent tail
                // (updateAuxiliaryText()).
                isCursorMoving_ = true;
                server_.moveCursor(-1);
            }
            return TRUE;
        case IBUS_KEY_Right:
            if (shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(true);
            } else if (isCursorMoving_) {
                // Same as Left: move only, no candidate-list refresh.
                server_.moveCursor(1);
            }
            return TRUE;
        default:
            break;
    }
    if (isInputableKey(keyval)) {
        if (isDirectConversionMode_) {
            commitPreedit();
            resetState();
        }
        updateSurroundingText();
        server_.inputChar(utf8FromKeyval(keyval));
        // Display-only refresh: coalesce (see
        // scheduleCandidateRefresh()).
        scheduleCandidateRefresh(/*isSuggest=*/true);
        return TRUE;
    }
    return FALSE;
}

gboolean HazkeyState::candidateKeyEvent(guint keyval, guint state) {
    const gboolean shift = (state & IBUS_SHIFT_MASK) != 0;
    const gboolean control = (state & IBUS_CONTROL_MASK) != 0;

    // [community] Learning-data delete must be checked before the generic
    // Ctrl passthrough, otherwise Ctrl+D is forwarded to the application.
    if (hotkeyMatches(keyval, state, deleteLearningHotkey_)) {
        handleDeleteCandidateLearningData(cursorIndex_);
        return TRUE;
    }

    // [community] Accept only focused suggest-mode candidates. Unlike Return,
    // this preserves the composition and refreshes it from the server.
    if (currentListIsSuggest_ &&
        hotkeyMatches(keyval, state, acceptPredictionHotkey_)) {
        server_.acceptPrediction(cursorIndex_);
        showPreeditCandidateList();
        return TRUE;
    }

    // [community] Alt+1..9 selects the page-local candidate, mirroring fcitx's
    // candidateKeyEvent() isAltDigitKeyEvent() branch. Checked before the
    // Alt/Super passthrough guard below, which would otherwise forward it.
    if (isAltDigitKey(keyval, state)) {
        selectPageLocalAltDigit(keyval, /*flushFirst=*/false);
        return TRUE;
    }

    // Non-hotkey modifier combinations (Alt/Super/Meta/Hyper) belong to the
    // application. fcitx's isInputableEvent() accepts only unmodified simple
    // keys, so without this guard Alt+A / Super+A would fall through to
    // isInputableKey() and be typed into the composition. Control is left to
    // the per-case handling below to match fcitx's candidate navigation.
    if ((state & (IBUS_MOD1_MASK | IBUS_SUPER_MASK | IBUS_MOD4_MASK |
                  IBUS_META_MASK | IBUS_HYPER_MASK)) != 0) {
        return FALSE;
    }

    switch (keyval) {
        case IBUS_KEY_Right:
            if (shift) {
                moveSegmentBoundary(true);
            } else {
                nextPage();
            }
            return TRUE;
        case IBUS_KEY_Left:
            if (shift) {
                moveSegmentBoundary(false);
            } else {
                prevPage();
            }
            return TRUE;
        case IBUS_KEY_Return:
        case IBUS_KEY_KP_Enter:
        case IBUS_KEY_ISO_Enter:
            if (cursorIndex_ >= 0) {
                completeCandidate(cursorIndex_);
            }
            return TRUE;
        case IBUS_KEY_Escape:
            if (isClauseBoundaryAdjusting_) {
                showNonPredictCandidateList();
                return TRUE;
            }
            isClauseBoundaryAdjusting_ = false;
            [[fallthrough]];
        case IBUS_KEY_BackSpace:
            isClauseBoundaryAdjusting_ = false;
            showPreeditCandidateList();
            return TRUE;
        case IBUS_KEY_space:
        case IBUS_KEY_Tab:
            if (shift) {
                backCandidateCursor();
            } else {
                advanceCandidateCursor();
            }
            return TRUE;
        case IBUS_KEY_ISO_Left_Tab:
            backCandidateCursor();
            return TRUE;
        case IBUS_KEY_Down:
            advanceCandidateCursor();
            return TRUE;
        case IBUS_KEY_Up:
            backCandidateCursor();
            return TRUE;
        case IBUS_KEY_F6:
        case IBUS_KEY_F7:
        case IBUS_KEY_F8:
        case IBUS_KEY_F9:
        case IBUS_KEY_F10:
            functionKeyHandler(keyval);
            return TRUE;
        default:
            break;
    }
    if (control) {
        // fcitx's candidateKeyEvent() routes an exact Ctrl combo through
        // ctrlShortcutHandler(): the direct-conversion shortcuts are consumed,
        // any other Ctrl key is forwarded to the application. Ctrl + another
        // modifier (including AltGr-like Mod3/Mod5) is not an exact Ctrl combo
        // and is forwarded unchanged.
        if (!hasAltGrLikeModifier(state) &&
            normalizeHotkeyModifiers(state) == IBUS_CONTROL_MASK) {
            return ctrlShortcutHandler(keyval) ? TRUE : FALSE;
        }
        return FALSE;
    }
    if (selectDigit(keyval)) {
        return TRUE;
    }
    if (isInputableKey(keyval)) {
        // Resolve a deferred refresh before capturing/committing, or the
        // committed text and surrounding-text update would lag.
        flushPendingRefresh();
        const std::string committed = preeditText_;
        commitPreedit();
        resetState();
        updateSurroundingText(committed);
        server_.inputChar(utf8FromKeyval(keyval));
        showPreeditCandidateList();
        return TRUE;
    }
    return FALSE;
}

void HazkeyState::loadServerProfile() {
    const auto configOpt = server_.getServerConfig();
    if (!configOpt.has_value() || configOpt->profiles_size() == 0) {
        return;  // server not ready; keep defaults
    }
    const auto& profile = configOpt->profiles(0);
    liveConvertHotkey_ =
        parseHotkey(profile.auto_convert_hotkey(), "Control+Shift+L");
    acceptPredictionHotkey_ =
        parseHotkey(profile.accept_prediction_hotkey(), "F5");
    zenzaiToggleHotkey_ =
        parseHotkey(profile.zenzai_toggle_hotkey(), "Control+Alt+Z");
    deleteLearningHotkey_ =
        parseHotkey(profile.delete_learning_hotkey(), "Control+D");
    cachedAutoConvertMode_ = profile.auto_convert_mode();
    using M = hazkey::config::Profile_AutoConvertMode;
    // Only update the remembered "ON" mode when the server's mode is not
    // DISABLED. When DISABLED (e.g. after a previous hotkey toggle-off), keep
    // the previous remembered value so toggle-on restores the right mode.
    // rememberedOnMode_ lives on the connector (shared across input contexts)
    // so it survives focus changes between applications.
    if (cachedAutoConvertMode_ !=
        M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED) {
        server_.rememberedOnMode() = cachedAutoConvertMode_;
    }
    serverProfileLoaded_ = true;
}

void HazkeyState::handleLiveConvertToggle() {
    const auto prevMode = cachedAutoConvertMode_;
    auto& sharedRemembered = server_.rememberedOnMode();
    const auto prevRemembered = sharedRemembered;

    cachedAutoConvertMode_ =
        computeNextAutoConvertMode(cachedAutoConvertMode_, sharedRemembered);

    const auto configOpt = server_.getServerConfig();
    if (!configOpt.has_value() || configOpt->profiles_size() == 0) {
        cachedAutoConvertMode_ = prevMode;
        sharedRemembered = prevRemembered;
        return;
    }

    auto config = configOpt.value();
    config.mutable_profiles(0)->set_auto_convert_mode(cachedAutoConvertMode_);
    if (!server_.setServerConfig(config)) {
        cachedAutoConvertMode_ = prevMode;
        sharedRemembered = prevRemembered;
        return;
    }

    const std::string composingText = server_.getComposingText(
        hazkey::commands::GetComposingString_CharType_HIRAGANA, preeditText_);
    if (composingText.empty()) {
        return;
    }
    showCandidateList(true);
}

void HazkeyState::handleZenzaiToggle() {
    const auto enabled = server_.toggleZenzai();
    if (!enabled.has_value()) {
        return;
    }
    // IBus has no transient input-method popup; the auxiliary text is the
    // closest equivalent and lasts until the next key event overwrites it.
    setAuxiliaryText(tr(enabled.value() ? "Zenzai enabled"
                                        : "Zenzai disabled"));
}

void HazkeyState::handleDeleteCandidateLearningData(int globalIndex) {
    const auto result = server_.deleteCandidateLearningData(globalIndex);
    if (!result.has_value() || result->deleted_count == 0) {
        return;
    }
    if (currentListIsSuggest_) {
        // Suggest-mode list: rebuild from live_text (same display as before),
        // then re-focus the first candidate like the Tab-focus path does.
        if (!applyCandidateResponse(result->candidates, std::nullopt, true)) {
            return;
        }
        cursorIndex_ = 0;
        updateCandidateCursor();
    } else {
        showNonPredictCandidateList(result->candidates, result->hiragana);
    }
}

void HazkeyState::functionKeyHandler(guint keyval) {
    switch (keyval) {
        case IBUS_KEY_F6:
            directCharactorConversion(ConversionMode::Hiragana);
            break;
        case IBUS_KEY_F7:
            directCharactorConversion(ConversionMode::KatakanaFullwidth);
            break;
        case IBUS_KEY_F8:
            directCharactorConversion(ConversionMode::KatakanaHalfwidth);
            break;
        case IBUS_KEY_F9:
            directCharactorConversion(ConversionMode::RawFullwidth);
            break;
        case IBUS_KEY_F10:
            directCharactorConversion(ConversionMode::RawHalfwidth);
            break;
        default:
            return;
    }
    isDirectConversionMode_ = true;
}

void HazkeyState::directCharactorConversion(ConversionMode mode) {
    // Resolve a deferred refresh: the conversion below reads preeditText_,
    // which would otherwise be stale.
    flushPendingRefresh();
    const std::string converted =
        server_.getComposingText(charTypeFor(mode), preeditText_);
    livePreeditIndex_ = -1;
    preeditText_ = converted;
    if (converted.empty()) {
        hidePreedit();
    } else {
        // fcitx's setSimplePreeditHighlighted() highlights the whole string
        // and puts the preedit cursor at its START (cursorSegment=0), unlike
        // the normal (unhighlighted) preedit whose cursor is at the end.
        setPreeditHighlighted(converted);
    }
    if (listVisible_ || lookupTable_ != nullptr) {
        candidates_.clear();
        pageSize_ = 0;
        cursorIndex_ = -1;
        listVisible_ = false;
        currentListIsSuggest_ = false;
        clearLookupTable();
    }
}

bool HazkeyState::ctrlShortcutHandler(guint keyval) {
    // Port of fcitx5-hazkey's fcitx::HazkeyState::ctrlShortcutHandler():
    // u -> Hiragana, i -> KatakanaFullwidth, o -> KatakanaHalfwidth,
    // p -> RawFullwidth, t -> RawHalfwidth. The caller only reaches this for an
    // exact Ctrl combo (see isDirectConversionShortcut()).
    switch (normalizeHotkeyKeyval(keyval)) {
        case IBUS_KEY_u:
            directCharactorConversion(ConversionMode::Hiragana);
            break;
        case IBUS_KEY_i:
            directCharactorConversion(ConversionMode::KatakanaFullwidth);
            break;
        case IBUS_KEY_o:
            directCharactorConversion(ConversionMode::KatakanaHalfwidth);
            break;
        case IBUS_KEY_p:
            directCharactorConversion(ConversionMode::RawFullwidth);
            break;
        case IBUS_KEY_t:
            directCharactorConversion(ConversionMode::RawHalfwidth);
            break;
        default:
            return false;
    }
    // Same effect as functionKeyHandler()'s direct-conversion entry.
    isDirectConversionMode_ = true;
    return true;
}

void HazkeyState::moveSegmentBoundary(bool expand) {
    const auto result = server_.adjustClauseBoundary(expand ? 1 : -1);
    if (!result.has_value()) {
        isClauseBoundaryAdjusting_ = false;
        return;
    }
    isClauseBoundaryAdjusting_ = true;
    showNonPredictCandidateList(result->candidates, result->hiragana);
}

hazkey::commands::GetComposingString::CharType HazkeyState::charTypeFor(
    ConversionMode mode) {
    switch (mode) {
        case ConversionMode::Hiragana:
            return hazkey::commands::GetComposingString_CharType_HIRAGANA;
        case ConversionMode::KatakanaFullwidth:
            return hazkey::commands::GetComposingString_CharType_KATAKANA_FULL;
        case ConversionMode::KatakanaHalfwidth:
            return hazkey::commands::GetComposingString_CharType_KATAKANA_HALF;
        case ConversionMode::RawFullwidth:
            return hazkey::commands::GetComposingString_CharType_ALPHABET_FULL;
        case ConversionMode::RawHalfwidth:
            return hazkey::commands::GetComposingString_CharType_ALPHABET_HALF;
    }
    return hazkey::commands::GetComposingString_CharType_HIRAGANA;
}

bool HazkeyState::showCandidateList(bool isSuggest) {
    return applyCandidateResponse(server_.getCandidates(isSuggest),
                                  std::nullopt, isSuggest);
}

bool HazkeyState::applyCandidateResponse(
    const hazkey::commands::CandidatesResult& response,
    const std::optional<std::string>& fallback, bool isSuggest) {
    currentListIsSuggest_ = isSuggest;
    candidates_.clear();
    for (const auto& c : response.candidates()) {
        HazkeyCandidate cand;
        cand.text = c.text();
        cand.subHiragana = c.sub_hiragana();
        cand.hasLearningEntry = c.has_learning_entry();
        candidates_.push_back(std::move(cand));
    }
    pageSize_ = 0;
    const int rawPageSize = static_cast<int>(response.page_size());

    std::string display;
    if (cachedAutoConvertMode_ !=
            hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED &&
        !response.live_text().empty()) {
        display = response.live_text();
    } else if (fallback.has_value()) {
        display = *fallback;
    } else {
        display = server_.getComposingText(
            hazkey::commands::GetComposingString_CharType_HIRAGANA,
            preeditText_);
    }
    preeditText_ = display;
    const glong charLen = g_utf8_strlen(display.c_str(), -1);
    // Pin the preedit cursor to composition start (0) so IBus anchors there;
    // at composition end it follows live-conversion width and the panel flaps.
    // fcitx5-hazkey matches this because fcitx-gtk clamps its unset cursor to 0.
    setPreeditUnderline(display, 0, charLen, 0);

    livePreeditIndex_ = response.live_text_index();

    const bool hasCandidates = rawPageSize > 0 && !candidates_.empty();
    if (hasCandidates) {
        pageSize_ = std::clamp(rawPageSize, 1, 16);
        rebuildLookupTable();
        cursorIndex_ = -1;
        listVisible_ = true;
        pushLookupTable();
        return true;
    }
    pageSize_ = 0;
    clearLookupTable();
    cursorIndex_ = -1;
    listVisible_ = false;
    return false;
}

void HazkeyState::showPreeditCandidateList() {
    if (server_
            .getComposingText(
                hazkey::commands::GetComposingString_CharType_HIRAGANA,
                preeditText_)
            .empty()) {
        resetState();
        return;
    }
    showCandidateList(true);
}

/// Candidate refresh coalescing
//
// Mirrors fcitx5-hazkey's HazkeyState::scheduleCandidateRefresh /
// firePendingCandidateRefresh (see
// hazkey-frontend-common/candidate_refresh_coalescer.h for the pure
// leading-edge + latest-wins trailing debounce policy). Only the timer adapter
// is frontend-specific: fcitx5 owns an EventSourceTime on its event loop, IBus
// owns a GLib timeout here.
//
// Coalescing applies ONLY to the display-only refresh that follows a
// state-mutating inputChar (the three inputable-key sites), exactly like
// fcitx5. Candidate navigation, paging, clause-boundary adjustment, commit,
// backspace/delete and reset stay synchronous. Because processKeyEvent() and
// the timeout callback both run on the single GLib main-loop thread, no
// locking is needed.

void HazkeyState::scheduleCandidateRefresh(bool isSuggest) {
    pendingRefreshIsSuggest_ = isSuggest;
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());

    // Leading edge: nothing pending and the previous refresh is older than one
    // quiet period, so execute now with zero added latency.
    if (refreshCoalescer_.shouldRunImmediately(
            nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // An armed timeout must not survive an immediate run: onRun() consumes
        // the pending slot, so the old callback would be a stale duplicate.
        if (refreshTimerId_ != 0) {
            g_source_remove(refreshTimerId_);
            refreshTimerId_ = 0;
        }
        refreshCoalescer_.onRun(nowUsec);
        runPendingCandidateRefresh();
        return;
    }

    if (refreshCoalescer_.shouldSchedule(
            nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // Latest-wins: removing the previous source before arming the new one
        // makes the newest request own the deadline, so a burst collapses into
        // one trailing execution instead of firing once per keystroke.
        if (refreshTimerId_ != 0) {
            g_source_remove(refreshTimerId_);
            refreshTimerId_ = 0;
        }
        refreshTimerId_ = g_timeout_add(
            static_cast<guint>(
                hazkey::frontend::kCandidateRefreshCoalesceUsec / 1000),
            &HazkeyState::onCandidateRefreshTimeout, this);
    }
}

gboolean HazkeyState::onCandidateRefreshTimeout(gpointer data) {
    auto* self = static_cast<HazkeyState*>(data);
    // This source is firing and is about to be removed (G_SOURCE_REMOVE), so
    // clear the id before doing work that could re-arm a timer.
    self->refreshTimerId_ = 0;
    self->firePendingCandidateRefresh();
    return G_SOURCE_REMOVE;
}

void HazkeyState::firePendingCandidateRefresh() {
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());
    if (!refreshCoalescer_.shouldFire(nowUsec)) {
        // Defensive: GLib timers are not expected to fire early, but if one
        // did, keep the pending refresh alive rather than dropping it.
        if (refreshCoalescer_.hasPending()) {
            const uint64_t remaining =
                refreshCoalescer_.pendingDeadlineUsec() - nowUsec;
            guint ms = static_cast<guint>((remaining + 999) / 1000);
            if (ms == 0) {
                ms = 1;
            }
            refreshTimerId_ = g_timeout_add(
                ms, &HazkeyState::onCandidateRefreshTimeout, this);
        }
        return;
    }
    refreshCoalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
}

void HazkeyState::runPendingCandidateRefresh() {
    executingPendingRefresh_ = true;
    if (pendingRefreshIsSuggest_) {
        showPreeditCandidateList();
    } else {
        showNonPredictCandidateList();
    }
    executingPendingRefresh_ = false;
}

void HazkeyState::cancelPendingRefresh() {
    if (refreshTimerId_ != 0) {
        g_source_remove(refreshTimerId_);
        refreshTimerId_ = 0;
    }
    // resetPolicy() (not onCancel()): a new composition epoch must not inherit
    // the previous epoch's run timestamp, or its first refresh would be
    // deferred by a full quiet period.
    refreshCoalescer_.resetPolicy();
}

// Runs a pending coalesced refresh immediately instead of discarding it, so a
// caller that is about to CONSUME preeditText_ (Return commit, focus-out
// commit, direct conversion) acts on the latest server state rather than the
// stale last-synchronously-refreshed value. Without this, a keystroke deferred
// inside the coalesce window is dropped from the committed text (e.g.
// a i u e o followed by an immediate Return previously committed only the
// leading edge's first character).
void HazkeyState::flushPendingRefresh() {
    if (!refreshCoalescer_.hasPending()) {
        return;
    }
    // Drop the armed timeout first so onRun() below owns the slot and no stale
    // callback can fire afterwards.
    if (refreshTimerId_ != 0) {
        g_source_remove(refreshTimerId_);
        refreshTimerId_ = 0;
    }
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());
    refreshCoalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
}

void HazkeyState::showNonPredictCandidateList() {
    // A pending deferred suggest refresh must not fire after this and overwrite
    // the non-predict list (exempted while the coalescer executes its own
    // pending refresh, which may legitimately be a non-predict one).
    if (!executingPendingRefresh_) {
        cancelPendingRefresh();
    }
    server_.moveCursor(1024);
    isClauseBoundaryAdjusting_ = false;
    if (!showCandidateList(false)) {
        return;
    }
    livePreeditIndex_ = -1;
    cursorIndex_ = 0;
    updateCandidateCursor();
}

void HazkeyState::showNonPredictCandidateList(
    const hazkey::commands::CandidatesResult& response,
    const std::string& hiragana) {
    if (!executingPendingRefresh_) {
        cancelPendingRefresh();
    }
    if (!applyCandidateResponse(response, hiragana, false)) {
        return;
    }
    livePreeditIndex_ = -1;
    cursorIndex_ = 0;
    updateCandidateCursor();
}

void HazkeyState::focusCandidates() {
    // Resolve a deferred display refresh first so the focused list reflects
    // every committed keystroke.
    flushPendingRefresh();
    if (listVisible_ && cursorIndex_ < 0) {
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    if (!listVisible_) {
        // The refresh cleared the suggest list; fall back to a non-predict
        // conversion instead of swallowing the focus key.
        showNonPredictCandidateList();
    }
}

void HazkeyState::updateCandidateCursor() {
    if (cursorIndex_ < 0 ||
        cursorIndex_ >= static_cast<int>(candidates_.size())) {
        return;
    }
    const HazkeyCandidate& c = candidates_[static_cast<size_t>(cursorIndex_)];
    preeditText_ = c.text + c.subHiragana;
    const glong totalChars = g_utf8_strlen(preeditText_.c_str(), -1);
    IBusText* t = ibus_text_new_from_string(preeditText_.c_str());
    if (c.subHiragana.empty()) {
        // fcitx renders this single segment highlighted (cursorSegment=0), so
        // mark it as the preedit selection rather than only underlining it.
        if (totalChars > 0) {
#if HAZKEY_IBUS_HAS_ATTR_TYPE_HINT
            ibus_text_append_attribute(t, IBUS_ATTR_TYPE_HINT,
                                       IBUS_ATTR_PREEDIT_SELECTION, 0,
                                       static_cast<guint>(totalChars));
#endif
            ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                       IBUS_ATTR_UNDERLINE_SINGLE, 0,
                                       static_cast<guint>(totalChars));
        }
    } else {
        // The underline marks the conversion TARGET segment (c.text); the
        // trailing reading (c.subHiragana) is intentionally left plain. The
        // IBUS_ATTR_TYPE_HINT selection below is a panel-only hint that
        // client-side-preedit apps (GTK/Qt) ignore, so the explicit underline
        // is what actually shows the target there.
        const glong candChars = g_utf8_strlen(c.text.c_str(), -1);
#if HAZKEY_IBUS_HAS_ATTR_TYPE_HINT
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_HINT,
                                   IBUS_ATTR_PREEDIT_SELECTION, 0,
                                   static_cast<guint>(candChars));
#endif
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE, 0,
                                   static_cast<guint>(candChars));
    }
    ibus_engine_update_preedit_text(engine_, t, 0, TRUE);
    pushLookupTable();
}

void HazkeyState::advanceCandidateCursor() {
    if (lookupTable_ == nullptr) {
        return;
    }
    if (cursorIndex_ < 0) {
        // Shown but unfocused: fcitx's moveCursor() focuses the first
        // candidate instead of advancing from an implicit position.
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    if (!ibus_lookup_table_cursor_down(lookupTable_)) {
        // round=FALSE stops at the last candidate; fcitx's nextCandidate()
        // wraps around to the first.
        ibus_lookup_table_set_cursor_pos(lookupTable_, 0);
    }
    cursorIndex_ =
        static_cast<int>(ibus_lookup_table_get_cursor_pos(lookupTable_));
    updateCandidateCursor();
}

void HazkeyState::backCandidateCursor() {
    if (lookupTable_ == nullptr) {
        return;
    }
    if (cursorIndex_ < 0) {
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    if (!ibus_lookup_table_cursor_up(lookupTable_)) {
        // round=FALSE stops at the first candidate; fcitx's prevCandidate()
        // wraps around to the last.
        ibus_lookup_table_set_cursor_pos(
            lookupTable_, static_cast<guint>(candidates_.size() - 1));
    }
    cursorIndex_ =
        static_cast<int>(ibus_lookup_table_get_cursor_pos(lookupTable_));
    updateCandidateCursor();
}

void HazkeyState::nextPage() {
    if (lookupTable_ == nullptr || pageSize_ <= 0) {
        return;
    }
    if (!ibus_lookup_table_page_down(lookupTable_)) {
        // round=FALSE: already on the last page. fcitx's next() is a no-op
        // there and nextPage() then resets the cursor to this page's first
        // candidate.
        const int cursorPos =
            static_cast<int>(ibus_lookup_table_get_cursor_pos(lookupTable_));
        const int pageStart = (cursorPos / pageSize_) * pageSize_;
        ibus_lookup_table_set_cursor_pos(lookupTable_,
                                         static_cast<guint>(pageStart));
        cursorIndex_ = pageStart;
        updateCandidateCursor();
        return;
    }
    const int cursorPos =
        static_cast<int>(ibus_lookup_table_get_cursor_pos(lookupTable_));
    const int pageStart = (cursorPos / pageSize_) * pageSize_;
    ibus_lookup_table_set_cursor_pos(lookupTable_,
                                     static_cast<guint>(pageStart));
    cursorIndex_ = pageStart;
    updateCandidateCursor();
}

void HazkeyState::prevPage() {
    if (lookupTable_ == nullptr || pageSize_ <= 0) {
        return;
    }
    if (!ibus_lookup_table_page_up(lookupTable_)) {
        // round=FALSE: already on the first page; fcitx resets the cursor to
        // this page's first candidate.
        const int cursorPos =
            static_cast<int>(ibus_lookup_table_get_cursor_pos(lookupTable_));
        const int pageStart = (cursorPos / pageSize_) * pageSize_;
        ibus_lookup_table_set_cursor_pos(lookupTable_,
                                         static_cast<guint>(pageStart));
        cursorIndex_ = pageStart;
        updateCandidateCursor();
        return;
    }
    const int cursorPos =
        static_cast<int>(ibus_lookup_table_get_cursor_pos(lookupTable_));
    const int pageStart = (cursorPos / pageSize_) * pageSize_;
    ibus_lookup_table_set_cursor_pos(lookupTable_,
                                     static_cast<guint>(pageStart));
    cursorIndex_ = pageStart;
    updateCandidateCursor();
}

int HazkeyState::pageLocalToGlobalIndex(int pageSize, int totalSize,
                                        int cursorPos, int localIndex) {
    if (pageSize <= 0 || totalSize <= 0 || cursorPos < 0 ||
        cursorPos >= totalSize || localIndex < 0) {
        return -1;
    }
    const int page = cursorPos / pageSize;
    const int pageStart = page * pageSize;
    const int pageCount = std::min(pageSize, totalSize - pageStart);
    if (localIndex >= pageCount) {
        return -1;
    }
    return pageStart + localIndex;
}

bool HazkeyState::selectDigit(guint keyval) {
    int local = -1;
    if (keyval == IBUS_KEY_0) {
        local = 9;
    } else if (keyval >= IBUS_KEY_1 && keyval <= IBUS_KEY_9) {
        local = static_cast<int>(keyval - IBUS_KEY_1);
    } else {
        return false;
    }
    if (cursorIndex_ < 0) {
        return false;
    }
    const int global = pageLocalToGlobalIndex(
        pageSize_, static_cast<int>(candidates_.size()), cursorIndex_, local);
    if (global < 0) {
        return false;
    }
    cursorIndex_ = global;
    completeCandidate(global);
    return true;
}

void HazkeyState::selectPageLocalAltDigit(guint keyval, bool flushFirst) {
    // Port of fcitx's Alt-digit selection. candidateKeyEvent() selects from the
    // list it was dispatched with (no flush); preeditKeyEvent() first resolves
    // a deferred coalesced refresh so the selection is not made against a stale
    // list. Both pick the page-local slot the digit names.
    if (flushFirst) {
        flushPendingRefresh();
    }
    if (!listVisible_ || candidates_.empty() || pageSize_ <= 0) {
        return;
    }
    if (keyval < IBUS_KEY_1 || keyval > IBUS_KEY_9) {
        return;
    }
    // An unfocused list is on page 0 (IBus hides the cursor and leaves the
    // lookup-table cursor at 0; fcitx's unfocused list is likewise on the
    // first page until focused). A focused list resolves the page from the
    // current global cursor position, like HazkeyCandidateList::setCursorIndex.
    const int cursorPos = cursorIndex_ >= 0 ? cursorIndex_ : 0;
    const int local = static_cast<int>(keyval - IBUS_KEY_1);
    const int global = pageLocalToGlobalIndex(
        pageSize_, static_cast<int>(candidates_.size()), cursorPos, local);
    if (global < 0) {
        return;
    }
    cursorIndex_ = global;
    completeCandidate(global);
}

void HazkeyState::completeCandidate(int globalIndex) {
    if (globalIndex < 0 ||
        globalIndex >= static_cast<int>(candidates_.size())) {
        return;
    }
    const HazkeyCandidate cand =
        candidates_[static_cast<size_t>(globalIndex)];
    updateSurroundingText(cand.text);
    server_.completePrefix(globalIndex);
    hidePreedit();
    commitText(cand.text);
    if (!cand.subHiragana.empty()) {
        showNonPredictCandidateList();
    } else {
        resetState();
    }
}

void HazkeyState::rebuildLookupTable() {
    g_clear_object(&lookupTable_);
    if (candidates_.empty() || pageSize_ <= 0) {
        return;
    }
    IBusLookupTable* table =
        ibus_lookup_table_new(static_cast<guint>(pageSize_), 0, FALSE, FALSE);
    for (const auto& c : candidates_) {
        ibus_lookup_table_append_candidate(
            table, ibus_text_new_from_string(c.text.c_str()));
    }
    g_object_ref_sink(table);
    lookupTable_ = table;
}

void HazkeyState::pushLookupTable() {
    if (lookupTable_ == nullptr || candidates_.empty()) {
        ibus_engine_hide_lookup_table(engine_);
        return;
    }
    const guint n = static_cast<guint>(candidates_.size());
    guint pos = 0;
    if (cursorIndex_ >= 0 && static_cast<guint>(cursorIndex_) < n) {
        pos = static_cast<guint>(cursorIndex_);
    }
    ibus_lookup_table_set_cursor_pos(lookupTable_, pos);
    ibus_lookup_table_set_cursor_visible(lookupTable_, cursorIndex_ >= 0);
    ibus_engine_update_lookup_table(engine_, lookupTable_, TRUE);
}

void HazkeyState::clearLookupTable() {
    g_clear_object(&lookupTable_);
    ibus_engine_hide_lookup_table(engine_);
}

void HazkeyState::resetState() {
    // A pending coalesced refresh must not fire after this reset (which is
    // also the focus-out/disable/enable path); cancel it explicitly, matching
    // fcitx5's HazkeyState::reset().
    cancelPendingRefresh();
    isCursorMoving_ = false;
    isDirectConversionMode_ = false;
    isClauseBoundaryAdjusting_ = false;
    livePreeditIndex_ = -1;
    candidates_.clear();
    pageSize_ = 0;
    cursorIndex_ = -1;
    listVisible_ = false;
    currentListIsSuggest_ = false;
    preeditText_.clear();
    clearLookupTable();
    hidePreedit();
    setAuxiliaryText("");
    server_.newComposingText();
}

void HazkeyState::commitText(const std::string& text) {
    IBusText* t = ibus_text_new_from_string(text.c_str());
    ibus_engine_commit_text(engine_, t);
}

void HazkeyState::hidePreedit() { ibus_engine_hide_preedit_text(engine_); }

void HazkeyState::commitPreedit() {
    // Resolve a deferred display refresh first: focus-out/disable/commit would
    // otherwise commit the stale last-synchronously-refreshed preedit.
    flushPendingRefresh();
    if (!preeditText_.empty()) {
        commitText(preeditText_);
    }
    hidePreedit();
}

void HazkeyState::setPreeditUnderline(const std::string& text, glong startChar,
                                      glong endChar, guint cursorChar) {
    IBusText* t = ibus_text_new_from_string(text.c_str());
    if (endChar > startChar) {
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE,
                                   static_cast<guint>(startChar),
                                   static_cast<guint>(endChar));
    }
    ibus_engine_update_preedit_text(engine_, t, cursorChar, TRUE);
}

void HazkeyState::setPreeditHighlighted(const std::string& text) {
    // Mirrors fcitx HazkeyPreedit::setSimplePreeditHighlighted(): the whole
    // string is highlighted (selection) and the preedit cursor sits at its
    // start.
    IBusText* t = ibus_text_new_from_string(text.c_str());
    const glong charLen = g_utf8_strlen(text.c_str(), -1);
    if (charLen > 0) {
#if HAZKEY_IBUS_HAS_ATTR_TYPE_HINT
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_HINT,
                                   IBUS_ATTR_PREEDIT_SELECTION, 0,
                                   static_cast<guint>(charLen));
#endif
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE, 0,
                                   static_cast<guint>(charLen));
    }
    ibus_engine_update_preedit_text(engine_, t, 0, TRUE);
}

void HazkeyState::setAuxiliaryText(const std::string& text) {
    IBusText* aux = ibus_text_new_from_string(text.c_str());
    ibus_engine_update_auxiliary_text(engine_, aux, !text.empty());
}

void HazkeyState::setAuxiliaryTextWithCursor(const std::string& auxUp,
                                             glong underlineStart,
                                             glong underlineEnd,
                                             const std::string& auxDown) {
    const std::string text = joinAuxiliaryText(auxUp, auxDown);
    IBusText* aux = ibus_text_new_from_string(text.c_str());
    // The raw-hiragana AuxUp underlines the character under the server cursor,
    // the IBus counterpart of fcitx's Underline TextFormatFlag on onCursor (see
    // composingTextWithCursorToFcitxText() in the fcitx adapter). The offsets
    // are UTF-8 character offsets and AuxUp is a prefix of the joined text, so
    // they need no shift. Panels that ignore aux attributes simply render the
    // plain bytes, which are always the full before+onCursor+after string.
    if (underlineStart >= 0 && underlineEnd > underlineStart) {
        ibus_text_append_attribute(aux, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE,
                                   static_cast<guint>(underlineStart),
                                   static_cast<guint>(underlineEnd));
    }
    ibus_engine_update_auxiliary_text(engine_, aux, !text.empty());
}

void HazkeyState::updateAuxiliaryText() {
    // Mirrors fcitx5's keyEvent() tail. AuxUp is "[n/total]" while a candidate
    // list is focused (fcitx setCandidateCursorAUX), otherwise the raw hiragana
    // with the server cursor when a composition exists (fcitx setHiraganaAUX).
    // AuxDown is "[Direct Input]" in direct-input mode, "Deletable" for a
    // focused candidate backed by learning data, or "[Press Tab to Select]"
    // while composing (fcitx setAuxDownText); direct-input wins over the hint,
    // exactly like fcitx's setAuxDownText() checks it first.
    const bool focused =
        listVisible_ && cursorIndex_ >= 0 &&
        cursorIndex_ < static_cast<int>(candidates_.size());

    std::string auxDown;
    if (server_.currentInputModeIsDirect()) {
        auxDown = tr("[Direct Input]");
    } else if (focused) {
        if (candidates_[static_cast<size_t>(cursorIndex_)].hasLearningEntry) {
            auxDown = tr("Deletable");
        }
    } else if (!preeditText_.empty()) {
        auxDown = tr("[Press Tab to Select]");
    }

    if (focused) {
        const std::string auxUp = "[" + std::to_string(cursorIndex_ + 1) + "/" +
                                  std::to_string(candidates_.size()) + "]";
        setAuxiliaryTextWithCursor(auxUp, -1, -1, auxDown);
        return;
    }
    if (!preeditText_.empty()) {
        // The transport caches this read. The server returns three empty fields
        // when auxTextMode is auxTextDisabled, or auxTextShowWhenCursorNotAtEnd
        // with the cursor at the end (with auxTextAlways the raw hiragana is
        // shown even then); in the empty cases joinAuxiliaryText() yields
        // AuxDown alone, without a leading space.
        const auto parts = server_.getComposingHiraganaWithCursor();
        const glong beforeChars = g_utf8_strlen(parts.before.c_str(), -1);
        const glong onCursorChars = g_utf8_strlen(parts.onCursor.c_str(), -1);
        setAuxiliaryTextWithCursor(parts.toString(), beforeChars,
                                   beforeChars + onCursorChars, auxDown);
        return;
    }
    // Not composing and not direct: fcitx clears both AuxUp and AuxDown.
    setAuxiliaryText(joinAuxiliaryText("", auxDown));
}

void HazkeyState::updateSurroundingText(const std::string& append) {
    if (hasSurroundingText_) {
        const glong n = g_utf8_strlen(append.c_str(), -1);
        server_.setContext(surroundingText_ + append,
                           static_cast<int>(surroundingAnchor_ + n));
    } else {
        server_.setContext("", 0);
    }
}

void HazkeyState::clearSurroundingText() {
    surroundingText_.clear();
    surroundingAnchor_ = 0;
    hasSurroundingText_ = false;
}

void HazkeyState::focusIn() { resetState(); }

void HazkeyState::focusOut() {
    flushPendingRefresh();
    if (!preeditText_.empty()) {
        commitPreedit();
    }
    clearSurroundingText();
    resetState();
}

void HazkeyState::reset() {
    clearSurroundingText();
    resetState();
}

void HazkeyState::enable() {
    resetState();
    ibus_engine_get_surrounding_text(engine_, nullptr, nullptr, nullptr);
}

void HazkeyState::disable() {
    flushPendingRefresh();
    if (!preeditText_.empty()) {
        commitPreedit();
    }
    clearSurroundingText();
    resetState();
}

void HazkeyState::setCursorLocation(gint x, gint y, gint w, gint h) {
    cursorX_ = x;
    cursorY_ = y;
    cursorW_ = w;
    cursorH_ = h;
}

void HazkeyState::setSurroundingText(IBusText* text, guint cursorIndex,
                                     guint anchorPos) {
    (void)cursorIndex;
    surroundingText_ =
        (text != nullptr) ? ibus_text_get_text(text) : "";
    surroundingAnchor_ = anchorPos;
    hasSurroundingText_ = true;
}

void HazkeyState::pageUp() {
    flushPendingRefresh();
    prevPage();
    updateAuxiliaryText();
}

void HazkeyState::pageDown() {
    flushPendingRefresh();
    nextPage();
    updateAuxiliaryText();
}

void HazkeyState::cursorUp() {
    flushPendingRefresh();
    backCandidateCursor();
    updateAuxiliaryText();
}

void HazkeyState::cursorDown() {
    flushPendingRefresh();
    advanceCandidateCursor();
    updateAuxiliaryText();
}

void HazkeyState::candidateClicked(guint index, guint button, guint state) {
    (void)button;
    (void)state;
    // A click on a list rendered before a still-pending display refresh would
    // commit a stale candidate and drop the trailing input. Resolve the
    // pending refresh and drop this stale click; the refreshed list is then
    // shown for the user to click again.
    if (refreshCoalescer_.hasPending()) {
        flushPendingRefresh();
        return;
    }
    if (pageSize_ <= 0 || candidates_.empty()) {
        return;
    }
    const guint tablePos =
        lookupTable_ != nullptr
            ? ibus_lookup_table_get_cursor_pos(lookupTable_)
            : 0;
    const int global =
        pageLocalToGlobalIndex(pageSize_,
                               static_cast<int>(candidates_.size()),
                               static_cast<int>(tablePos),
                               static_cast<int>(index));
    if (global < 0) {
        return;
    }
    cursorIndex_ = global;
    completeCandidate(global);
}

bool HazkeyState::isInputableKey(guint keyval) const {
    if (keyval == IBUS_KEY_space) {
        return true;
    }
    if (keyval >= 0x04a1 && keyval <= 0x04df) {
        return true;
    }
    const gunichar ch = ibus_keyval_to_unicode(keyval);
    if (ch == 0 || !g_unichar_validate(ch)) {
        return false;
    }
    if (g_unichar_iscntrl(ch)) {
        return false;
    }
    return true;
}

std::string HazkeyState::utf8FromKeyval(guint keyval) {
    const gunichar ch = ibus_keyval_to_unicode(keyval);
    if (ch == 0 || !g_unichar_validate(ch)) {
        return "";
    }
    char buf[8];
    const int n = g_unichar_to_utf8(ch, buf);
    return std::string(buf, static_cast<size_t>(n));
}

}  // namespace hazkey::ibus

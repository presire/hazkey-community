#include "hazkey_state.h"

#include <algorithm>
#include <functional>
#include <utility>

#include "composing_cursor_view.h"
#include "hazkey_frontend_hooks.h"
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
    // autoConnect=false: the connector is first touched on the worker thread,
    // so constructing it must not run the blocking connect loop on the GLib
    // main loop (engine construction calls this via HazkeyState).
    static HazkeyServerConnector connector(/*autoConnect=*/false);
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

// How long the transient toggle hint stays in the auxiliary-text slot.
// Matches fcitx5's showInputMethodInformation() overlay (instance.cpp:
// now(CLOCK_MONOTONIC) + 1000000, i.e. 1 second) and ibus-rime's
// RIME_STATUS_HINT_TIMEOUT_MS. Used by both the Zenzai toggle and the
// live-conversion toggle.
constexpr uint64_t kTransientHintTimeoutUsec = 1'000'000;

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

HazkeyState::HazkeyState(std::shared_ptr<HazkeyUi> ui,
                         hazkey::frontend::SerialTaskExecutor* executor)
    : ui_(std::move(ui)), executor_(executor), server_(sharedServerConnector()) {
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
    // A pending delayed refresh must never run after the state is gone. The
    // destructor runs only once no worker task still references this object
    // (tasks hold a shared_ptr), so cancelling the token here is sufficient.
    cancelPendingRefresh();
    cancelPendingHint();
    // No IBus/GObject is owned here: the shared HazkeyUi owns (and retires)
    // them on the main loop.
}

void HazkeyState::postUi(std::function<void(HazkeyUi&)> fn) {
    auto ui = ui_;
    hazkey::frontend::postToMainLoop(
        [ui, fn = std::move(fn)]() mutable {
            if (ui) {
                fn(*ui);
            }
        });
}

HazkeyState::IngressSnapshot HazkeyState::ingressSnapshot() const {
    IngressSnapshot snapshot;
    snapshot.composing = !preeditText_.empty() || listVisible_;
    snapshot.listFocused = listVisible_ && cursorIndex_ >= 0;
    snapshot.profileLoaded = serverProfileLoaded_;
    snapshot.liveConvert = liveConvertHotkey_;
    snapshot.zenzaiToggle = zenzaiToggleHotkey_;
    snapshot.acceptPrediction = acceptPredictionHotkey_;
    snapshot.deleteLearning = deleteLearningHotkey_;
    return snapshot;
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

bool HazkeyState::isAltShiftSpaceOrTab(guint keyval, guint state) {
    // IBus clients report Shift+Tab as IBUS_KEY_ISO_Left_Tab; treat it as Tab
    // so the candidate-mode Alt+Shift no-op also covers that encoding (without
    // Alt, ISO_Left_Tab keeps its own back-navigation branch).
    if (keyval != IBUS_KEY_space && keyval != IBUS_KEY_Tab &&
        keyval != IBUS_KEY_ISO_Left_Tab) {
        return false;
    }
    return !hasAltGrLikeModifier(state) &&
           normalizeHotkeyModifiers(state) ==
               (IBUS_MOD1_MASK | IBUS_SHIFT_MASK);
}

std::string HazkeyState::selectionLabelForIndex(int localIndex) {
    if (localIndex >= 0 && localIndex <= 8) {
        return std::to_string(localIndex + 1);
    }
    if (localIndex == 9) {
        return "0";
    }
    return "";
}

bool HazkeyState::capabilityIsAvailable(guint caps, bool capsKnown,
                                        guint capability) {
    return !capsKnown || (caps & capability) != 0;
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
            updateInputModeProperty();
            updateAuxiliaryText();
        } else {
            // Fcitx refreshes AuxDown on releases too; keep IBus's collapsed
            // auxiliary text current even when the application receives this key.
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

    if (!serverProfileLoaded_ || server_.consumeConfigChanged()) {
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
        case IBUS_KEY_Muhenkan:
            // Fcitx routes FcitxKey_Muhenkan to functionKeyHandler() from
            // preeditKeyEvent(); functionKeyHandler() has no Muhenkan branch,
            // so it is a consumed no-op. Keep the same shape here.
            functionKeyHandler(keyval);
            return TRUE;
        case IBUS_KEY_Escape:
            resetState();
            return TRUE;
        case IBUS_KEY_space:
            if (!isDirectConversionMode_ && shift) {
                updateSurroundingText();
                server_.inputChar(" ");
                refreshAfterComposingEdit();
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
                moveComposingCursor(-1);
            }
            return TRUE;
        case IBUS_KEY_Right:
            if (shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(true);
            } else {
                moveComposingCursor(1);
            }
            return TRUE;
        // [community] Home/End are always consumed while composing, so they
        // move the composition cursor instead of the application's. Previously
        // they fell through to the facade's forward path and moved the
        // APPLICATION's cursor mid-composition, which fcitx5 never did.
        case IBUS_KEY_Home:
        case IBUS_KEY_KP_Home:
            moveComposingCursor(-1024);
            return TRUE;
        case IBUS_KEY_End:
        case IBUS_KEY_KP_End:
            moveComposingCursor(1024);
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
        refreshAfterComposingEdit();
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

    // Fcitx consumes exactly Alt+Shift Space/Tab as a no-op in candidate mode.
    // Keep it before the generic Alt/Super passthrough so it cannot reach the
    // application or navigate the lookup table.
    if (isAltShiftSpaceOrTab(keyval, state)) {
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
    cachedAuxTextMode_ = profile.aux_text_mode();
    updateZenzaiProperty(profile.zenzai_enable());
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

    // Feedback for the toggle, mirroring the Zenzai hint. The new mode is
    // DISABLED on toggle-off, or the restored ON mode on toggle-on. Shown
    // before the empty-composing early return below so a plain hotkey press
    // still reports the change.
    using M = hazkey::config::Profile_AutoConvertMode;
    showTransientHint(
        cachedAutoConvertMode_ ==
                M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED
            ? tr("Live conversion disabled")
            : tr("Live conversion enabled"));

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
    // IBus has no fcitx5 showCustomInputMethodInformation() popup that every
    // panel renders, so surface the new state as a transient aux hint
    // (ibus-rime status_hint approach) in addition to the persistent property.
    updateZenzaiProperty(enabled.value());
    showTransientHint(tr(enabled.value() ? "Neural conversion enabled" : "Neural conversion disabled"));
}

void HazkeyState::showTransientHint(const std::string& text) {
    transientHintText_ = text;
    if (hintToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(hintToken_);
    }
    // Delayed on the serial worker (never a GLib timer): HazkeyState is
    // worker-owned, so the auto-hide must run on the same thread. The lambda
    // captures shared_from_this() so the state cannot die under the task.
    auto self = shared_from_this();
    hintToken_ = executor_->submitDelayed(
        [self] {
            self->hintToken_ =
                hazkey::frontend::SerialTaskExecutor::kInvalidToken;
            self->clearTransientHint();
        },
        kTransientHintTimeoutUsec);
    updateAuxiliaryText();
}

void HazkeyState::clearTransientHint() {
    transientHintText_.clear();
    updateAuxiliaryText();
}

void HazkeyState::cancelPendingHint() {
    if (hintToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(hintToken_);
        hintToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
    }
    transientHintText_.clear();
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
    if (listVisible_ || !candidates_.empty()) {
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
    currentListIsSuggest_ = isSuggest;
    // [community] The live-conversion display is the only one that pauses.
    // Non-predict conversion either snapped the cursor to the end already
    // (showNonPredictCandidateList) or is a focused clause-boundary
    // adjustment, which legitimately keeps the cursor inside.
    if (isSuggest && showPausedPreeditIfCursorInside()) {
        return false;
    }
    return applyCandidateResponse(server_.getCandidates(isSuggest),
                                  std::nullopt, isSuggest);
}

void HazkeyState::showPausedRawPreedit(
    const hazkey::frontend::ComposingTextWithCursor& parts) {
    const std::string text = hazkey::frontend::composingTextOf(parts);
    preeditText_ = text;
    // No live_text is on screen, so Return must commit the raw kana instead of
    // completing a candidate the user cannot see.
    livePreeditIndex_ = -1;
    const glong charLen = g_utf8_strlen(text.c_str(), -1);
    // Unlike the end-mode preedit (cursor pinned to 0 to stop the panel from
    // flapping as the live-conversion width changes), the paused preedit
    // carries a REAL caret: the raw kana is stable, so there is nothing to flap.
    setPreeditUnderline(
        text, 0, charLen,
        static_cast<guint>(hazkey::frontend::caretCharOffset(parts)));
    if (listVisible_ || !candidates_.empty()) {
        candidates_.clear();
        pageSize_ = 0;
        cursorIndex_ = -1;
        listVisible_ = false;
        clearLookupTable();
    }
}

bool HazkeyState::showPausedPreeditIfCursorInside() {
    const auto parts = server_.getComposingHiraganaWithCursor();
    if (hazkey::frontend::cursorAtEnd(parts)) {
        return false;
    }
    showPausedRawPreedit(parts);
    return true;
}

void HazkeyState::moveComposingCursor(int offset) {
    if (offset > 0 && hazkey::frontend::cursorAtEnd(
                          server_.getComposingHiraganaWithCursor())) {
        // Right/End at the end of the composition: nothing to move to. The key
        // is still consumed by the caller, but no RPC and no redraw happen.
        return;
    }
    // Any deferred refresh is superseded by the synchronous render below.
    // Cancel -> render -> hide list all run on this one worker, in this order.
    cancelPendingRefresh();
    server_.moveCursor(offset);
    // moveCursor() invalidates the connector cache, so this re-read sees the
    // new position. The server clamps the offset, so +-1024 is safe.
    const auto parts = server_.getComposingHiraganaWithCursor();
    if (hazkey::frontend::cursorAtEnd(parts)) {
        showPreeditCandidateList();
        return;
    }
    showPausedRawPreedit(parts);
}

void HazkeyState::refreshAfterComposingEdit() {
    const auto parts = server_.getComposingHiraganaWithCursor();
    if (!hazkey::frontend::cursorAtEnd(parts)) {
        cancelPendingRefresh();
        showPausedRawPreedit(parts);
        return;
    }
    // Display-only refresh: coalesce (see scheduleCandidateRefresh()).
    scheduleCandidateRefresh(/*isSuggest=*/true);
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
    // livePreeditIndex_ means "this live_text is what the user sees", not "the
    // response carried an index": Return completes that candidate, so it must
    // only be set on the branch that actually displays live_text.
    livePreeditIndex_ = -1;
    if (cachedAutoConvertMode_ !=
            hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED &&
        !response.live_text().empty()) {
        display = response.live_text();
        livePreeditIndex_ = response.live_text_index();
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

    const bool hasCandidates = rawPageSize > 0 && !candidates_.empty();
    if (hasCandidates) {
        pageSize_ = std::clamp(rawPageSize, 1, 16);
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
// schedules a delayed task on the shared SerialTaskExecutor. Using the
// executor instead of a GLib timer keeps ALL coalescer state on the one
// worker thread and removes the cross-thread timer lifetime hazard (a GLib
// timeout source holding a raw `this`).
//
// Coalescing applies ONLY to the display-only refresh that follows a
// state-mutating inputChar (the three inputable-key sites), exactly like
// fcitx5. Candidate navigation, paging, clause-boundary adjustment, commit,
// backspace/delete and reset stay synchronous. Every method below runs on the
// single worker thread, so no locking is needed.

void HazkeyState::scheduleCandidateRefresh(bool isSuggest) {
    pendingRefreshIsSuggest_ = isSuggest;
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());

    // Leading edge: nothing pending and the previous refresh is older than one
    // quiet period, so execute now with zero added latency.
    if (refreshCoalescer_.shouldRunImmediately(
            nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // A scheduled delayed task must not survive an immediate run: onRun()
        // consumes the pending slot, so the old task would be a stale
        // duplicate. cancel() is safe even if it already ran.
        if (refreshToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
            executor_->cancel(refreshToken_);
            refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
        }
        refreshCoalescer_.onRun(nowUsec);
        runPendingCandidateRefresh();
        return;
    }

    if (refreshCoalescer_.shouldSchedule(
            nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // Latest-wins: cancelling the previous delayed task before scheduling
        // the new one makes the newest request own the deadline, so a burst
        // collapses into one trailing execution instead of firing once per
        // keystroke. The delay is derived from the coalescer's own deadline so
        // posting latency cannot shorten the quiet period.
        if (refreshToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
            executor_->cancel(refreshToken_);
            refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
        }
        const uint64_t deadline = refreshCoalescer_.pendingDeadlineUsec();
        const uint64_t delayUsec = deadline > nowUsec ? deadline - nowUsec : 0;
        auto self = shared_from_this();
        refreshToken_ = executor_->submitDelayed(
            [self] {
                self->refreshToken_ =
                    hazkey::frontend::SerialTaskExecutor::kInvalidToken;
                self->firePendingCandidateRefresh();
            },
            delayUsec);
    }
}

void HazkeyState::firePendingCandidateRefresh() {
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());
    if (!refreshCoalescer_.shouldFire(nowUsec)) {
        // Defensive: the delayed task should not run early, but if it did,
        // re-arm for the remaining time rather than dropping the refresh.
        if (refreshCoalescer_.hasPending()) {
            const uint64_t deadline = refreshCoalescer_.pendingDeadlineUsec();
            const uint64_t remaining = deadline > nowUsec ? deadline - nowUsec : 0;
            auto self = shared_from_this();
            refreshToken_ = executor_->submitDelayed(
                [self] {
                    self->refreshToken_ =
                        hazkey::frontend::SerialTaskExecutor::kInvalidToken;
                    self->firePendingCandidateRefresh();
                },
                remaining == 0 ? 1 : remaining);
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
    if (refreshToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(refreshToken_);
        refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
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
    // Drop the scheduled task first so onRun() below owns the slot and no stale
    // task can run afterwards.
    if (refreshToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(refreshToken_);
        refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
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
    // fcitx renders the conversion TARGET highlighted: the whole string when
    // the candidate has no trailing reading, otherwise just c.text (the
    // trailing subHiragana is intentionally left plain).
    const std::string selection =
        c.subHiragana.empty() ? preeditText_ : c.text;
    const glong selectionLen = g_utf8_strlen(selection.c_str(), -1);
    postUi([text = preeditText_, selectionLen](HazkeyUi& ui) {
        ui.updatePreeditSelection(text, selectionLen);
    });
    pushLookupTable();
}

void HazkeyState::advanceCandidateCursor() {
    if (candidates_.empty()) {
        return;
    }
    if (cursorIndex_ < 0) {
        // Shown but unfocused: fcitx's moveCursor() focuses the first
        // candidate instead of advancing from an implicit position.
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    // Mirrors ibus_lookup_table_cursor_down() with round=FALSE: increment up
    // to the last candidate, then wrap to the first (the previous code called
    // set_cursor_pos(0) when cursor_down returned FALSE).
    cursorIndex_ = advanceCursorIndex(cursorIndex_,
                                      static_cast<int>(candidates_.size()));
    updateCandidateCursor();
}

void HazkeyState::backCandidateCursor() {
    if (candidates_.empty()) {
        return;
    }
    if (cursorIndex_ < 0) {
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    // Mirrors ibus_lookup_table_cursor_up() with round=FALSE: decrement to the
    // first candidate, then wrap to the last.
    cursorIndex_ = backCursorIndex(cursorIndex_,
                                   static_cast<int>(candidates_.size()));
    updateCandidateCursor();
}

void HazkeyState::nextPage() {
    if (pageSize_ <= 0 || candidates_.empty()) {
        return;
    }
    cursorIndex_ = nextPageStart(cursorIndex_, pageSize_,
                                 static_cast<int>(candidates_.size()));
    updateCandidateCursor();
}

void HazkeyState::prevPage() {
    if (pageSize_ <= 0 || candidates_.empty()) {
        return;
    }
    cursorIndex_ = prevPageStart(cursorIndex_, pageSize_);
    updateCandidateCursor();
}

// Pure mirrors of ibus_lookup_table_page_down()/page_up() with round=FALSE,
// followed by the caller's pageStart normalization (see the original code:
// page_down false -> stay on the current page start; otherwise -> the new
// cursor's page start).
int HazkeyState::nextPageStart(int cursorIndex, int pageSize, int total) {
    if (pageSize <= 0 || total <= 0) {
        return cursorIndex;
    }
    const int cur = cursorIndex >= 0 ? cursorIndex : 0;
    const int page = cur / pageSize;
    const int pageCount = (total + pageSize - 1) / pageSize;
    if (page >= pageCount - 1) {
        return page * pageSize;
    }
    int next = cur + pageSize;
    if (next > total - 1) {
        next = total - 1;
    }
    return (next / pageSize) * pageSize;
}

int HazkeyState::prevPageStart(int cursorIndex, int pageSize) {
    if (pageSize <= 0) {
        return cursorIndex;
    }
    const int cur = cursorIndex >= 0 ? cursorIndex : 0;
    if (cur < pageSize) {
        return 0;
    }
    return ((cur - pageSize) / pageSize) * pageSize;
}

int HazkeyState::advanceCursorIndex(int cursorIndex, int total) {
    if (total <= 0) {
        return cursorIndex;
    }
    if (cursorIndex < 0) {
        return 0;
    }
    return (cursorIndex + 1) % total;
}

int HazkeyState::backCursorIndex(int cursorIndex, int total) {
    if (total <= 0) {
        return cursorIndex;
    }
    if (cursorIndex < 0) {
        return 0;
    }
    return (cursorIndex + total - 1) % total;
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

void HazkeyState::pushLookupTable() {
    // The lookup table is built and pushed entirely on the main loop from a
    // plain snapshot, so the worker never owns an IBusLookupTable. The
    // generation lets a later click be resolved against exactly this render.
    const uint64_t generation = ++lookupGeneration_;
    if (pageSize_ <= 0 || candidates_.empty()) {
        postUi([generation](HazkeyUi& ui) {
            ui.hideLookupTable(static_cast<int>(generation));
        });
        return;
    }
    std::vector<std::string> texts;
    texts.reserve(candidates_.size());
    for (const auto& c : candidates_) {
        texts.push_back(c.text);
    }
    const int pageSize = pageSize_;
    const int cursorIndex = cursorIndex_;
    postUi([texts = std::move(texts), pageSize, cursorIndex,
            generation](HazkeyUi& ui) {
        ui.updateLookupTable(texts, pageSize, cursorIndex,
                             static_cast<int>(generation));
    });
}

void HazkeyState::clearLookupTable() {
    const uint64_t generation = ++lookupGeneration_;
    postUi([generation](HazkeyUi& ui) {
        ui.hideLookupTable(static_cast<int>(generation));
    });
}

void HazkeyState::resetState() {
    // A pending coalesced refresh must not fire after this reset (which is
    // also the focus-out/disable/enable path); cancel it explicitly, matching
    // fcitx5's HazkeyState::reset().
    cancelPendingRefresh();
    cancelPendingHint();
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
    postUi([text](HazkeyUi& ui) { ui.commitText(text); });
}

void HazkeyState::hidePreedit() {
    postUi([](HazkeyUi& ui) { ui.hidePreedit(); });
}

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
    postUi([text, startChar, endChar, cursorChar](HazkeyUi& ui) {
        ui.updatePreeditRange(text, startChar, endChar, cursorChar);
    });
}

void HazkeyState::setPreeditHighlighted(const std::string& text) {
    // Mirrors fcitx HazkeyPreedit::setSimplePreeditHighlighted(): the whole
    // string is highlighted (selection) and the preedit cursor sits at its
    // start.
    postUi([text](HazkeyUi& ui) { ui.updatePreeditHighlighted(text); });
}

void HazkeyState::setAuxiliaryText(const std::string& text) {
    postUi([text](HazkeyUi& ui) { ui.updateAuxiliaryTextPlain(text); });
}

void HazkeyState::setAuxiliaryTextWithCursor(const std::string& auxUp,
                                             glong underlineStart,
                                             glong underlineEnd,
                                             const std::string& auxDown) {
    // The raw-hiragana AuxUp underlines the character under the server cursor,
    // the IBus counterpart of fcitx's Underline TextFormatFlag on onCursor (see
    // composingTextWithCursorToFcitxText() in the fcitx adapter). The offsets
    // are UTF-8 character offsets and AuxUp is a prefix of the joined text, so
    // they need no shift.
    postUi([auxUp, underlineStart, underlineEnd, auxDown](HazkeyUi& ui) {
        ui.updateAuxiliaryTextWithCursor(auxUp, underlineStart, underlineEnd,
                                         auxDown);
    });
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

    // A transient toggle hint (from the Zenzai toggle or the live-conversion
    // toggle) is transient feedback with no other IBus channel (see
    // showTransientHint()). Overlaying it on AuxDown reuses the existing aux
    // rendering path, and it must still make the aux slot VISIBLE when nothing
    // else would (idle toggle: no preedit, not direct). It is placed first
    // because it is the most recent event.
    if (!transientHintText_.empty()) {
        auxDown = joinAuxiliaryText(transientHintText_, auxDown);
    }

    if (focused) {
        const std::string auxUp = "[" + std::to_string(cursorIndex_ + 1) + "/" +
                                  std::to_string(candidates_.size()) + "]";
        setAuxiliaryTextWithCursor(auxUp, -1, -1, auxDown);
        return;
    }
    if (!preeditText_.empty()) {
        // The transport caches this read. auxTextMode is applied here rather
        // than on the server (see cachedAuxTextMode_); when it hides the raw
        // hiragana, joinAuxiliaryText() yields AuxDown alone without a leading
        // space.
        const auto parts = server_.getComposingHiraganaWithCursor();
        if (!hazkey::frontend::shouldShowAuxText(
                cachedAuxTextMode_, hazkey::frontend::cursorAtEnd(parts))) {
            setAuxiliaryTextWithCursor("", -1, -1, auxDown);
            return;
        }
        const glong beforeChars = g_utf8_strlen(parts.before.c_str(), -1);
        const glong onCursorChars = g_utf8_strlen(parts.onCursor.c_str(), -1);
        setAuxiliaryTextWithCursor(parts.toString(), beforeChars,
                                   beforeChars + onCursorChars, auxDown);
        return;
    }
    // Not composing and not direct: fcitx clears both AuxUp and AuxDown.
    setAuxiliaryText(joinAuxiliaryText("", auxDown));
}

void HazkeyState::registerProperties() {
    // Load the server profile before the property is (re)registered so the
    // Zenzai property reflects the persisted setting immediately; the lazy
    // load otherwise only runs on the first non-release key event (leaving the
    // property stale until then).
    if (!serverProfileLoaded_) {
        loadServerProfile();
    }
    const bool direct = server_.currentInputModeIsDirect();
    const bool zenzai = cachedZenzaiEnabled_;
    postUi([direct, zenzai](HazkeyUi& ui) {
        ui.registerProperties(direct, zenzai);
    });
}

void HazkeyState::updateInputModeProperty() {
    const bool direct = server_.currentInputModeIsDirect();
    postUi([direct](HazkeyUi& ui) { ui.updateInputModeProperty(direct); });
}

void HazkeyState::updateZenzaiProperty(bool enabled) {
    cachedZenzaiEnabled_ = enabled;
    postUi([enabled](HazkeyUi& ui) { ui.updateZenzaiProperty(enabled); });
}

void HazkeyState::updateSurroundingText(const std::string& append) {
    if (capabilityIsAvailable(caps_, capsKnown_, IBUS_CAP_SURROUNDING_TEXT) &&
        hasSurroundingText_) {
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

void HazkeyState::focusIn() {
    resetState();
    invalidateServerProfile();
    registerProperties();
}

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
    registerProperties();
    if (capabilityIsAvailable(caps_, capsKnown_, IBUS_CAP_SURROUNDING_TEXT)) {
        postUi([](HazkeyUi& ui) { ui.requestSurroundingText(); });
    }
}

void HazkeyState::disable() {
    flushPendingRefresh();
    if (!preeditText_.empty()) {
        commitPreedit();
    }
    clearSurroundingText();
    resetState();
}

void HazkeyState::setCapabilities(guint caps) {
    caps_ = caps;
    capsKnown_ = true;
    if (!capabilityIsAvailable(caps_, capsKnown_, IBUS_CAP_SURROUNDING_TEXT)) {
        clearSurroundingText();
    }
}

bool HazkeyState::activateProperty(const gchar* propName,
                                   [[maybe_unused]] guint propState) {
    if (g_strcmp0(propName, "InputMode") == 0) {
        // Reuse the server's lone-Shift tap RPC path; it owns direct-input mode
        // transitions and cache invalidation, avoiding a frontend-only state.
        // Clear shiftPressedAlone_ first: if a physical Shift is held, its
        // later release must send CANCEL (not a second lone RELEASE), or the
        // synthetic tap and the physical release would toggle twice.
        shiftPressedAlone_ = false;
        server_.shiftKeyEvent(false);
        server_.shiftKeyEvent(true, true);
        updateInputModeProperty();
        updateAuxiliaryText();
        return true;
    }
    if (g_strcmp0(propName, "Zenzai") == 0) {
        handleZenzaiToggle();
        return true;
    }
    return false;
}

void HazkeyState::setCursorLocation(gint x, gint y, gint w, gint h) {
    cursorX_ = x;
    cursorY_ = y;
    cursorW_ = w;
    cursorH_ = h;
}

void HazkeyState::setSurroundingText(const std::string& text, guint cursorIndex,
                                     guint anchorPos) {
    (void)cursorIndex;
    if (!capabilityIsAvailable(caps_, capsKnown_, IBUS_CAP_SURROUNDING_TEXT)) {
        clearSurroundingText();
        return;
    }
    surroundingText_ = text;
    const glong textLength = g_utf8_strlen(surroundingText_.c_str(), -1);
    surroundingAnchor_ = std::min(anchorPos, static_cast<guint>(textLength));
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

void HazkeyState::candidateClickedGlobal(int globalIndex, int generation) {
    // The click was resolved on the main loop against the render the user
    // actually saw; a generation mismatch means the list changed underneath
    // the click, so it is dropped rather than applied to stale candidates.
    if (static_cast<uint64_t>(generation) != lookupGeneration_) {
        return;
    }
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
    if (globalIndex < 0 ||
        globalIndex >= static_cast<int>(candidates_.size())) {
        return;
    }
    cursorIndex_ = globalIndex;
    completeCandidate(globalIndex);
}

bool HazkeyState::isInputableKey(guint keyval) {
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

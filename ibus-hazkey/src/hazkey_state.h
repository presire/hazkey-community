#ifndef IBUS_HAZKEY_HAZKEY_STATE_H
#define IBUS_HAZKEY_HAZKEY_STATE_H
#include <ibus.h>

#include <optional>
#include <string>
#include <vector>

#include "candidate_refresh_coalescer.h"
#include "commands.pb.h"
#include "config.pb.h"
#include "hazkey_server_connector.h"

namespace hazkey::ibus {

// True when `state` holds no modifier other than Shift. A modifier key's own
// KeyPress may be reported with the state sampled before that modifier is
// applied, so the SHIFT bit itself is intentionally not required. Used to
// decide whether a Shift release toggles the sub-input (direct) mode.
bool isLoneShiftModifierState(guint state);

struct HazkeyCandidate {
    std::string text;
    std::string subHiragana;
    bool hasLearningEntry = false;
};

class HazkeyState {
 public:
    explicit HazkeyState(IBusEngine* engine);
    ~HazkeyState();
    HazkeyState(const HazkeyState&) = delete;
    HazkeyState& operator=(const HazkeyState&) = delete;

    gboolean processKeyEvent(guint keyval, guint keycode, guint state);
    void focusIn();
    void focusOut();
    void reset();
    void enable();
    void disable();
    // IBusEngine::set_capabilities is a real vfunc in IBus 1.5.33
    // (ibusengine.h); IBusEngineSimple does not override it.
    void setCapabilities(guint caps);
    bool activateProperty(const gchar* propName, guint propState);
    void setCursorLocation(gint x, gint y, gint w, gint h);
    void setSurroundingText(IBusText* text, guint cursorIndex, guint anchorPos);
    void pageUp();
    void pageDown();
    void cursorUp();
    void cursorDown();
    void candidateClicked(guint index, guint button, guint state);

    // Maps a page-local candidate index (0-based, as produced by a number key
    // or a lookup-table click) to the global candidate index, resolving the
    // page from the current global cursor position. The local index is bounded
    // by the candidates actually present on that page, so a number key for an
    // absent slot on the final partial page cannot select a later page's
    // candidate. Returns -1 on invalid input or when out of range.
    static int pageLocalToGlobalIndex(int pageSize, int totalSize,
                                      int cursorPos, int localIndex);

    // A parsed keyboard shortcut: the key itself plus the exact modifier set
    // that must accompany it (IBus modifier mask, lock keys ignored). keyval 0
    // means "unparsable / unset". Parsing happens once per input context in
    // loadServerProfile() from the fcitx5-style profile hotkey strings written
    // by hazkey-settings (keysequence_util.cpp: QKeySequence -> "Control+...",
    // "Super", "Alt" tokens).
    struct HotkeySpec {
        guint keyval = 0;
        guint modifiers = 0;
    };

    // Exposed for tests: parse a fcitx5-style hotkey string (empty -> fallback
    // string is parsed instead) and match an IBus key event against a spec.
    static HotkeySpec parseHotkey(const std::string& keyString,
                                  const std::string& fallback);
    static bool hotkeyMatches(guint keyval, guint state,
                              const HotkeySpec& hotkey);

    // Exposed for tests: exactly Alt + digit 1-9, mirroring fcitx's
    // isAltDigitKeyEvent() (KeyState::Alt). Alt+0 is not a selection, and any
    // extra modifier (Shift/Ctrl/Super...) makes it an application key. Lock
    // keys (CapsLock/NumLock) are ignored, like the other hotkey predicates.
    static bool isAltDigitKey(guint keyval, guint state);

    // Exposed for tests: exactly Ctrl + one of u/i/o/p/t, mirroring fcitx's
    // ctrlShortcutHandler() direct-conversion shortcuts (Hiragana /
    // KatakanaFullwidth / KatakanaHalfwidth / RawFullwidth / RawHalfwidth).
    // fcitx requires KeyState::Ctrl exactly, so Ctrl+Shift+X and Ctrl+Alt+X
    // are not shortcuts and stay with the application.
    static bool isDirectConversionShortcut(guint keyval, guint state);

    // Exposed for tests: the Fcitx candidate-mode Alt+Shift Space/Tab no-op.
    // Shift+Tab (IBUS_KEY_ISO_Left_Tab) is included because IBus clients may
    // report it instead of IBUS_KEY_Tab.
    static bool isAltShiftSpaceOrTab(guint keyval, guint state);

    // Exposed for tests: Fcitx defaultSelectionKeys (1..9, 0) for IBus lookup
    // table slots; other slots deliberately have no label.
    static std::string selectionLabelForIndex(int localIndex);

    // Exposed for tests: before IBus reports capabilities, preserve historical
    // behavior by treating every capability as available.
    static bool capabilityIsAvailable(guint caps, bool capsKnown,
                                      guint capability);

    // Exposed for tests: joins the fcitx AuxUp/AuxDown pair into IBus's single
    // auxiliary-text slot. A single space separates them only when BOTH are
    // non-empty, so an empty raw-hiragana AuxUp (auxTextMode disabled / cursor
    // at the end) never leaves a leading space before AuxDown.
    static std::string joinAuxiliaryText(const std::string& auxUp,
                                         const std::string& auxDown);

 private:
    // Direct character conversion targets (F6-F10), mirroring fcitx's
    // HazkeyState::ConversionMode.
    enum class ConversionMode {
        Hiragana,
        KatakanaFullwidth,
        KatakanaHalfwidth,
        RawFullwidth,
        RawHalfwidth,
    };

    gboolean noPreeditKeyEvent(guint keyval, guint state);
    gboolean preeditKeyEvent(guint keyval, guint state);
    gboolean candidateKeyEvent(guint keyval, guint state);

    // Lazy-load the server profile (hotkey strings + current auto-convert
    // mode) once per input context, mirroring fcitx's loadServerProfile().
    void loadServerProfile();
    // Toggle live conversion via hotkey (synchronous get/mutate/set), mirroring
    // fcitx's handleLiveConvertToggle().
    void handleLiveConvertToggle();
    // Toggle Zenzai via hotkey; the server persists the new state.
    void handleZenzaiToggle();
    // [community] Delete the focused candidate's learning memory entries via
    // hotkey, then rebuild the candidate list in the same display mode.
    void handleDeleteCandidateLearningData(int globalIndex);

    // F6-F10 handler: converts the composition to hiragana/katakana/raw and
    // enters direct-conversion mode.
    void functionKeyHandler(guint keyval);
    void directCharactorConversion(ConversionMode mode);
    // Ctrl+U/I/O/P/T direct conversion, mirroring fcitx's
    // ctrlShortcutHandler(). Returns true when the keyval is one of the five
    // targets (and enters direct-conversion mode like functionKeyHandler());
    // false for any other Ctrl key so the caller can forward it.
    bool ctrlShortcutHandler(guint keyval);
    // Selects the page-local Alt+digit candidate (1-9) when a list is visible.
    // flushFirst mirrors fcitx's preeditKeyEvent() branch (resolve a deferred
    // coalesced refresh before selecting); the focused candidateKeyEvent()
    // branch selects from the list it was dispatched with and does not flush.
    void selectPageLocalAltDigit(guint keyval, bool flushFirst);

    // Shift+Left / Shift+Right clause-boundary adjustment (both preedit and
    // candidate modes).
    void moveSegmentBoundary(bool expand);

    // Auxiliary text (fcitx AuxUp/AuxDown equivalent, collapsed into IBus's
    // single aux slot). AuxUp is "[n/total]" while a candidate is focused, or
    // the raw hiragana with the server-side cursor underlined otherwise (fcitx
    // setCandidateCursorAUX / setHiraganaAUX); AuxDown is "[Direct Input]",
    // "Deletable" or "[Press Tab to Select]" (fcitx setAuxDownText).
    void updateAuxiliaryText();
    void setAuxiliaryText(const std::string& text);
    // Builds the aux IBusText from an AuxUp (with an optional underline range
    // on its onCursor character, IBus's equivalent of fcitx's Underline
    // TextFormatFlag) joined with an AuxDown suffix, then pushes it.
    void setAuxiliaryTextWithCursor(const std::string& auxUp,
                                    glong underlineStart, glong underlineEnd,
                                     const std::string& auxDown);
    void registerProperties();
    void updateInputModeProperty();
    void updateZenzaiProperty(bool enabled);

    bool showCandidateList(bool isSuggest);
    bool applyCandidateResponse(
        const hazkey::commands::CandidatesResult& response,
        const std::optional<std::string>& fallback, bool isSuggest);
    void showPreeditCandidateList();

    // Coalescing entry point for the display-only refresh that follows an
    // inputable keystroke. Mirrors fcitx5-hazkey's scheduleCandidateRefresh():
    // the first request of a burst runs immediately (leading edge) and rapid
    // successive requests are collapsed into one GLib-timeout execution with a
    // latest-wins 30ms trailing debounce. The pure policy is shared with the
    // fcitx5 frontend (hazkey-frontend-common/candidate_refresh_coalescer.h);
    // only the timer adapter differs. The state-mutating inputChar RPC that
    // precedes each call stays synchronous and ordered -- only the candidate
    // LIST/predit display push is deferred.
    void scheduleCandidateRefresh(bool isSuggest);
    // GLib timeout callback target (g_timeout_add): consults
    // refreshCoalescer_.shouldFire() and runs the latest pending refresh.
    static gboolean onCandidateRefreshTimeout(gpointer data);
    void firePendingCandidateRefresh();
    // Executes the latest requested refresh kind (suggest vs non-suggest),
    // shared by the leading-edge and trailing-timer paths.
    void runPendingCandidateRefresh();
    // Drops any armed GLib timeout and clears the coalescer policy. Called
    // from resetState() (focus-out/disable/enable/reset) and the destructor so
    // no stale callback can mutate the UI after teardown or across a new
    // composition epoch.
    void cancelPendingRefresh();
    // Runs a pending coalesced refresh immediately (if any) instead of
    // cancelling it, so a caller about to CONSUME preeditText_ (commit /
    // focus-out / direct conversion) acts on the latest server state rather
    // than the stale last-synchronously-refreshed value.
    void flushPendingRefresh();

    void showNonPredictCandidateList();
    void showNonPredictCandidateList(
        const hazkey::commands::CandidatesResult& response,
        const std::string& hiragana);
    void focusCandidates();
    void completeCandidate(int globalIndex);
    void updateCandidateCursor();
    void advanceCandidateCursor();
    void backCandidateCursor();
    void nextPage();
    void prevPage();
    bool selectDigit(guint keyval);
    void rebuildLookupTable();
    void pushLookupTable();
    void clearLookupTable();
    void resetState();
    void commitPreedit();
    void commitText(const std::string& text);
    void hidePreedit();
    void setPreeditUnderline(const std::string& text, glong startChar,
                             glong endChar, guint cursorChar);
    // Whole-string highlighted preedit (cursor at 0), used by direct
    // character conversion (F6-F10); mirrors fcitx's
    // setSimplePreeditHighlighted().
    void setPreeditHighlighted(const std::string& text);
    void updateSurroundingText(const std::string& append = "");
    void clearSurroundingText();
    bool isInputableKey(guint keyval) const;
    static std::string utf8FromKeyval(guint keyval);
    static hazkey::commands::GetComposingString::CharType charTypeFor(
        ConversionMode mode);

    IBusEngine* engine_;
    HazkeyServerConnector& server_;
    IBusLookupTable* lookupTable_ = nullptr;
    IBusPropList* propertyList_ = nullptr;
    IBusProperty* inputModeProperty_ = nullptr;
    IBusProperty* zenzaiProperty_ = nullptr;
    std::vector<HazkeyCandidate> candidates_;
    int pageSize_ = 0;
    int cursorIndex_ = -1;
    bool listVisible_ = false;
    bool currentListIsSuggest_ = false;

    // Coalescing state for scheduleCandidateRefresh(). processKeyEvent() and
    // the GLib timeout callback both run on the single main-loop thread, so no
    // locking is needed.
    hazkey::frontend::CandidateRefreshCoalescer refreshCoalescer_;
    guint refreshTimerId_ = 0;
    bool pendingRefreshIsSuggest_ = true;
    // True while runPendingCandidateRefresh() executes, so showNonPredict* can
    // tell a coalescer-driven execution from a synchronous caller.
    bool executingPendingRefresh_ = false;

    std::string preeditText_;
    int livePreeditIndex_ = -1;
    bool isCursorMoving_ = false;
    bool isDirectConversionMode_ = false;
    // Tracks whether Shift is currently pressed without any other modifier,
    // so the release can report RELEASE (lone tap) vs CANCEL.
    bool shiftPressedAlone_ = false;
    bool isClauseBoundaryAdjusting_ = false;
    std::string surroundingText_;
    guint surroundingAnchor_ = 0;
    bool hasSurroundingText_ = false;
    guint caps_ = 0;
    bool capsKnown_ = false;
    gint cursorX_ = 0;
    gint cursorY_ = 0;
    gint cursorW_ = 0;
    gint cursorH_ = 0;

    // Hotkeys read from the server profile on the first key event. The
    // constructor seeds the server defaults (matching
    // fcitx5-hazkey/src/hazkey_state.cpp member initializers) and
    // loadServerProfile() overwrites them once the profile is available.
    HotkeySpec liveConvertHotkey_{};
    HotkeySpec zenzaiToggleHotkey_{};
    HotkeySpec acceptPredictionHotkey_{};
    HotkeySpec deleteLearningHotkey_{};
    bool serverProfileLoaded_ = false;
    // Last Zenzai enabled state learned from the server profile / toggle RPC,
    // re-applied to the Zenzai property whenever properties are registered.
    bool cachedZenzaiEnabled_ = false;
    hazkey::config::Profile_AutoConvertMode cachedAutoConvertMode_ =
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;
};

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_STATE_H

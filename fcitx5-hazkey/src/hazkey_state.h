#ifndef _FCITX5_HAZKEY_HAZKEY_STATE_H_
#define _FCITX5_HAZKEY_HAZKEY_STATE_H_

#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/surroundingtext.h>

#include <memory>

#include "candidate_refresh_coalescer.h"
#include "config.pb.h"
#include "hazkey_candidate.h"
#include "hazkey_frontend_hooks.h"
#include "hazkey_preedit.h"

namespace fcitx {

class HazkeyEngine;

class HazkeyState : public InputContextProperty {
   public:
    HazkeyState(HazkeyEngine* engine, InputContext* ic);

    // complete the prefix and remove from composingText_
    void candidateCompleteHandler(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    void commitPreedit();
    // handle key event. call candidateKeyEvent or preeditNoPredictKeyEvent
    // depends on the current mode
    void keyEvent(KeyEvent& keyEvent);
    // void loadConfig(std::shared_ptr<HazkeyConfig> &config);
    //  reset to the initial state
    void reset();

    // Drops the cached server profile so the next key event reloads it.
    void invalidateServerProfile() { serverProfileLoaded_ = false; }

   private:
    enum class ConversionMode {
        Hiragana,
        KatakanaFullwidth,
        KatakanaHalfwidth,
        RawFullwidth,
        RawHalfwidth,
    };

    enum class showCandidateMode {
        PredictWithLivePreedit,
        NonPredictWithFirstPreedit,
    };

    // update surrounding text
    void updateSurroundingText(std::string appendText = "");

    // lazy-load the server profile (hotkey + current auto-convert mode)
    void loadServerProfile();
    // toggle live conversion via hotkey (synchronous get/mutate/set)
    void handleLiveConvertToggle([[maybe_unused]] KeyEvent& event);
    void handleZenzaiToggle();
    // [community] delete the focused candidate's AzooKey learning memory
    // entries via hotkey, then rebuild the candidate list in the same
    // display mode (suggest vs non-predict conversion)
    void handleDeleteCandidateLearningData(
        std::shared_ptr<HazkeyCandidateList> candidateList);

    bool ctrlShortcutHandler(KeyEvent& keyEvent);
    // f6-f10 key handler
    void functionKeyHandler(KeyEvent& keyEvent);
    // convert to hiragana/katakana/alphanumeric directly
    void directCharactorConversion(ConversionMode mode);
    // handle key event in normal mode (no preedit)
    void noPreeditKeyEvent(KeyEvent& keyEvent);
    // handle key event in candidate mode
    void candidateKeyEvent(KeyEvent& keyEvent,
                           std::shared_ptr<HazkeyCandidateList> candidateList);
    // handle key event in preedit mode
    void preeditKeyEvent(
        KeyEvent& keyEvent,
        std::shared_ptr<HazkeyCandidateList> PreeditCandidateList);
    // base function to prepare candidate list
    // make sure composingText_ is not nullptr
    bool showCandidateList(bool isSuggest);
    bool showCandidateList(
        const hazkey::commands::CandidatesResult& response,
        std::optional<std::string> fallbackPreedit = std::nullopt);
    std::unique_ptr<HazkeyCandidateList> createCandidateList(
        std::vector<std::vector<std::string>> candidates,
        std::shared_ptr<std::vector<std::string>> preeditSegments);

    // [community] Live-conversion pause (composition cursor not at the end).
    //
    // A kana offset cannot be mapped into the converted text (kana <-> kanji is
    // many-to-many), so instead of drawing a caret at a guessed position the
    // live-conversion display is suspended: the raw kana is shown with a real
    // caret until the cursor returns to the end. The mode decision and the
    // caret arithmetic are shared with ibus-hazkey via
    // hazkey-frontend-common/composing_cursor_view.h so the two frontends
    // cannot drift apart.

    // Renders the paused display: raw kana + caret, no candidate list, and
    // livePreeditIndex_ = -1 so Return commits exactly what is on screen.
    void showPausedRawPreedit(
        const hazkey::frontend::ComposingTextWithCursor& parts);
    // Renders the paused display when the cursor is not at the end. Returns
    // true when it did, i.e. when the caller must not run a conversion.
    bool showPausedPreeditIfCursorInside();
    // Moves the composition cursor and re-renders. Reaching the end resumes
    // live conversion with exactly one synchronous re-conversion; a forward
    // move that is already at the end is consumed without any RPC.
    void moveComposingCursor(int offset);
    // Re-renders after an edit that mutated the composition: schedules the
    // usual coalesced live-conversion refresh at the end, or redraws the
    // paused display without computing a conversion nobody would see.
    void refreshAfterComposingEdit();

    // prepare candidate list for normal conversion
    void showNonPredictCandidateList(bool preserveTarget = false);
    void showNonPredictCandidateList(
        const hazkey::commands::CandidatesResult& response,
        const std::string& hiragana);
    // prepare candidate
    // list for prediction.
    // shorter than normal
    void showPreeditCandidateList();

    // Coalescing entry point for rapid successive DISPLAY-ONLY candidate
    // refresh triggers (see candidate_refresh_coalescer.h for the policy and
    // hazkey_state.cpp for the call-site rationale). Records the latest
    // requested refresh kind and, per the coalescer policy, (re)arms
    // refreshTimer_ so the actual refresh executes at most once per quiet
    // period instead of once per keystroke. isSuggest mirrors
    // showCandidateList(bool)/getCandidates(isSuggest)'s parameter: only
    // showPreeditCandidateList() (isSuggest=true) call sites are coalesced
    // in this delivery, but the payload is a bool so a future
    // showNonPredictCandidateList() (isSuggest=false) coalescing target
    // could reuse the same machinery without a new enum.
    void scheduleCandidateRefresh(bool isSuggest);
    // Timer callback target: consults coalescer_.shouldFire() and, if still
    // due, executes the latest pending refresh kind.
    void firePendingCandidateRefresh();
    // Executes the latest requested refresh kind (suggest vs non-suggest).
    // Shared by the leading-edge synchronous path in
    // scheduleCandidateRefresh() and the trailing timer path in
    // firePendingCandidateRefresh(); it performs no UI push of its own
    // because the two callers differ in whether one is needed.
    void runPendingCandidateRefresh();
    // Explicitly cancels any pending coalesced refresh (does not rely on
    // RAII alone): drops refreshTimer_ (cancelling the fcitx event-loop
    // callback) and clears coalescer_ state. Called from reset(), which is
    // reached on every focus-out/deactivate/escape/commit path (see
    // hazkey_engine.cpp's activate()/deactivate(), both of which call
    // state->reset()).
    void cancelPendingRefresh();
    // Runs a pending coalesced refresh immediately (if any) instead of
    // cancelling it, so a caller that is about to CONSUME the client-side
    // preedit (commit, direct conversion) acts on the latest server state
    // rather than the stale last-synchronously-refreshed value. Without this a
    // keystroke deferred inside the coalesce window is dropped from the
    // committed text.
    void flushPendingRefresh();

    // update the candidate cursor
    void updateCandidateCursor(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    // advance the cursor in
    // the candidate list,
    // update aux, set
    // preedit text
    void advanceCandidateCursor(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    // back the cursor in
    // the candidate list,
    // update aux, set
    // preedit text
    void backCandidateCursor(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    void moveSegmentBoundary(bool expand);
    // update aux; label on
    // the candidate list
    // like "[1/100]"
    void setCandidateCursorAUX(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    // set AuxDown
    // like "[Tabキーで選択]" or "[直接入力]"
    void setAuxDownText(std::optional<std::string>);
    // UpAUX that shows unconverted text
    void setHiraganaAUX();
    // check if the key
    // event is inputable
    // (simple key / kana
    // key) or not
    bool isInputableEvent(const KeyEvent& keyEvent);

    bool isAltDigitKeyEvent(const KeyEvent& keyEvent);

    bool isClauseBoundaryAdjusting_ = false;

    // Coalescing state for scheduleCandidateRefresh(). keyEvent() and the
    // fcitx5 event-loop timer callback both run on fcitx5's single
    // event-loop thread, so no locking is needed around these members (see
    // hazkey_state.cpp comment at scheduleCandidateRefresh() for the
    // detailed rationale).
    hazkey::frontend::CandidateRefreshCoalescer coalescer_;
    std::unique_ptr<EventSourceTime> refreshTimer_;
    bool pendingRefreshIsSuggest_ = true;
    // True while runPendingCandidateRefresh() executes, so the refresh targets
    // can tell a coalescer-driven execution from a synchronous caller and not
    // cancel the coalescer's own in-flight execution.
    bool executingPendingRefresh_ = false;

    bool isDirectConversionMode_ = false;
    // Tracks whether Shift is currently pressed without any other modifier or
    // character key, so the release can report RELEASE (lone tap) vs CANCEL.
    bool shiftPressedAlone_ = false;
    int livePreeditIndex_ = -1;

    fcitx::Key liveConvertHotkey_{"Control+Shift+L"};
    fcitx::Key zenzaiToggleHotkey_{"Control+Alt+Z"};
    // [community] Hotkey for accepting the focused prediction candidate as a
    // fixed leading notation while keeping the composition open.
    fcitx::Key acceptPredictionHotkey_{"F5"};
    // [community] Hotkey for deleting the focused candidate's AzooKey
    // learning memory entries (the list is rebuilt afterwards).
    fcitx::Key deleteLearningHotkey_{"Control+D"};
    // Display mode (suggest vs non-predict conversion) of the candidate list
    // currently shown. Mirrors the server's currentCandidateListIsSuggest so
    // the learning-data delete rebuild shows the same kind of list.
    bool currentListIsSuggest_ = false;
    hazkey::config::Profile_AutoConvertMode cachedAutoConvertMode_ =
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;
    // [community] Raw-hiragana AuxUp visibility. Gated HERE rather than on the
    // server, so getHiraganaWithCursor() stays a structural API the preedit
    // caret can depend on. Seeded with the server default profile value
    // (HazkeyServerConfig.genDefaultConfig() writes auxTextShowWhenCursorNotAtEnd).
    hazkey::config::Profile_AuxTextMode cachedAuxTextMode_ =
        hazkey::config::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END;
    bool serverProfileLoaded_ = false;

    // engine
    HazkeyEngine* engine_;
    // fcitx input context
    // pointer
    InputContext* ic_;
    // preedit class
    HazkeyPreedit preedit_;
};

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_HAZKEY_STATE_H_

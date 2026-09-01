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
    // Explicitly cancels any pending coalesced refresh (does not rely on
    // RAII alone): drops refreshTimer_ (cancelling the fcitx event-loop
    // callback) and clears coalescer_ state. Called from reset(), which is
    // reached on every focus-out/deactivate/escape/commit path (see
    // hazkey_engine.cpp's activate()/deactivate(), both of which call
    // state->reset()).
    void cancelPendingRefresh();

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

    bool isCursorMoving_ = false;
    bool isClauseBoundaryAdjusting_ = false;

    // Coalescing state for scheduleCandidateRefresh(). keyEvent() and the
    // fcitx5 event-loop timer callback both run on fcitx5's single
    // event-loop thread, so no locking is needed around these members (see
    // hazkey_state.cpp comment at scheduleCandidateRefresh() for the
    // detailed rationale).
    CandidateRefreshCoalescer coalescer_;
    std::unique_ptr<EventSourceTime> refreshTimer_;
    bool pendingRefreshIsSuggest_ = true;

    bool isDirectConversionMode_ = false;
    int livePreeditIndex_ = -1;

    fcitx::Key liveConvertHotkey_{"Control+Shift+L"};
    hazkey::config::Profile_AutoConvertMode cachedAutoConvertMode_ =
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;
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

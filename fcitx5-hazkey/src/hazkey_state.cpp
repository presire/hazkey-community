#include "hazkey_state.h"

#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/candidatelist.h>
#include <fcitx/instance.h>

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include "candidate_refresh_coalescer.h"
#include "commands.pb.h"
#include "fcitx-utils/keysym.h"
#include "hazkey_candidate.h"
#include "hazkey_engine.h"
#include "hazkey_server_connector.h"
#include "live_convert_mode.h"

namespace fcitx {

HazkeyState::HazkeyState(HazkeyEngine* engine, InputContext* ic)
    : engine_(engine), ic_(ic), preedit_(HazkeyPreedit(ic)) {
    engine_->server().newComposingText();
}

bool HazkeyState::isInputableEvent(const KeyEvent& event) {
    auto key = event.key();
    if (key.check(FcitxKey_space) || key.isSimple() ||
        Key::keySymToUTF8(key.sym()).size() > 1 ||
        (key.sym() >= 0x04a1 && key.sym() <= 0x04df)) {
        // 0x04a1 - 0x04dd is the range of kana keys
        return true;
    }
    return false;
}

void HazkeyState::commitPreedit() {
    // Resolve a deferred display refresh first: focus-out/deactivate commits
    // the panel preedit, which would otherwise be stale.
    flushPendingRefresh();
    preedit_.commitPreedit();
}

void HazkeyState::keyEvent(KeyEvent& event) {
    FCITX_DEBUG() << "HazkeyState keyEvent";

    if (!event.isRelease() && event.key().sym() != FcitxKey_Shift_L &&
        event.key().sym() != FcitxKey_Shift_R) {
        shiftPressedAlone_ = false;
    }

    if (!event.isRelease()) {
        if (!serverProfileLoaded_) {
            loadServerProfile();
        }
        if (event.key().check(liveConvertHotkey_)) {
            handleLiveConvertToggle(event);
            event.filterAndAccept();
            return;
        }
        if (event.key().check(zenzaiToggleHotkey_)) {
            handleZenzaiToggle();
            event.filterAndAccept();
            return;
        }
    }

    std::string composingText = engine_->server().getComposingText(
        hazkey::commands::GetComposingString_CharType_HIRAGANA,
        preedit_.text());

    if (event.key().sym() == FcitxKey_Shift_L ||
        event.key().sym() == FcitxKey_Shift_R) {
        if (!event.isRelease()) {
            // "Lone Shift" = no modifier other than Shift is active. Do NOT
            // require the Shift bit itself: a modifier key's own KeyPress may
            // be reported with the state sampled before it is applied, so the
            // held set can legitimately be empty for a lone Shift.
            const KeyStates held =
                event.key().states() &
                (KeyStates(KeyState::SimpleMask) | KeyState::Mod5);
            shiftPressedAlone_ =
                (held == KeyState::Shift) || (held == KeyState::NoState);
            engine_->server().shiftKeyEvent(false);
        } else {
            engine_->server().shiftKeyEvent(true, shiftPressedAlone_);
            shiftPressedAlone_ = false;
        }
        if (composingText == "") {
            setAuxDownText(std::nullopt);
            return;
        }
    }

    auto candidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
        event.inputContext()->inputPanel().candidateList());

    if (candidateList != nullptr && candidateList->focused() &&
        !event.isRelease()) {
        candidateKeyEvent(event, candidateList);
    } else if (composingText != "" && !event.isRelease()) {
        preeditKeyEvent(event, candidateList);
    } else if (!event.isRelease()) {
        noPreeditKeyEvent(event);
    } else if (candidateList != nullptr && candidateList->focused()) {
        setCandidateCursorAUX(candidateList);
    } else if (composingText != "" && candidateList != nullptr &&
               engine_->config().showTabToSelect.value()) {
        setAuxDownText(std::string(_("[Press Tab to Select]")));
    } else {
        setAuxDownText(std::nullopt);
    }

    if (event.isRelease()) {
        return;
    }

    auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
        ic_->inputPanel().candidateList());
    if (newCandidateList != nullptr && newCandidateList->focused()) {
        setCandidateCursorAUX(newCandidateList);
    } else if (composingText != "") {
        setHiraganaAUX();
    }
}

void HazkeyState::noPreeditKeyEvent(KeyEvent& event) {
    FCITX_DEBUG() << "HazkeyState noPredictKeyEvent";

    auto key = event.key();
    auto keysym = key.sym();

    switch (keysym) {
        case FcitxKey_space:
            if (key.states() == KeyState::Shift) {
                ic_->commitString(" ");
                reset();
            } else {
                // Keep Zenzai leftContext fresh.
                updateSurroundingText();
                engine_->server().inputChar(" ");
                ic_->commitString(engine_->server().getComposingText(
                    hazkey::commands::GetComposingString_CharType::
                        GetComposingString_CharType_HIRAGANA,
                    ""));
                reset();
            }
            break;
        default:
            if (isInputableEvent(event)) {
                updateSurroundingText();
                engine_->server().inputChar(Key::keySymToUTF8(keysym));
                // Display-only refresh: coalesce rapid successive keystrokes
                // (see scheduleCandidateRefresh() for rationale). inputChar
                // itself, above, is the state-mutating RPC and remains
                // synchronous/ordered -- only the candidate LIST display is
                // deferred/coalesced.
                scheduleCandidateRefresh(/*isSuggest=*/true);
                setHiraganaAUX();
            } else {
                reset();
                return event.filter();
            }
            break;
    }

    return event.filterAndAccept();
}

void HazkeyState::preeditKeyEvent(
    KeyEvent& event,
    std::shared_ptr<HazkeyCandidateList> PredictCandidateList) {
    FCITX_DEBUG() << "HazkeyState preeditKeyEvent";

    auto key = event.key();
    auto keysym = key.sym();

    switch (keysym) {
        case FcitxKey_Return:
            // Resolve a deferred display refresh so the committed text is the
            // latest composition, not the stale last-synchronously-refreshed
            // preedit.
            flushPendingRefresh();
            preedit_.commitPreedit();
            if (livePreeditIndex_ >= 0) {
                engine_->server().completePrefix(livePreeditIndex_);
            }
            reset();
            break;
        case FcitxKey_BackSpace:
            engine_->server().deleteLeft();
            showPreeditCandidateList();
            break;
        case FcitxKey_Delete:
            engine_->server().deleteRight();
            showPreeditCandidateList();
            break;
        case FcitxKey_F6:
        case FcitxKey_F7:
        case FcitxKey_F8:
        case FcitxKey_F9:
        case FcitxKey_F10:
        case FcitxKey_Muhenkan:
            functionKeyHandler(event);
            break;
        case FcitxKey_Escape:
            reset();
            break;
        case FcitxKey_space:
            if (!isDirectConversionMode_ &&
                event.key().states() == KeyState::Shift) {
                // Keep Zenzai leftContext fresh.
                updateSurroundingText();
                engine_->server().inputChar(" ");
                // Display-only refresh: coalesce (see
                // scheduleCandidateRefresh()).
                scheduleCandidateRefresh(/*isSuggest=*/true);
            } else {
                showNonPredictCandidateList();
            }
            break;
        case FcitxKey_Henkan:
            showNonPredictCandidateList();
            break;
        case FcitxKey_Up:
        case FcitxKey_Down:
        case FcitxKey_Tab:
            if (PredictCandidateList == nullptr) {
                showNonPredictCandidateList();
            } else {
                // Resolve a deferred display refresh first: the list about to
                // be focused must reflect every committed keystroke, or a
                // following selection would commit a stale candidate and drop
                // the trailing input.
                flushPendingRefresh();
                auto freshList =
                    std::dynamic_pointer_cast<HazkeyCandidateList>(
                        ic_->inputPanel().candidateList());
                if (freshList != nullptr) {
                    freshList->focus();
                    updateCandidateCursor(freshList);
                } else {
                    // The refresh cleared the suggest list; fall back to a
                    // non-predict conversion instead of swallowing the key.
                    showNonPredictCandidateList();
                }
            }
            break;
        case FcitxKey_Left:
            if (key.states() == KeyState::Shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(false);
            } else {
                isCursorMoving_ = true;
                engine_->server().moveCursor(-1);
            }
            break;
        case FcitxKey_Right:
            if (key.states() == KeyState::Shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(true);
            } else if (isCursorMoving_) {
                engine_->server().moveCursor(1);
            }
            break;
        default:
            if (event.key().states() == KeyState::Ctrl) {
                ctrlShortcutHandler(event);
            } else if (isAltDigitKeyEvent(event)) {
                if (PredictCandidateList != nullptr) {
                    // Resolve a deferred refresh so Alt+digit selects from the
                    // current list, not a stale one.
                    flushPendingRefresh();
                    auto freshList =
                        std::dynamic_pointer_cast<HazkeyCandidateList>(
                            ic_->inputPanel().candidateList());
                    if (freshList != nullptr) {
                        const int localIndex =
                            static_cast<int>(keysym - FcitxKey_1);
                        // Bound by the candidates that exist on the current
                        // page, not by pageSize(): on the final partial page
                        // the trailing slots are empty. Without this the
                        // selection silently fails but candidateCompleteHandler
                        // would still run against the stale cursor.
                        if (HazkeyCandidateList::pageLocalIndexInRange(
                                freshList->pageSize(), freshList->totalSize(),
                                freshList->currentPage(), localIndex)) {
                            freshList->setCursorIndex(localIndex);
                            candidateCompleteHandler(freshList);
                        }
                    }
                }
            } else if (isInputableEvent(event)) {
                if (isDirectConversionMode_) {
                    flushPendingRefresh();
                    preedit_.commitPreedit();
                    reset();
                }
                // Zenzai leftContext更新のため。
                updateSurroundingText();
                engine_->server().inputChar(Key::keySymToUTF8(keysym));
                // Display-only refresh: coalesce (see
                // scheduleCandidateRefresh()).
                scheduleCandidateRefresh(/*isSuggest=*/true);
            }
            break;
    }
    return event.filterAndAccept();
}

bool HazkeyState::isAltDigitKeyEvent(const KeyEvent& event) {
    auto key = event.key();
    if (key.states() == KeyState::Alt && key.sym() >= FcitxKey_1 &&
        key.sym() <= FcitxKey_9) {
        return true;
    }
    return false;
}

void HazkeyState::candidateKeyEvent(
    KeyEvent& event, std::shared_ptr<HazkeyCandidateList> candidateList) {
    FCITX_DEBUG() << "HazkeyState candidateKeyEvent";

    auto key = event.key();
    auto keysym = key.sym();

    // [community] Delete the focused candidate's learning data. Must be
    // checked before the switch: a Ctrl combo falls into the default
    // clause's ctrlShortcutHandler, which would consume the event first.
    if (key.check(deleteLearningHotkey_)) {
        handleDeleteCandidateLearningData(candidateList);
        return event.filterAndAccept();
    }

    // [community] Accept only focused suggest-mode candidates. Unlike Return,
    // this preserves the composition and refreshes it from the server.
    if (currentListIsSuggest_ && key.check(acceptPredictionHotkey_)) {
        engine_->server().acceptPrediction(candidateList->globalCursorIndex());
        showPreeditCandidateList();
        return event.filterAndAccept();
    }

    std::vector<std::string> preedit;
    switch (keysym) {
        case FcitxKey_Right:
            if (key.states() == KeyState::Shift) {
                moveSegmentBoundary(true);
            } else {
                candidateList->nextPage();
            }
            break;
        case FcitxKey_Left:
            if (key.states() == KeyState::Shift) {
                moveSegmentBoundary(false);
            } else {
                candidateList->prevPage();
            }
            break;
        case FcitxKey_Return:
            candidateCompleteHandler(candidateList);
            break;
        case FcitxKey_Escape:
            if (isClauseBoundaryAdjusting_) {
                showNonPredictCandidateList(false);
                break;
            }
            isClauseBoundaryAdjusting_ = false;
            [[fallthrough]];
        case FcitxKey_BackSpace:
            isClauseBoundaryAdjusting_ = false;
            showPreeditCandidateList();
            break;
        case FcitxKey_space:
        case FcitxKey_Tab:
            if (key.states() == KeyState::Shift) {
                backCandidateCursor(candidateList);
            } else if (key.states() == KeyState::Alt_Shift) {
                // do nothing
            } else {
                advanceCandidateCursor(candidateList);
            }
            break;
        case FcitxKey_Down:
            advanceCandidateCursor(candidateList);
            break;
        case FcitxKey_Up:
            backCandidateCursor(candidateList);
            break;
        case FcitxKey_F6:
        case FcitxKey_F7:
        case FcitxKey_F8:
        case FcitxKey_F9:
        case FcitxKey_F10:
            functionKeyHandler(event);
            break;
        case FcitxKey_Shift_L:
        case FcitxKey_Shift_R:

        default:
            if (event.key().states() == KeyState::Ctrl) {
                if (!ctrlShortcutHandler(event)) {
                    return event.filter();
                }
            } else if (isAltDigitKeyEvent(event) ||
                       key.checkKeyList(defaultSelectionKeys)) {
                const int localIndex =
                    isAltDigitKeyEvent(event)
                        ? static_cast<int>(keysym - FcitxKey_1)
                        : key.keyListIndex(defaultSelectionKeys);
                // Bound by the candidates that exist on the current page
                // (covering both the Alt+digit and number-key paths) so the
                // final partial page never completes an empty slot. size() is
                // page-local on current Fcitx, but this states the rule
                // explicitly and stays correct across Fcitx versions.
                if (HazkeyCandidateList::pageLocalIndexInRange(
                        candidateList->pageSize(), candidateList->totalSize(),
                        candidateList->currentPage(), localIndex)) {
                    candidateList->setCursorIndex(localIndex);
                    candidateCompleteHandler(candidateList);
                }
            } else if (isInputableEvent(event)) {
                // Resolve a deferred refresh before capturing/committing, or
                // the committed text and surrounding-text update would lag.
                flushPendingRefresh();
                auto committedText = preedit_.text();
                preedit_.commitPreedit();
                reset();
                // Keep Zenzai leftContext fresh after committing.
                updateSurroundingText(committedText);
                engine_->server().inputChar(Key::keySymToUTF8(keysym));
                showPreeditCandidateList();
            } else {
                return event.filter();
            }
            break;
    }
    return event.filterAndAccept();
}

void HazkeyState::candidateCompleteHandler(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    auto preedit =
        candidateList->getCandidate(candidateList->cursorIndex()).getPreedit();
    // hazkey cannot get surroundingText correctly immediately after
    // committing so call it with appendText before committing.
    updateSurroundingText(preedit[0]);
    engine_->server().completePrefix(candidateList->globalCursorIndex());
    ic_->commitString(preedit[0]);
    if (preedit.size() > 1) {
        isClauseBoundaryAdjusting_ = false;
        showNonPredictCandidateList(false);
    } else {
        reset();
    }
}

void HazkeyState::updateSurroundingText(std::string appendText) {
    if (ic_->capabilityFlags().test(CapabilityFlag::SurroundingText) &&
        ic_->surroundingText().isValid()) {
        auto& surroundingText = ic_->surroundingText();
        // anchor() is in characters; count appendText in characters too.
        engine_->server().setContext(
            surroundingText.text() + appendText,
            surroundingText.anchor() + utf8::lengthValidated(appendText));
    } else {
        engine_->server().setContext("", 0);
    }
}

void HazkeyState::loadServerProfile() {
    auto configOpt = engine_->server().getServerConfig();
    if (!configOpt.has_value() || configOpt->profiles_size() == 0) {
        return;  // server not ready; keep defaults
    }
    const auto& profile = configOpt->profiles(0);
    const std::string& hotkey = profile.auto_convert_hotkey();
    liveConvertHotkey_ = Key(hotkey.empty() ? "Control+Shift+L" : hotkey);
    const std::string& acceptPredictionHotkey =
        profile.accept_prediction_hotkey();
    acceptPredictionHotkey_ =
        Key(acceptPredictionHotkey.empty() ? "F5" : acceptPredictionHotkey);
    const std::string& zenzaiToggleHotkey = profile.zenzai_toggle_hotkey();
    zenzaiToggleHotkey_ =
        Key(zenzaiToggleHotkey.empty() ? "Control+Alt+Z" : zenzaiToggleHotkey);
    // [community] Learning-data delete hotkey. Read once per input context
    // like liveConvertHotkey_, so GUI changes take effect from the next
    // input context (fcitx5 restart applies it reliably).
    const std::string& deleteHotkey = profile.delete_learning_hotkey();
    deleteLearningHotkey_ =
        Key(deleteHotkey.empty() ? "Control+D" : deleteHotkey);
    cachedAutoConvertMode_ = profile.auto_convert_mode();
    using M = hazkey::config::Profile_AutoConvertMode;
    // Only update the remembered "ON" mode when the server's mode is not
    // DISABLED. When DISABLED (e.g. after a previous hotkey toggle-off), keep
    // the previous remembered value so toggle-on restores the right mode.
    // rememberedOnMode_ lives on the connector (shared across input contexts)
    // so it survives focus changes between applications.
    if (cachedAutoConvertMode_ !=
        M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED) {
        engine_->server().rememberedOnMode() = cachedAutoConvertMode_;
    }
    serverProfileLoaded_ = true;
}

void HazkeyState::handleLiveConvertToggle([[maybe_unused]] KeyEvent& event) {
    FCITX_DEBUG() << "HazkeyState handleLiveConvertToggle";

    auto prevMode = cachedAutoConvertMode_;
    auto& sharedRemembered = engine_->server().rememberedOnMode();
    auto prevRemembered = sharedRemembered;

    cachedAutoConvertMode_ =
        computeNextAutoConvertMode(cachedAutoConvertMode_, sharedRemembered);

    auto configOpt = engine_->server().getServerConfig();
    if (!configOpt.has_value() || configOpt->profiles_size() == 0) {
        FCITX_WARN() << "handleLiveConvertToggle: getServerConfig failed";
        cachedAutoConvertMode_ = prevMode;
        sharedRemembered = prevRemembered;
        return;
    }

    auto config = configOpt.value();
    config.mutable_profiles(0)->set_auto_convert_mode(cachedAutoConvertMode_);

    if (!engine_->server().setServerConfig(config)) {
        FCITX_WARN() << "handleLiveConvertToggle: setServerConfig failed";
        cachedAutoConvertMode_ = prevMode;
        sharedRemembered = prevRemembered;
        return;
    }

    auto composingText = engine_->server().getComposingText(
        hazkey::commands::GetComposingString_CharType_HIRAGANA,
        preedit_.text());
    if (composingText.empty()) {
        ic_->updateUserInterface(
            fcitx::UserInterfaceComponent::InputPanel);
        return;
    }
    showCandidateList(true);
    ic_->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void HazkeyState::handleZenzaiToggle() {
    FCITX_DEBUG() << "HazkeyState handleZenzaiToggle";

    const auto enabled = engine_->server().toggleZenzai();
    if (!enabled.has_value()) {
        return;
    }
#if defined(HAZKEY_HAS_SHOW_CUSTOM_IM_INFO)
    engine_->instance()->showCustomInputMethodInformation(
        ic_, enabled.value() ? _("Zenzai enabled") : _("Zenzai disabled"));
#else
    // fcitx5 < 5.1.11 has no showCustomInputMethodInformation() (e.g. Ubuntu
    // 24.04 ships 5.1.7). The toggle itself works; only the transient status
    // notification is unavailable on those releases.
#endif
}

bool HazkeyState::ctrlShortcutHandler(KeyEvent& event) {
    auto keysym = event.key().sym();
    switch (keysym) {
        case FcitxKey_u:
        case FcitxKey_U:
            directCharactorConversion(ConversionMode::Hiragana);
            isDirectConversionMode_ = true;
            break;
        case FcitxKey_i:
        case FcitxKey_I:
            directCharactorConversion(ConversionMode::KatakanaFullwidth);
            isDirectConversionMode_ = true;
            break;
        case FcitxKey_o:
        case FcitxKey_O:
            directCharactorConversion(ConversionMode::KatakanaHalfwidth);
            isDirectConversionMode_ = true;
            break;
        case FcitxKey_p:
        case FcitxKey_P:
            directCharactorConversion(ConversionMode::RawFullwidth);
            isDirectConversionMode_ = true;
            break;
        case FcitxKey_t:
        case FcitxKey_T:
            directCharactorConversion(ConversionMode::RawHalfwidth);
            isDirectConversionMode_ = true;
            break;
        default:
            FCITX_INFO() << "keysym" << keysym;
            return false;
    }
    return true;
}

void HazkeyState::functionKeyHandler(KeyEvent& event) {
    auto keysym = event.key().sym();
    switch (keysym) {
        case FcitxKey_F6:
            directCharactorConversion(ConversionMode::Hiragana);
            break;
        case FcitxKey_F7:
            directCharactorConversion(ConversionMode::KatakanaFullwidth);
            break;
        case FcitxKey_F8:
            directCharactorConversion(ConversionMode::KatakanaHalfwidth);
            break;
        case FcitxKey_F9:
            directCharactorConversion(ConversionMode::RawFullwidth);
            break;
        case FcitxKey_F10:
            directCharactorConversion(ConversionMode::RawHalfwidth);
            break;
        default:
            FCITX_ERROR() << "functionKeyHandler: unhandled key code: "
                          << keysym;
            return;
    }
    isDirectConversionMode_ = true;
}

void HazkeyState::directCharactorConversion(ConversionMode mode) {
    // Resolve a deferred refresh: the conversion below reads preedit_.text(),
    // which would otherwise be stale.
    flushPendingRefresh();
    std::string converted;
    // TODO: use protobuf type for all program
    switch (mode) {
        case ConversionMode::Hiragana:
            converted = engine_->server().getComposingText(
                hazkey::commands::GetComposingString_CharType_HIRAGANA,
                preedit_.text());
            break;
        case ConversionMode::KatakanaFullwidth:
            converted = engine_->server().getComposingText(
                hazkey::commands::GetComposingString_CharType_KATAKANA_FULL,
                preedit_.text());
            break;
        case ConversionMode::KatakanaHalfwidth:
            converted = engine_->server().getComposingText(
                hazkey::commands::GetComposingString_CharType_KATAKANA_HALF,
                preedit_.text());
            break;
        case ConversionMode::RawFullwidth:
            converted = engine_->server().getComposingText(
                hazkey::commands::GetComposingString_CharType_ALPHABET_FULL,
                preedit_.text());
            break;
        case ConversionMode::RawHalfwidth:
            converted = engine_->server().getComposingText(
                hazkey::commands::GetComposingString_CharType_ALPHABET_HALF,
                preedit_.text());
            break;
    }
    preedit_.setSimplePreeditHighlighted(converted);
    livePreeditIndex_ = -1;
    auto candidateList = ic_->inputPanel().candidateList();
    if (candidateList) {
        ic_->inputPanel().setCandidateList(nullptr);
        setAuxDownText(std::nullopt);
    }
}

/// Show Candidate List

bool HazkeyState::showCandidateList(bool isSuggest) {
    currentListIsSuggest_ = isSuggest;
    auto response = engine_->server().getCandidates(isSuggest);
    return showCandidateList(response);
}

bool HazkeyState::showCandidateList(
    const hazkey::commands::CandidatesResult& response,
    std::optional<std::string> fallbackPreedit) {
    FCITX_DEBUG() << "HazkeyState showCandidateList";

    auto candidateResult =
        std::make_unique<HazkeyCandidateList>(response.candidates());

    candidateResult->setSelectionHandler([this](int globalIndex) {
        // A click on a list rendered before a still-pending display refresh
        // would commit a stale candidate and drop the trailing input. Resolve
        // the pending refresh and drop this stale click: the refreshed list is
        // then shown for the user to click again.
        if (coalescer_.hasPending()) {
            // This handler runs outside HazkeyEngine::keyEvent(), so the
            // refreshed preedit/input panel must be published explicitly --
            // otherwise the screen keeps showing the stale list and a second
            // click could map to the wrong candidate.
            flushPendingRefresh();
            ic_->updatePreedit();
            ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
            return;
        }
        auto candidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
            ic_->inputPanel().candidateList());
        if (candidateList != nullptr &&
            candidateList->globalCursorIndex() == globalIndex) {
            candidateCompleteHandler(candidateList);
        }
    });

    candidateResult->setSelectionKey(defaultSelectionKeys);

    ic_->inputPanel().reset();

    if (cachedAutoConvertMode_ !=
            hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED &&
        !response.live_text().empty()) {
        // preedit conversion is enabled and conversion result is found
        // show preedit conversion result
        preedit_.setSimplePreedit(response.live_text());
    } else if (fallbackPreedit != std::nullopt) {
        preedit_.setSimplePreedit(*fallbackPreedit);
    } else {
        // preedit conversion is disabled or conversion result is not
        // available show hiragana preedit
        auto hiragana = engine_->server().getComposingText(
            hazkey::commands::GetComposingString_CharType_HIRAGANA,
            preedit_.text());
        preedit_.setSimplePreedit(hiragana);
    }

    livePreeditIndex_ = response.live_text_index();

    const bool hasCandidates =
        response.page_size() > 0 && response.candidates_size() > 0;
    if (hasCandidates) {
        ic_->inputPanel().setCandidateList(std::move(candidateResult));
        auto newFcitxCandidateList =
            std::dynamic_pointer_cast<HazkeyCandidateList>(
                ic_->inputPanel().candidateList());
        // No lower clamp is needed: hasCandidates above already guarantees
        // page_size() > 0, so this only caps the upper bound at the 10
        // selection keys. (The server also normalizes numCandidatesPerPage to
        // 1..10 via HazkeyServerConfig.normalizeProfile(_:), but the > 0 gate
        // is what makes the clamp safe. The IBus frontend's
        // std::clamp(rawPageSize, 1, 16) has the same redundant lower bound.)
        int pageSize = std::min(static_cast<size_t>(response.page_size()),
                                defaultSelectionKeys.size());
        newFcitxCandidateList->setPageSize(pageSize);
    }

    // true if the list is displayed
    return hasCandidates;
}

void HazkeyState::showNonPredictCandidateList(bool preserveTarget) {
    // A pending deferred suggest refresh must not fire after this and overwrite
    // the non-predict list (exempted while the coalescer executes its own
    // pending refresh, which may legitimately be a non-predict one).
    if (!executingPendingRefresh_) {
        cancelPendingRefresh();
    }
    if (!preserveTarget) {
        engine_->server().moveCursor(1024);
        isClauseBoundaryAdjusting_ = false;
    }
    if (!showCandidateList(false)) {
        return;
    }

    livePreeditIndex_ = -1;

    // highlight all preedit text
    // because the first candidate is the result of all preedit text.
    auto currentPreedit = preedit_.text();
    preedit_.setSimplePreeditHighlighted(currentPreedit);

    auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
        ic_->inputPanel().candidateList());
    newCandidateList->focus();
    updateCandidateCursor(newCandidateList);
    setCandidateCursorAUX(
        std::static_pointer_cast<HazkeyCandidateList>(newCandidateList));
}

void HazkeyState::showNonPredictCandidateList(
    const hazkey::commands::CandidatesResult& response,
    const std::string& hiragana) {
    if (!executingPendingRefresh_) {
        cancelPendingRefresh();
    }
    currentListIsSuggest_ = false;
    if (!showCandidateList(response, hiragana)) {
        return;
    }

    livePreeditIndex_ = -1;

    preedit_.setSimplePreeditHighlighted(hiragana);

    auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
        ic_->inputPanel().candidateList());
    newCandidateList->focus();
    updateCandidateCursor(newCandidateList);
    setCandidateCursorAUX(
        std::static_pointer_cast<HazkeyCandidateList>(newCandidateList));
}

void HazkeyState::showPreeditCandidateList() {
    if (engine_->server()
            .getComposingText(
                hazkey::commands::GetComposingString_CharType_HIRAGANA,
                preedit_.text())
            .size() <= 0) {
        reset();
        return;
    }
    if (showCandidateList(true) && engine_->config().showTabToSelect.value()) {
        setAuxDownText(std::string(_("[Press Tab to Select]")));
    } else {
        setAuxDownText(std::nullopt);
    }
}

/// Candidate refresh coalescing
//
// Composition with the existing client-side read-through RPC cache
// (hazkey_server_connector.h): that cache deduplicates *identical* repeated
// reads within one composition epoch and is invalidated by state-mutating
// RPCs (inputChar, deleteLeft/Right, moveCursor, setContext,
// newComposingText, etc. -- see HazkeyServerConnector::invalidateCache()
// callers). The coalescer here sits ABOVE that cache, at the call-site
// level: it does not know or care whether the eventual getCandidates() read
// would hit the cache or not, it only reduces HOW OFTEN that call happens
// by collapsing several rapid keystrokes' worth of display-only refresh
// requests into a single deferred execution.
//
// Latency: coalescing is LEADING-EDGE (see candidate_refresh_coalescer.h).
// The first refresh of a typing burst runs synchronously inside the key
// event, exactly like the uncoalesced call sites did, because at ordinary
// typing speed keystrokes are far more than one quiet period apart and a
// purely trailing debounce would add kCandidateRefreshCoalesceUsec to the
// visible feedback of every keystroke while never merging anything. Only
// keystrokes that arrive while the previous refresh is still within the
// quiet period are deferred and merged into one trailing execution.
//
// When a deferred refresh finally runs, it goes through showCandidateList(true) ->
// engine_->server().getCandidates(true) exactly as an uncoalesced call
// would, so it still benefits from (and does not fight with) the
// connector's cache. Scheduling never invalidates the cache -- only state
// mutations do that, and state-mutating operations (inputChar's RPC itself,
// commit, delete/cursor, clause-boundary adjustment, live-convert toggle,
// direct conversion) bypass the coalescer entirely and stay synchronous.
//
// Thread-safety: fcitx5 key events and this addon's event-loop timer
// callbacks both run on fcitx5's single event-loop thread (there is no
// separate worker thread involved anywhere in this addon), so coalescer_,
// refreshTimer_, and pendingRefreshIsSuggest_ need no locking.

void HazkeyState::scheduleCandidateRefresh(bool isSuggest) {
    pendingRefreshIsSuggest_ = isSuggest;
    const uint64_t nowUsec = now(CLOCK_MONOTONIC);

    // Leading edge: nothing pending and the previous refresh is older than
    // one quiet period, so there is nothing to coalesce with -- run now and
    // keep keystroke feedback latency at zero added milliseconds.
    // scheduleCandidateRefresh() is only reached from noPreeditKeyEvent()
    // and preeditKeyEvent(), both of which filterAndAccept() the event, so
    // HazkeyEngine::keyEvent() calls updatePreedit()/updateUserInterface()
    // right after this dispatch returns -- unlike the timer path below, no
    // explicit push is needed (or wanted: it would be a redundant second
    // update of identical content).
    if (coalescer_.shouldRunImmediately(nowUsec,
                                        hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // An armed timer must not survive an immediate run: onRun() consumes
        // the pending slot, so the old callback would be a stale duplicate.
        refreshTimer_.reset();
        coalescer_.onRun(nowUsec);
        runPendingCandidateRefresh();
        return;
    }

    if (coalescer_.shouldSchedule(nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // Assigning to refreshTimer_ destroys any previously-owned
        // EventSourceTime first (std::unique_ptr::operator= semantics),
        // which cancels the old pending callback before the new one is
        // armed -- this is what makes "latest-wins" actually true at the
        // real-timer level, not just in the policy's bookkeeping.
        refreshTimer_ = engine_->instance()->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, nowUsec + hazkey::frontend::kCandidateRefreshCoalesceUsec, 0,
            [this](EventSourceTime*, uint64_t) {
                firePendingCandidateRefresh();
                return true;
            });
    }
}

void HazkeyState::firePendingCandidateRefresh() {
    const uint64_t nowUsec = now(CLOCK_MONOTONIC);
    if (!coalescer_.shouldFire(nowUsec)) {
        // Stale/duplicate callback (should not normally happen given the
        // replace-on-schedule behavior above, but the policy is defensive).
        return;
    }
    coalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
    // Unlike a synchronous keyEvent() dispatch (where HazkeyEngine::keyEvent
    // calls updatePreedit()/updateUserInterface() after propertyFor(...)
    // returns), this refresh runs from the event-loop timer callback with
    // no enclosing keyEvent dispatch, so both calls must be made explicitly
    // here to push the updated preedit/candidate list to the client.
    ic_->updatePreedit();
    ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

// Executes the latest requested refresh kind. Shared by both execution
// paths so the leading-edge (synchronous) and trailing (timer) runs cannot
// drift apart; the UI push differs between them and stays at the call site.
void HazkeyState::runPendingCandidateRefresh() {
    executingPendingRefresh_ = true;
    if (pendingRefreshIsSuggest_) {
        showPreeditCandidateList();
    } else {
        showNonPredictCandidateList(/*preserveTarget=*/true);
    }
    executingPendingRefresh_ = false;
}

void HazkeyState::cancelPendingRefresh() {
    // Dropping the unique_ptr destroys the underlying EventSourceTime
    // (fcitx-utils/event.h: EventSource's destructor
    // disarms/removes it from the event loop), so the callback captured in
    // scheduleCandidateRefresh() can never run afterwards -- there is no
    // path back into firePendingCandidateRefresh() once refreshTimer_ is
    // reset. This, together with clearing the policy state, is why reset()
    // calling cancelPendingRefresh() satisfies the invariant that no
    // pending callback may mutate the input panel after reset/deactivate.
    refreshTimer_.reset();
    // resetPolicy() rather than onCancel(): reset() begins a NEW composition
    // epoch, whose first refresh must never be deferred. onCancel() alone
    // would leave the previous epoch's run timestamp behind, and the
    // leading-edge predicate would read it as "a refresh just ran" and defer
    // the first keystroke of the new composition by a full quiet period.
    coalescer_.resetPolicy();
}

// Runs a pending coalesced refresh immediately instead of discarding it, so a
// caller that is about to CONSUME the client-side preedit (Return commit,
// focus-out commit, direct conversion) acts on the latest server state rather
// than the stale last-synchronously-refreshed value. Without this, a keystroke
// deferred within the coalesce window is dropped from the committed text
// (e.g. a i u e o followed by an immediate Return previously committed only
// the leading edge's first character).
void HazkeyState::flushPendingRefresh() {
    if (!coalescer_.hasPending()) {
        return;
    }
    // Drop the armed timer first so the policy's onRun() below owns the slot
    // and no stale callback can fire afterwards.
    refreshTimer_.reset();
    const uint64_t nowUsec = now(CLOCK_MONOTONIC);
    coalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
}

/// Candidate Cursor

void HazkeyState::updateCandidateCursor(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    setCandidateCursorAUX(candidateList);
    auto text =
        candidateList->getCandidate(candidateList->cursorIndex()).getPreedit();
    preedit_.setMultiSegmentPreedit(text, 0);
}

void HazkeyState::advanceCandidateCursor(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    candidateList->nextCandidate();
    updateCandidateCursor(candidateList);
}

void HazkeyState::backCandidateCursor(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    candidateList->prevCandidate();
    updateCandidateCursor(candidateList);
}

void HazkeyState::moveSegmentBoundary(bool expand) {
    auto result = engine_->server().adjustClauseBoundary(expand ? 1 : -1);
    if (result == std::nullopt) {
        isClauseBoundaryAdjusting_ = false;
        return;
    }
    isClauseBoundaryAdjusting_ = true;
    showNonPredictCandidateList(result->candidates, result->hiragana);
}

/// [community] Delete the focused candidate's AzooKey learning memory
/// entries and rebuild the candidate list from the server response. The
/// server rebuilds its list in the mode it was created in (suggest vs
/// non-predict conversion) and this side mirrors that mode so the
/// live-conversion preedit state survives the rebuild. Nothing changes
/// visually when nothing was deleted (candidate not backed by learning
/// data).
void HazkeyState::handleDeleteCandidateLearningData(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    FCITX_DEBUG() << "HazkeyState handleDeleteCandidateLearningData";

    auto result = engine_->server().deleteCandidateLearningData(
        candidateList->globalCursorIndex());
    if (result == std::nullopt || result->deleted_count == 0) {
        return;
    }
    if (currentListIsSuggest_) {
        // Suggest-mode list: showCandidateList restores the preedit from
        // live_text (same as the pre-delete display), then re-focus the
        // rebuilt list exactly like the Tab-focus path does.
        if (!showCandidateList(result->candidates)) {
            return;
        }
        auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
            ic_->inputPanel().candidateList());
        newCandidateList->focus();
        updateCandidateCursor(newCandidateList);
    } else {
        // Non-predict conversion list: the standard rebuild path (same as
        // moveSegmentBoundary).
        showNonPredictCandidateList(result->candidates, result->hiragana);
    }
}

/// AUX

void HazkeyState::setCandidateCursorAUX(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    auto label = "[" + std::to_string(candidateList->globalCursorIndex() + 1) +
                 "/" + std::to_string(candidateList->totalSize()) + "]";
    ic_->inputPanel().setAuxUp(Text(label));
    setAuxDownText(candidateList->getCandidate(candidateList->cursorIndex())
                       .hasLearningEntry()
                       ? std::optional<std::string>(_("削除可"))
                       : std::nullopt);
}

void HazkeyState::setAuxDownText(std::optional<std::string> optText) {
    auto aux = Text();
    if (engine_->server().currentInputModeIsDirect()) {
        // appending fcitx::Text is supported only >= 5.1.9
        aux.append(std::string(_("[Direct Input]")));
    } else if (optText != std::nullopt) {
        aux.append(optText.value());
    }
    ic_->inputPanel().setAuxDown(aux);
}

void HazkeyState::setHiraganaAUX() {
    // The shared transport returns a neutral ComposingTextWithCursor; the
    // fcitx adapter applies the cursor underline (was done inside the
    // connector before the extraction).
    ic_->inputPanel().setAuxUp(composingTextWithCursorToFcitxText(
        engine_->server().getComposingHiraganaWithCursor()));
}

/// Reset

void HazkeyState::reset() {
    FCITX_DEBUG() << "HazkeyState reset";
    isDirectConversionMode_ = false;
    livePreeditIndex_ = -1;
    isCursorMoving_ = false;
    isClauseBoundaryAdjusting_ = false;
    currentListIsSuggest_ = false;
    // Explicit cancellation (do not rely on RAII alone): reset() is called
    // from many keyEvent branches and from both HazkeyEngine::activate()
    // and HazkeyEngine::deactivate() (the latter is the focus-out-equivalent
    // for an IME) without the HazkeyState object itself being destroyed, so
    // a pending coalesced refresh must be cancelled here explicitly.
    cancelPendingRefresh();
    engine_->server().newComposingText();
    ic_->inputPanel().reset();
}

}  // namespace fcitx

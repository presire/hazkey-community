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
#include "composing_cursor_view.h"
#include "fcitx-utils/keysym.h"
#include "hazkey_candidate.h"
#include "hazkey_engine.h"
#include "hazkey_server_connector.h"
#include "live_convert_mode.h"

namespace fcitx {

/** @brief 入力状態を初期化して、サーバ側の組成を開始する */
HazkeyState::HazkeyState(HazkeyEngine* engine, InputContext* ic)
    : engine_(engine), ic_(ic), preedit_(HazkeyPreedit(ic)) {
    engine_->server().newComposingText();
}

/** @brief キーイベントが文字入力として扱えるか判定する */
bool HazkeyState::isInputableEvent(const KeyEvent& event) {
    auto key = event.key();
    if (key.check(FcitxKey_space) || key.isSimple() ||
        Key::keySymToUTF8(key.sym()).size() > 1 ||
        (key.sym() >= 0x04a1 && key.sym() <= 0x04df)) {
        // 0x04a1から0x04ddはかなキーの範囲
        return true;
    }
    return false;
}

/** @brief 保留中の候補更新を反映してからpreeditを確定する */
void HazkeyState::commitPreedit() {
    // フォーカス解除時に古いpreeditを確定しないよう、保留中の表示更新を先に反映する
    flushPendingRefresh();
    preedit_.commitPreedit();
}

/** @brief 入力モードに応じて、キーイベントを振り分ける */
void HazkeyState::keyEvent(KeyEvent& event) {
    FCITX_DEBUG() << "HazkeyState keyEvent";

    if (!event.isRelease() && event.key().sym() != FcitxKey_Shift_L && event.key().sym() != FcitxKey_Shift_R) {
        shiftPressedAlone_ = false;
    }

    if (!event.isRelease()) {
        if (!serverProfileLoaded_ || engine_->server().consumeConfigChanged()) {
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
            // [Shift]以外の修飾キーが押下されてない場合を単独押下として扱う
            // キー押下イベントでは[Shift]状態が反映前の値となり、押下状態が空の場合もある
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

/** @brief preeditがない状態のキーイベントを処理する */
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
                // Zenzaiの左文脈を最新に保つ
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
                // 表示専用の更新を間引き、連続入力時の候補再描画をまとめる
                // 状態を変更するinputCharは同期実行し、遅延させない
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

/** @brief 組成中のキーイベントを処理する */
void HazkeyState::preeditKeyEvent(
    KeyEvent& event,
    std::shared_ptr<HazkeyCandidateList> PredictCandidateList) {
    FCITX_DEBUG() << "HazkeyState preeditKeyEvent";

    auto key = event.key();
    auto keysym = key.sym();

    switch (keysym) {
        case FcitxKey_Return:
            // 古いpreeditではなく最新の組成を確定できるよう、保留中の更新を反映する
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
                // Zenzaiの左文脈を最新に保つ
                updateSurroundingText();
                engine_->server().inputChar(" ");
                refreshAfterComposingEdit();
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
                // フォーカスする候補リストへ全入力を反映して、古い候補の確定による入力欠落を防ぐ
                flushPendingRefresh();
                auto freshList =
                    std::dynamic_pointer_cast<HazkeyCandidateList>(
                        ic_->inputPanel().candidateList());
                if (freshList != nullptr) {
                    freshList->focus();
                    updateCandidateCursor(freshList);
                } else {
                    // 予測候補が消えた場合は、キーを捨てず非予測変換へ切り替える
                    showNonPredictCandidateList();
                }
            }
            break;
        case FcitxKey_Left:
            if (key.states() == KeyState::Shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(false);
            } else {
                moveComposingCursor(-1);
            }
            break;
        case FcitxKey_Right:
            if (key.states() == KeyState::Shift) {
                showNonPredictCandidateList();
                moveSegmentBoundary(true);
            } else {
                moveComposingCursor(1);
            }
            break;
        // 組成中の[Home]と[End]は常に消費して、アプリケーションではなく組成カーソルを移動する
        // 移動量はサーバ側で制限され、IBus版も同じキーを処理する
        case FcitxKey_Home:
        case FcitxKey_KP_Home:
            moveComposingCursor(-1024);
            break;
        case FcitxKey_End:
        case FcitxKey_KP_End:
            moveComposingCursor(1024);
            break;
        default:
            if (event.key().states() == KeyState::Ctrl) {
                ctrlShortcutHandler(event);
            } else if (isAltDigitKeyEvent(event)) {
                if (PredictCandidateList != nullptr) {
                    // 古い候補ではなく、最新のリストから[Alt+数字]で選択する
                    flushPendingRefresh();
                    auto freshList =
                        std::dynamic_pointer_cast<HazkeyCandidateList>(
                            ic_->inputPanel().candidateList());
                    if (freshList != nullptr) {
                        const int localIndex =
                            static_cast<int>(keysym - FcitxKey_1);
                        // 最終ページは、候補数がページサイズに満たないため、実在する候補の範囲で選択する
                        // 範囲外を許すと、選択が失敗しても古いカーソル位置の候補を確定してしまう
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
                // Zenzaiの左文脈を更新する
                updateSurroundingText();
                engine_->server().inputChar(Key::keySymToUTF8(keysym));
                refreshAfterComposingEdit();
            }
            break;
    }
    return event.filterAndAccept();
}

/** @brief [Alt] + [数字]による候補選択キーか判定する */
bool HazkeyState::isAltDigitKeyEvent(const KeyEvent& event) {
    auto key = event.key();
    if (key.states() == KeyState::Alt && key.sym() >= FcitxKey_1 &&
        key.sym() <= FcitxKey_9) {
        return true;
    }
    return false;
}

/** @brief 候補リストにフォーカスがある状態のキーイベントを処理する */
void HazkeyState::candidateKeyEvent(
    KeyEvent& event, std::shared_ptr<HazkeyCandidateList> candidateList) {
    FCITX_DEBUG() << "HazkeyState candidateKeyEvent";

    auto key = event.key();
    auto keysym = key.sym();

    // [Ctrl] + [D]等の学習データ削除キーを先に判定する
    // [Ctrl]系キーはswitchのdefault節で処理されるため、この判定を先に行う
    if (key.check(deleteLearningHotkey_)) {
        handleDeleteCandidateLearningData(candidateList);
        return event.filterAndAccept();
    }

    // 予測候補のフォーカス中のみ候補を受け入れ、組成を維持してサーバから候補を再取得する
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
                // 何もしない
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
                // [Alt] + [数字]と数字キーのどちらも、現在のページに存在する候補だけを選択する
                // 最終ページの空き枠を選択して誤った候補を確定しない
                if (HazkeyCandidateList::pageLocalIndexInRange(
                        candidateList->pageSize(), candidateList->totalSize(),
                        candidateList->currentPage(), localIndex)) {
                    candidateList->setCursorIndex(localIndex);
                    candidateCompleteHandler(candidateList);
                }
            } else if (isInputableEvent(event)) {
                // 確定文字列と周辺テキストが遅れないよう保留中の更新を反映する
                flushPendingRefresh();
                auto committedText = preedit_.text();
                preedit_.commitPreedit();
                reset();
                // 確定後もZenzaiの左文脈を最新に保つ
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

/** @brief 選択候補の先頭文節を確定して、残りの組成を更新する */
void HazkeyState::candidateCompleteHandler(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    auto preedit =
        candidateList->getCandidate(candidateList->cursorIndex()).getPreedit();
    // 確定直後は周辺テキストを正しく取得できないため、確定前に文字列を追加して反映する
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

/** @brief 入力先の周辺テキストをサーバへ反映する */
void HazkeyState::updateSurroundingText(std::string appendText) {
    if (ic_->capabilityFlags().test(CapabilityFlag::SurroundingText) &&
        ic_->surroundingText().isValid()) {
        auto& surroundingText = ic_->surroundingText();
        // anchor()は文字数単位のためappendTextも文字数で加算する
        engine_->server().setContext(
            surroundingText.text() + appendText,
            surroundingText.anchor() + utf8::lengthValidated(appendText));
    } else {
        engine_->server().setContext("", 0);
    }
}

/** @brief サーバプロファイルからホットキーと表示設定を読み込む */
void HazkeyState::loadServerProfile() {
    auto configOpt = engine_->server().getServerConfig();
    if (!configOpt.has_value() || configOpt->profiles_size() == 0) {
        return;  // サーバ未準備のため既定値を維持
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
    // 学習データ削除キーは入力コンテキストごとに読み込み、設定変更後のコンテキストから反映する
    const std::string& deleteHotkey = profile.delete_learning_hotkey();
    deleteLearningHotkey_ =
        Key(deleteHotkey.empty() ? "Control+D" : deleteHotkey);
    cachedAutoConvertMode_ = profile.auto_convert_mode();
    cachedAuxTextMode_ = profile.aux_text_mode();
    using M = hazkey::config::Profile_AutoConvertMode;
    // サーバのモードが無効以外の場合だけ、復帰用の有効モードを更新する
    // 無効時は直前の値を保持して、再度有効にした時に元のモードへ戻す
    // rememberedOnMode_はコネクタ側で共有され、アプリケーション間のフォーカス移動後も維持される
    if (cachedAutoConvertMode_ !=
        M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED) {
        engine_->server().rememberedOnMode() = cachedAutoConvertMode_;
    }
    serverProfileLoaded_ = true;
}

/** @brief ホットキーでライブ変換モードを切り替える */
void HazkeyState::handleLiveConvertToggle([[maybe_unused]] KeyEvent& event) {
    FCITX_DEBUG() << "HazkeyState handleLiveConvertToggle";

    auto prevMode = cachedAutoConvertMode_;
    auto& sharedRemembered = engine_->server().rememberedOnMode();
    auto prevRemembered = sharedRemembered;

    cachedAutoConvertMode_ = computeNextAutoConvertMode(cachedAutoConvertMode_, sharedRemembered);

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

#if defined(HAZKEY_HAS_SHOW_CUSTOM_IM_INFO)
    // 一時通知APIは、Fcitx 5.1.11以降で利用できる
    engine_->instance()->showCustomInputMethodInformation(ic_,
        cachedAutoConvertMode_ ==
                hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED
            ? _("Live conversion disabled")
            : _("Live conversion enabled"));
#else
    // Fcitx 5.1.11未満では切り替えは動作するが一時通知は表示できない
#endif

    auto composingText = engine_->server().getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, preedit_.text());
    if (composingText.empty()) {
        ic_->updateUserInterface(
            fcitx::UserInterfaceComponent::InputPanel);
        return;
    }
    showCandidateList(true);
    ic_->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

/** @brief サーバのニューラル変換設定を切り替える */
void HazkeyState::handleZenzaiToggle() {
    FCITX_DEBUG() << "HazkeyState handleZenzaiToggle";

    const auto enabled = engine_->server().toggleZenzai();
    if (!enabled.has_value()) {
        return;
    }
#if defined(HAZKEY_HAS_SHOW_CUSTOM_IM_INFO)
    engine_->instance()->showCustomInputMethodInformation(ic_, enabled.value() ? _("Neural conversion enabled") : _("Neural conversion disabled"));
#else
    // Fcitx 5.1.11未満では切り替えは動作するが一時通知は表示できない
#endif
}

/** @brief [Ctrl]系ショートカットを処理する */
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

/** @brief ファンクションキーによる直接変換を処理する */
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

/** @brief 組成文字列を指定した文字種へ直接変換する */
void HazkeyState::directCharactorConversion(ConversionMode mode) {
    // 変換元のpreeditが古くならないよう保留中の更新を先に反映する
    flushPendingRefresh();
    std::string converted;
    // TODO: プログラム全体でprotobuf型を使用する
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

/** @brief サーバから候補を取得して入力パネルへ設定する */
bool HazkeyState::showCandidateList(bool isSuggest) {
    currentListIsSuggest_ = isSuggest;
    // キャレット位置で一時停止するのはライブ変換表示のみ
    // 非予測変換ではカーソルを末尾へ移動済み、または、文節境界調整中のため現在位置を維持する
    if (isSuggest && showPausedPreeditIfCursorInside()) {
        return false;
    }
    auto response = engine_->server().getCandidates(isSuggest);
    return showCandidateList(response);
}

/** @brief 変換を一時停止して、生かなとキャレットを表示する */
void HazkeyState::showPausedRawPreedit(
    const hazkey::frontend::ComposingTextWithCursor& parts) {
    ic_->inputPanel().reset();
    preedit_.setRawPreeditWithCaret(hazkey::frontend::composingTextOf(parts), static_cast<int>(hazkey::frontend::caretByteOffset(parts)));
    // ライブ変換結果を表示していないため、[Return]では見えていない候補ではなく、生かなを確定する
    livePreeditIndex_ = -1;
    // inputPanel().reset()で消えた直接入力表示を復元する
    // 候補リストがないため[Tab]選択の案内は表示しない
    setAuxDownText(std::nullopt);
}

/** @brief キャレットが末尾以外なら、一時停止表示へ切り替える */
bool HazkeyState::showPausedPreeditIfCursorInside() {
    const auto parts = engine_->server().getComposingHiraganaWithCursor();
    if (hazkey::frontend::cursorAtEnd(parts)) {
        return false;
    }
    showPausedRawPreedit(parts);
    return true;
}

/** @brief 組成カーソルを移動して、位置に応じた表示へ更新する */
void HazkeyState::moveComposingCursor(int offset) {
    if (offset > 0 && hazkey::frontend::cursorAtEnd(
                          engine_->server().getComposingHiraganaWithCursor())) {
        // 組成末尾で[Right]または[End]を押下しても移動先がない
        // 呼び出し元でキーは消費するが、RPCと再描画は行わない
        return;
    }
    // 以下の同期描画で置き換えるため、保留中の更新を取り消す
    cancelPendingRefresh();
    engine_->server().moveCursor(offset);
    // moveCursor()でコネクタのキャッシュが無効になるため、再取得で新しい位置を得る
    // オフセットはサーバ側で制限されるため±1024を指定できる
    const auto parts = engine_->server().getComposingHiraganaWithCursor();
    if (hazkey::frontend::cursorAtEnd(parts)) {
        showPreeditCandidateList();
        return;
    }
    showPausedRawPreedit(parts);
}

/** @brief 組成編集後にライブ変換または一時停止表示を更新する */
void HazkeyState::refreshAfterComposingEdit() {
    const auto parts = engine_->server().getComposingHiraganaWithCursor();
    if (!hazkey::frontend::cursorAtEnd(parts)) {
        cancelPendingRefresh();
        showPausedRawPreedit(parts);
        return;
    }
    // 表示専用の更新を間引き、連続入力時の候補再描画をまとめる
    scheduleCandidateRefresh(/*isSuggest=*/true);
}

/** @brief 応答済み候補を入力パネルへ設定する */
bool HazkeyState::showCandidateList(
    const hazkey::commands::CandidatesResult& response,
    std::optional<std::string> fallbackPreedit) {
    FCITX_DEBUG() << "HazkeyState showCandidateList";

    auto candidateResult =
        std::make_unique<HazkeyCandidateList>(response.candidates());

    candidateResult->setSelectionHandler([this](int globalIndex) {
        // 更新前の候補クリックで古い候補を確定すると、後続入力が失われる
        // 更新を反映してクリックを無効にして、新しい候補リストを表示して選び直せるようにする
        if (coalescer_.hasPending()) {
            // この処理は、HazkeyEngine::keyEvent()の外で実行されるため、更新後の表示を明示的に通知する
            // 通知しないと古いリストが残り、次のクリックが誤った候補を指す可能性がある
            flushPendingRefresh();
            ic_->updatePreedit();
            ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
            return;
        }
        auto candidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(ic_->inputPanel().candidateList());
        if (candidateList != nullptr && candidateList->globalCursorIndex() == globalIndex) {
            candidateCompleteHandler(candidateList);
        }
    });

    candidateResult->setSelectionKey(defaultSelectionKeys);

    ic_->inputPanel().reset();

    if (cachedAutoConvertMode_ != hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED && !response.live_text().empty()) {
        // ライブ変換が有効で結果がある場合は、変換結果を表示する
        preedit_.setSimplePreedit(response.live_text());
        // livePreeditIndex_は応答に番号があるかではなく、表示中のlive_textの候補番号を表す
        // [Return]でその候補を確定するため、変換結果を表示する場合だけ設定する
        livePreeditIndex_ = response.live_text_index();
    } else if (fallbackPreedit != std::nullopt) {
        preedit_.setSimplePreedit(*fallbackPreedit);
        livePreeditIndex_ = -1;
    } else {
        // ライブ変換が無効、または、結果がない場合はひらがなのpreeditを表示する
        auto hiragana = engine_->server().getComposingText(
            hazkey::commands::GetComposingString_CharType_HIRAGANA,
            preedit_.text());
        preedit_.setSimplePreedit(hiragana);
        livePreeditIndex_ = -1;
    }

    const bool hasCandidates =
        response.page_size() > 0 && response.candidates_size() > 0;
    if (hasCandidates) {
        ic_->inputPanel().setCandidateList(std::move(candidateResult));
        auto newFcitxCandidateList =
            std::dynamic_pointer_cast<HazkeyCandidateList>(
                ic_->inputPanel().candidateList());
        // 候補がある場合はpage_size()が正のため、選択キー数を上限として制限する
        // サーバ側でも候補数は1〜10に正規化される
        int pageSize = std::min(static_cast<size_t>(response.page_size()), defaultSelectionKeys.size());
        newFcitxCandidateList->setPageSize(pageSize);
    }

    // 候補リストを表示した場合はtrue
    return hasCandidates;
}

/** @brief 非予測変換候補を取得して表示する */
void HazkeyState::showNonPredictCandidateList(bool preserveTarget) {
    // 保留中の予測更新が後から実行されて、非予測候補を上書きしないようにする
    // 間引き器自身が更新を実行中の場合は、その更新を許可する
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

    // 先頭候補はpreedit全体の変換結果であるため、preedit全体を強調表示する
    auto currentPreedit = preedit_.text();
    preedit_.setSimplePreeditHighlighted(currentPreedit);

    auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(ic_->inputPanel().candidateList());
    newCandidateList->focus();
    updateCandidateCursor(newCandidateList);
    setCandidateCursorAUX(std::static_pointer_cast<HazkeyCandidateList>(newCandidateList));
}

/** @brief 応答済みの非予測候補を表示する */
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

    auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(ic_->inputPanel().candidateList());
    newCandidateList->focus();
    updateCandidateCursor(newCandidateList);
    setCandidateCursorAUX(std::static_pointer_cast<HazkeyCandidateList>(newCandidateList));
}

/** @brief 予測候補リストを取得して表示する */
void HazkeyState::showPreeditCandidateList() {
    if (engine_->server().getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, preedit_.text()).size() <= 0) {
        reset();
        return;
    }

    if (showCandidateList(true) && engine_->config().showTabToSelect.value()) {
        setAuxDownText(std::string(_("[Press Tab to Select]")));
    } else {
        setAuxDownText(std::nullopt);
    }
}

/** @brief 表示専用候補更新を間引いて、実行または予約する
 *  @param isSuggest 予測候補の更新ならtrue
 */
// 表示更新の間引きは、同一の読み取りをまとめるクライアント側RPCキャッシュより上位で動作する
// RPCキャッシュは、組成中の同一読み取りを再利用して、状態変更RPCで無効化される
// 間引き器は、候補取得を呼び出す頻度を抑え、短時間に発生した表示更新をまとめる
//
// 間引きは先行エッジ方式で、入力連続の最初の更新は同期実行する
// 前回の更新から静穏期間内に続いた入力だけを遅延し、後続の1度の更新へまとめる
// 遅延更新も通常と同じ候補取得経路を通るため、RPCキャッシュと併用できる
// 入力や削除等の状態変更処理は、間引き器を通さず同期実行する
//
// キーイベントとタイマコールバックは、Fcitx 5のイベントループ上で実行される
// そのため、ここで管理する状態にロックは不要
void HazkeyState::scheduleCandidateRefresh(bool isSuggest) {
    pendingRefreshIsSuggest_ = isSuggest;
    const uint64_t nowUsec = now(CLOCK_MONOTONIC);

    // 保留更新がなく、前回の更新から静穏期間が過ぎていれば、遅延を加えず直ちに実行する
    // この経路は、キーイベント処理から呼ばれるため、復帰後にエンジンが表示を通知する
    if (coalescer_.shouldRunImmediately(nowUsec,
                                        hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // 即時実行で保留枠を消費するため、古いタイマも取り消す
        refreshTimer_.reset();
        coalescer_.onRun(nowUsec);
        runPendingCandidateRefresh();
        return;
    }

    if (coalescer_.shouldSchedule(nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // タイマの代入により、以前のイベントを破棄してから新しいタイマを設定する
        // これにより、実際のタイマでも最新の要求だけが有効になる
        refreshTimer_ = engine_->instance()->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, nowUsec + hazkey::frontend::kCandidateRefreshCoalesceUsec, 0,
            [this](EventSourceTime*, uint64_t) {
                firePendingCandidateRefresh();
                return true;
            });
    }
}

/** @brief タイマから期限到来した候補更新を実行する */
void HazkeyState::firePendingCandidateRefresh() {
    const uint64_t nowUsec = now(CLOCK_MONOTONIC);
    if (!coalescer_.shouldFire(nowUsec)) {
        // 古い、または、重複したコールバックは実行しない
        return;
    }
    coalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
    // タイマ経由ではキーイベント処理後の自動通知がないため、更新後の表示を明示的に通知する
    ic_->updatePreedit();
    ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

/** @brief 最新の予約候補更新を実行する */
void HazkeyState::runPendingCandidateRefresh() {
    executingPendingRefresh_ = true;
    if (pendingRefreshIsSuggest_) {
        showPreeditCandidateList();
    } else {
        showNonPredictCandidateList(/*preserveTarget=*/ true);
    }
    executingPendingRefresh_ = false;
    // 次の静穏期間は変換開始時ではなく、完了時から計測する
    coalescer_.onRunFinished(now(CLOCK_MONOTONIC));
}

/** @brief タイマと間引き器の保留状態を破棄する */
void HazkeyState::cancelPendingRefresh() {
    // タイマを破棄するとイベントループから解除されて、登録済みコールバックは実行されない
    // 間引き状態も消去して、リセット後に保留コールバックが入力パネルを変更しないようにする
    refreshTimer_.reset();
    // リセット後は新しい組成となるため、前の実行時刻を残さず間引きポリシー全体を初期化する
    // 以前の時刻が残ると、新しい組成の最初の更新まで遅延する
    coalescer_.resetPolicy();
}

/** @brief 保留中の候補更新を破棄せず直ちに実行する */
void HazkeyState::flushPendingRefresh() {
    if (!coalescer_.hasPending()) {
        return;
    }
    // 間引き状態を実行へ移す前にタイマを解除して、古いコールバックを防ぐ
    refreshTimer_.reset();
    const uint64_t nowUsec = now(CLOCK_MONOTONIC);
    coalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
}

/** @brief カーソル候補に合わせて、補助表示とpreeditを更新する */
void HazkeyState::updateCandidateCursor(std::shared_ptr<HazkeyCandidateList> candidateList) {
    setCandidateCursorAUX(candidateList);
    auto text = candidateList->getCandidate(candidateList->cursorIndex()).getPreedit();
    preedit_.setMultiSegmentPreedit(text, 0);
}

/** @brief 候補カーソルを次へ進めて、表示を更新する */
void HazkeyState::advanceCandidateCursor(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    candidateList->nextCandidate();
    updateCandidateCursor(candidateList);
}

/** @brief 候補カーソルを前へ戻して、表示を更新する */
void HazkeyState::backCandidateCursor(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    candidateList->prevCandidate();
    updateCandidateCursor(candidateList);
}

/** @brief 変換文節の境界を移動する */
void HazkeyState::moveSegmentBoundary(bool expand) {
    auto result = engine_->server().adjustClauseBoundary(expand ? 1 : -1);
    if (result == std::nullopt) {
        isClauseBoundaryAdjusting_ = false;
        return;
    }
    isClauseBoundaryAdjusting_ = true;
    showNonPredictCandidateList(result->candidates, result->hiragana);
}

/** @brief フォーカス候補の学習データを削除して、同じ表示種別で再構築する
 *  @param candidateList フォーカス中の候補リスト
 */
void HazkeyState::handleDeleteCandidateLearningData(
    std::shared_ptr<HazkeyCandidateList> candidateList) {
    FCITX_DEBUG() << "HazkeyState handleDeleteCandidateLearningData";

    auto result = engine_->server().deleteCandidateLearningData(
        candidateList->globalCursorIndex());
    if (result == std::nullopt || result->deleted_count == 0) {
        return;
    }
    if (currentListIsSuggest_) {
        // 予測候補では削除前と同じlive_textを表示して、再構築した候補リストへフォーカスする
        if (!showCandidateList(result->candidates)) {
            return;
        }
        auto newCandidateList = std::dynamic_pointer_cast<HazkeyCandidateList>(
            ic_->inputPanel().candidateList());
        newCandidateList->focus();
        updateCandidateCursor(newCandidateList);
    } else {
        // 非予測候補は、文節境界調整と同じ経路で再構築する
        showNonPredictCandidateList(result->candidates, result->hiragana);
    }
}

/** @brief 候補位置と学習データ削除可否を、補助表示へ反映する */

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

/** @brief AuxDownへ状態に応じた文字列を設定する */
void HazkeyState::setAuxDownText(std::optional<std::string> optText) {
    auto aux = Text();
    if (engine_->server().currentInputModeIsDirect()) {
        // fcitx::Textへの追加は、Fcitx 5.1.9以降で利用できる
        aux.append(std::string(_("[Direct Input]")));
    } else if (optText != std::nullopt) {
        aux.append(optText.value());
    }
    ic_->inputPanel().setAuxDown(aux);
}

/** @brief 未変換ひらがなをAuxUpへ表示する */
void HazkeyState::setHiraganaAUX() {
    // 共通トランスポートは、中立なカーソル付き組成データを返す
    // カーソルの下線表示は、Fcitxアダプタ側で適用する
    const auto parts = engine_->server().getComposingHiraganaWithCursor();
    if (!hazkey::frontend::shouldShowAuxText(cachedAuxTextMode_, hazkey::frontend::cursorAtEnd(parts))) {
        ic_->inputPanel().setAuxUp(Text());
        return;
    }
    ic_->inputPanel().setAuxUp(composingTextWithCursorToFcitxText(parts));
}

/** @brief 組成・候補表示・保留中の表示更新を初期状態へ戻す */
void HazkeyState::reset() {
    FCITX_DEBUG() << "HazkeyState reset";

    isDirectConversionMode_ = false;
    livePreeditIndex_ = -1;
    isClauseBoundaryAdjusting_ = false;
    currentListIsSuggest_ = false;

    // reset()は、オブジェクト破棄なしに多数のキー処理やactivate() / deactivate()から呼ばれる
    // RAIIだけに頼らず保留中の更新を明示的に取り消す
    cancelPendingRefresh();
    engine_->server().newComposingText();
    ic_->inputPanel().reset();
}

}  // namespace fcitx

/**
 * @file hazkey_state.cpp
 * @brief IBusフロントエンドの入力状態機械の実装
 *
 * 公開APIの仕様はヘッダ (hazkey_state.h) を参照のこと
 */
#include "hazkey_state.h"
#include <algorithm>
#include <functional>
#include <utility>
#include "composing_cursor_view.h"
#include "hazkey_frontend_hooks.h"
#include "live_convert_mode.h"

// サポートするIBusの下限は、1.5.32 (Debian 13 Trixie / Fedora 44 / openSUSE Leap 16は、1.5.33 / 1.5.34を搭載)
// パネルがpreedit選択範囲を独自スタイルで描画できるIBUS_ATTR_TYPE_HINTマクロは1.5.33以降にしか存在しないため、使用可能な場合にのみ適用する
// 1.5.32では、hintの横で無条件に設定する素朴なIBUS_ATTR_TYPE_UNDERLINE属性により選択範囲は依然として可視である
#if IBUS_CHECK_VERSION(1, 5, 33)
#define HAZKEY_IBUS_HAS_ATTR_TYPE_HINT 1
#else
#define HAZKEY_IBUS_HAS_ATTR_TYPE_HINT 0
#endif

namespace hazkey::ibus {

namespace {

/**
 * @brief プロセス共有のサーバ接続を取得する
 *
 * エンジン構築時にHazkeyState経由で呼ばれる
 * 構築時の接続ループをGLibメインループ上で回さないようautoConnectを無効化して作る
 *
 * @return 共有 HazkeyServerConnectorへの参照
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
HazkeyServerConnector& sharedServerConnector() {
    // autoConnect=false:
    // connectorに最初に触れるのはワーカースレッド上のため、構築時にブロックする接続ループをGLibメインループ上で回してはならない
    // (エンジン構築時に、HazkeyState経由で呼ばれる)
    static HazkeyServerConnector connector(/*autoConnect=*/false);
    return connector;
}

/**
 * @brief エンジン固有ドメインでメッセージを翻訳する
 *
 * 導入先は、<datadir>/locale/<lang>/LC_MESSAGES/ibus-hazkey.moである
 * IBusパネルはエンジンの <longname>/<description> に同じドメインを使用する
 *
 * @param messageId 翻訳対象のメッセージID
 * @return 翻訳後の文字列
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
const char* tr(const char* messageId) {
    return g_dgettext("ibus-hazkey-community", messageId);
}

/**
 * @brief ホットキー照合用にモディファイアマスクを正規化する
 *
 * IBusクライアント / ツールキットは[Super]を異なるマスクで報告する (X11は、概ねMod4で送る)
 * Mod4をIBUS_SUPER_MASKに畳み込むことにより、[Super]ホットキーがどちらの符号化にも一致するようにし、ロックキー (CapsLock / NumLock) は無視する
 *
 * @param state 正規化前のIBusモディファイア状態
 * @return 正規化後のモディファイアマスク
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
guint normalizeHotkeyModifiers(guint state) {
    guint modifiers =
        state & (IBUS_SHIFT_MASK | IBUS_CONTROL_MASK | IBUS_MOD1_MASK |
                 IBUS_MOD4_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK |
                 IBUS_META_MASK);
    if ((modifiers & IBUS_MOD4_MASK) != 0) {
        // Mod4を置換する (ORではない)
        // [Super]指定がMod4符号化イベントに一致し、逆方向も一致するようにするため
        modifiers &= ~IBUS_MOD4_MASK;
        modifiers |= IBUS_SUPER_MASK;
    }
    return modifiers;
}

/**
 * @brief ホットキー照合用にキーシンボルを正規化する
 *
 * hazkey-community-settingsはホットキーを大文字キー字を含むFcitx 5キー文字列で保存する (例: [Control] + [D])
 * IBusは、多くのクライアントで[Ctrl] + [文字]をシフトなしの小文字keyvalとして報告する
 *
 * 文字は大文字小文字を区別せず比較する
 *
 * @param keyval 正規化前のキーシンボル
 * @return 正規化後のキーシンボル
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
guint normalizeHotkeyKeyval(guint keyval) {
    if (keyval >= 'A' && keyval <= 'Z') {
        return keyval - 'A' + 'a';
    }
    return keyval;
}

/**
 * @brief [AltGr]相当のモディファイアが含まれているかを判定する
 *
 * Mod3 (Mode_switch) / Mod5 (ISO_Level3_Shift = AltGr) は、keysymグループ選択用で、厳密モディファイア述語がモデル化するFcitx KeyState集合の一部ではない
 * これらを除外することにより、 "厳密に Alt" / "厳密に Ctrl" の判定を正しく保つ
 *
 * 例: [AltGr] + [数字]を[Alt] + [数字]の候補選択と見なさず、[Ctrl] + [AltGr] + [U]を[Ctrl] + [U]直接変換と見なさない
 *
 * @param state 判定対象のIBusモディファイア状態
 * @return AltGr相当を含んでいればtrue
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
bool hasAltGrLikeModifier(guint state) {
    return (state & (IBUS_MOD3_MASK | IBUS_MOD5_MASK)) != 0;
}

/** @brief 補助テキスト枠に一時的トグルヒントを表示し続ける時間 (Fcitx 5の表示とibus-rimeの待機時間に合わせた1秒) */
constexpr uint64_t kTransientHintTimeoutUsec = 1'000'000;

/**
 * @brief ASCII英字だけを小文字化する
 *
 * @param value 変換対象の文字列
 * @return 英字を小文字化した文字列
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
std::string asciiLower(const std::string& value) {
    std::string lowered = value;
    for (char& c : lowered) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    return lowered;
}

/**
 * @brief Qtキー表記のトークンをIBusキーシンボルへ解決する
 *
 * Qt QKeySequence::PortableText (hazkey-community-settingsの保存形式) は一部のキー表記がibus_keyval_from_name()受理のX11/IBus keysym名と異なる
 * 異なる表記のみ対応付けし、それ以外 (文字、数字、F1-F35、矢印) は直接検索する
 *
 * @param token ホットキー文字列のキー部分トークン
 * @return 解決したキーシンボル、不明な表記では0またはVoidSymbol
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
guint keyvalFromHotkeyToken(const std::string& token) {
    /** @brief Qt表記とIBus keysym名の対応表 (綴りが異なる表記のみ) */
    static const struct {
        const char* qt;      ///< Qt PortableTextの表記
        const char* keysym;  ///< X11 / IBus keysym名
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
    // 初回のgetServerConfig()が遅い・失敗してもホットキーが効くよう組込み既定値を入れる
    // サーバプロファイル取得後に、loadServerProfile()が上書きする
    liveConvertHotkey_ = parseHotkey("", "Control+Shift+L");
    acceptPredictionHotkey_ = parseHotkey("", "F5");
    zenzaiToggleHotkey_ = parseHotkey("", "Control+Alt+Z");
    deleteLearningHotkey_ = parseHotkey("", "Control+D");
    // サーバ側compositionはここではリセットしない
    // フォーカスイン/enable時のresetState()からnewComposingText()を送るため、
    // 非フォーカスの入力コンテキスト用にstateを構築しても共有シングルトンconnectorのlive compositionを壊さない
}

HazkeyState::~HazkeyState() {
    // 保留中の遅延リフレッシュは、state破棄後に実行してはならない
    // デストラクタは、ワーカータスクがこのオブジェクトを参照しなくなった後に1度だけ走る (タスクはshared_ptrを保持する) ため、ここでトークンを取り消せば十分
    cancelPendingRefresh();
    cancelPendingHint();
    // IBus/GObjectはここでは所有しない
    // 共有HazkeyUiがメインループ上で所有し、破棄も行う
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
                invalid = true;  // ホットキーが持てる非モディファイアキーはちょうど1つ
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
        return HotkeySpec{};  // 閉鎖側に倒す: 不正な指定は決して一致しない
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
    // FcitxのisAltDigitKeyEvent()は、厳密にKeyState::Altを要求する
    // [Alt] + [Shift] / [Ctrl] + [Alt]は選択にならず、[1]〜[9]のみが対象
    // [Alt] + [0]は何も選択しない
    //
    // [AltGr]系モディファイアは、その集合外 (hasAltGrLikeModifier参照)
    //
    // normalizeHotkeyModifiers()のMod4 -> [Super]畳み込みとロックキー除外は、hotkeyMatches()と同じ正規化である
    if (hasAltGrLikeModifier(state)) {
        return false;
    }
    if (normalizeHotkeyModifiers(state) != IBUS_MOD1_MASK) {
        return false;
    }
    return keyval >= IBUS_KEY_1 && keyval <= IBUS_KEY_9;
}

bool HazkeyState::isDirectConversionShortcut(guint keyval, guint state) {
    // FcitxのctrlShortcutHandler()には、厳密にKeyState::Ctrlの場合のみ到達する
    // [AltGr]系モディファイア付きはアプリケーション側に残す
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
    // IBusクライアントは[Shift] + [Tab]をIBUS_KEY_ISO_Left_Tabとして報告する
    // [Tab]として扱うことで、候補モード時の[Alt] + [Shift] NOPがこの符号化も覆う
    // ([Alt]なしのISO_Left_Tabは従来どおり後方移動ブランチを使用する)
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
    // fcitxはAuxUp / AuxDownの2枠を持つが、IBusの補助テキスト枠は1つだけ
    // ここで結合し、区切りの空白は両方が非空のときだけ付ける
    // 空の生ひらがなAuxUp (auxTextMode無効、または組成末尾のカーソル時) の前に余分な先行空白を残してはならない
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
            // [Shift]単体タップはサーバ側サブ入力 (直接入力) モードを切り替える
            // AuxDownの"[Direct Input]"表示を次のキーイベントまで古いままにせず、ここで再計算する
            // fcitxのkeyEvent()も[Shift]分岐で戻る前にsetAuxDownText()を呼ぶ
            // shiftKeyEvent()がconnectorキャッシュを無効化するため、下のcurrentInputModeIsDirect()は新モードを読む
            server_.shiftKeyEvent(true, shiftPressedAlone_);
            shiftPressedAlone_ = false;
            updateInputModeProperty();
            updateAuxiliaryText();
        } else {
            // Fcitxもrelease時にAuxDownを更新する
            // アプリケーションがこのキーを受け取る場合も、IBus側の結合済み補助テキストを最新に保つ
            updateAuxiliaryText();
        }
        return FALSE;
    }
    if (shiftKey) {
        // "[Shift]単体"は、[Shift]以外のモディファイアが押されていない状態を指す
        // IBUS_SHIFT_MASK自体は要求しない
        // 修飾キー自身のKeyPressは、修飾が適用される前のstateで報告されることが多い
        // そのため、[Shift]単体でも、stateが正当に0になり得る
        shiftPressedAlone_ = isLoneShiftModifierState(state);
        server_.shiftKeyEvent(false);
        return FALSE;
    }
    shiftPressedAlone_ = false;

    if (!serverProfileLoaded_ || server_.consumeConfigChanged()) {
        loadServerProfile();
    }

    // 全体トグルはモディファイア透過フィルタより先に照合する
    // 設定済みの[Ctrl] / [Alt]組み合わせを転送せず、hazkey側で消費するため
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
        // フォーカス済み候補リストは学習データ削除に必要なモディファイア組み合わせを持つ
        // 下のフィルタより先に振り分ける
        handled = candidateKeyEvent(keyval, state);
    } else if (!composingText.empty() && isAltDigitKey(keyval, state)) {
        // フォーカスなしsuggestリストでは、FcitxのpreeditKeyEvent()にある[Alt] + [数字]分岐に従う
        // 遅延リフレッシュを解決してからページ内候補を確定する
        // 数字が候補を指さない場合も、FcitxのfilterAndAccept()と同様にキーを消費する
        selectPageLocalAltDigit(keyval, /*flushFirst=*/true);
        handled = TRUE;
    } else if (!composingText.empty() && isDirectConversionShortcut(keyval, state)) {
        // FcitxのpreeditKeyEvent()既定分岐は、厳密な[Ctrl]組み合わせをctrlShortcutHandler()へ渡す
        // [Ctrl] + [U]、[Ctrl] + [I]、[Ctrl] + [O]、[Ctrl] + [P]、[Ctrl] + [T]は組成をその場で変換する
        // 下のモディファイア透過より先に扱わないと、アプリケーションへ転送される
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
        // 表示専用リフレッシュは連続打鍵を間引く
        // 上のinputChar RPCは同期で順序を保証したまま
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
            // FcitxはFcitxKey_MuhenkanをpreeditKeyEvent()からfunctionKeyHandler()へ渡す
            // functionKeyHandler()に[Muhenkan]分岐はないため、消費されるNOPになる
            // ここも同じ動作に保つ
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
        // 組成中は[Home] / [End]を常に消費し、アプリケーション側ではなく、組成カーソルを動かす
        // 以前はファサードの転送経路に抜け、組成途中でアプリケーション側カーソルが動いた (Fcitx 5では起きない動作)
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

    // 学習データ削除は汎用[Ctrl]透過より先に検査する
    // そうしないと[Ctrl] + [D]がアプリケーションへ転送される
    if (hotkeyMatches(keyval, state, deleteLearningHotkey_)) {
        handleDeleteCandidateLearningData(cursorIndex_);
        return TRUE;
    }

    // フォーカス済みsuggestモード候補だけを受理する
    // [Return]と違い、組成を保ったままサーバから更新する
    if (currentListIsSuggest_ && hotkeyMatches(keyval, state, acceptPredictionHotkey_)) {
        server_.acceptPrediction(cursorIndex_);
        showPreeditCandidateList();
        return TRUE;
    }

    // [Alt] + [1]〜[9]はページ内候補を選択する
    // FcitxのcandidateKeyEvent()にあるisAltDigitKeyEvent()分岐に合わせる
    // 下の[Alt] / [Super]透過ガードより先に検査しないと、アプリケーションへ転送される
    if (isAltDigitKey(keyval, state)) {
        selectPageLocalAltDigit(keyval, /*flushFirst=*/false);
        return TRUE;
    }

    // Fcitxは候補モードで、厳密な[Alt] + [Shift] + [Space] / [Alt] + [Shift] + [Tab]をNOPとして消費する
    // 汎用[Alt] / [Super]透過より先に置き、アプリケーションや候補テーブル操作へ届かないようにする
    if (isAltShiftSpaceOrTab(keyval, state)) {
        return TRUE;
    }

    // ホットキー以外の[Alt] / [Super] / [Meta] / [Hyper]組み合わせはアプリケーション向け
    // FcitxのisInputableEvent()は無修飾の単純キーだけを受理する
    // このガードがないと、[Alt] + [A] / [Super] + [A]がisInputableKey()に抜けて、組成へ入力される
    // [Ctrl]はFcitxの候補移動に合わせ、下のcase別処理に任せる
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
        // FcitxのcandidateKeyEvent()は厳密な[Ctrl]組み合わせをmctrlShortcutHandler()経由で処理する
        // 直接変換ショートカットは消費し、それ以外の[Ctrl]キーはアプリケーションへ転送する
        // [Ctrl] + 他モディファイア (AltGr系Mod3 / Mod5を含む) は、厳密な[Ctrl]組み合わせではない
        // そのままアプリケーションへ転送する
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
        // 保留リフレッシュは取り込みと確定の前に解決する
        // 解決しないと確定テキストと周囲テキストの更新が遅れる
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
        return;  // サーバ未準備、既定値を維持
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
    updateLiveConvertProperty();
    using M = hazkey::config::Profile_AutoConvertMode;
    // サーバ側モードがDISABLEDでないときだけ、記憶中の"ON"モードを更新する
    // DISABLED時 (例: 直前のホットキーで切り替えた直後) は直前の記憶値を保つ
    // これにより、切り替え直したときに正しいモードへ戻せる
    // rememberedOnMode_はconnector上で入力コンテキスト間に共有される
    // アプリケーション間のフォーカス移動をまたいで保持される
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

    // 失敗時もプロパティを再送出する
    // [ライブ変換]チェックボックスを楽観的に反転したパネルを実際の状態へ戻すため
    const auto configOpt = server_.getServerConfig();
    if (!configOpt.has_value() || configOpt->profiles_size() == 0) {
        cachedAutoConvertMode_ = prevMode;
        sharedRemembered = prevRemembered;
        updateLiveConvertProperty();
        return;
    }

    auto config = configOpt.value();
    config.mutable_profiles(0)->set_auto_convert_mode(cachedAutoConvertMode_);
    if (!server_.setServerConfig(config)) {
        cachedAutoConvertMode_ = prevMode;
        sharedRemembered = prevRemembered;
        updateLiveConvertProperty();
        return;
    }
    updateLiveConvertProperty();

    // 切り替え用のフィードバックはZenzaiヒントに合わせる
    // 新モードは切り替えオフ時のDISABLED、切り替えオン時の復帰ONモード
    // 空組成の早期リターンより前に表示し、ホットキーだけの押下でも変化を報告する
    using M = hazkey::config::Profile_AutoConvertMode;
    showTransientHint(
        cachedAutoConvertMode_ ==
                M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED
            ? tr("Live conversion disabled")
            : tr("Live conversion enabled"));

    const std::string composingText = server_.getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, preeditText_);
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
    // IBusには全パネルが描画するfcitx5のshowCustomInputMethodInformation()相当のポップアップがない
    // 永続プロパティに加え、新状態を一時的なauxヒントで表示する
    // (ibus-rimeのstatus_hint方式)
    updateZenzaiProperty(enabled.value());
    showTransientHint(tr(enabled.value() ? "Neural conversion enabled" : "Neural conversion disabled"));
}

void HazkeyState::showTransientHint(const std::string& text) {
    transientHintText_ = text;
    if (hintToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(hintToken_);
    }
    // シリアルワーカー上で遅延させる (GLibタイマは使用しない)
    // HazkeyStateはワーカーが所有するため、自動非表示も同じスレッドで実行する
    // ラムダはshared_from_this()を捕捉し、タスク実行中にstateが破棄されないようにする
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
        // suggestモードリストはlive_textから再構築する (従来と同じ表示)
        // [Tab]フォーカス経路と同様に、先頭候補へ再フォーカスする
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
    // 遅延リフレッシュを解決する
    // 下の変換はpreeditText_を読むため、解決しないと古い値になる
    flushPendingRefresh();
    const std::string converted =
        server_.getComposingText(charTypeFor(mode), preeditText_);
    livePreeditIndex_ = -1;
    preeditText_ = converted;
    if (converted.empty()) {
        hidePreedit();
    } else {
        // FcitxのsetSimplePreeditHighlighted()は、文字列全体をハイライトする
        // 通常の非ハイライトpreeditではカーソルが末尾にあるが、ここでは先頭 (cursorSegment=0) に置く
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
    // fcitx5-hazkey-communityのfcitx::HazkeyState::ctrlShortcutHandler()から移植
    // [Ctrl] + [U]はHiragana、[Ctrl] + [I]はKatakanaFullwidth
    // [Ctrl] + [O]はKatakanaHalfwidth、[Ctrl] + [P]はRawFullwidth
    // [Ctrl] + [T]はRawHalfwidth
    // ここに到達するのは、厳密な[Ctrl]組み合わせのみ (isDirectConversionShortcut()参照)
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
    // functionKeyHandler()による直接変換開始と同じ効果
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
    // 一時停止するのはライブ変換表示のみ
    // 非予測変換は、showNonPredictCandidateList()ですでにカーソルを末尾へ寄せている
    // または、フォーカス済みの文節境界調整でカーソル内在が正当であるため
    if (isSuggest && showPausedPreeditIfCursorInside()) {
        return false;
    }
    return applyCandidateResponse(server_.getCandidates(isSuggest), std::nullopt, isSuggest);
}

void HazkeyState::showPausedRawPreedit(
    const hazkey::frontend::ComposingTextWithCursor& parts) {
    const std::string text = hazkey::frontend::composingTextOf(parts);
    preeditText_ = text;
    // 画面上にlive_textがないため、[Return]は見えない候補ではなく生かなを確定する
    livePreeditIndex_ = -1;
    const glong charLen = g_utf8_strlen(text.c_str(), -1);
    // 末尾モードpreeditは、ライブ変換幅の変動でパネルがばたつかないようカーソルを0に固定する
    // 一時停止preeditは本物のキャレットを持つ
    // 生かなは安定しているため、パネルはばたつかない
    setPreeditUnderline(text, 0, charLen, static_cast<guint>(hazkey::frontend::caretCharOffset(parts)));
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
        // 組成末尾での[Right] / [End]には移動先がない
        // 呼び出し側はキーを消費するが、RPCも再描画も行わない
        return;
    }
    // 保留リフレッシュは下の同期描画で置き換える
    // 取り消し、描画、リスト非表示は全てこの1ワーカー上でこの順に実行する
    cancelPendingRefresh();
    server_.moveCursor(offset);
    // moveCursor()はconnectorキャッシュを無効化するため、この再読込は新しい位置を読む
    // サーバがオフセットをクランプするため、+-1024は安全
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
    // 表示専用リフレッシュは間引く (scheduleCandidateRefresh()参照)
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
    // livePreeditIndex_は、このlive_textがユーザに見えていることを表す
    // レスポンスがindexを持つことを表すわけではない
    // [Return]はその候補を確定するため、実際にlive_textを表示する分岐だけで設定する
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
    // preeditカーソルは組成先頭 (0) に固定し、IBusにそこを基準として扱わせる
    // 組成末尾だとライブ変換幅に追従してパネルがばたつく
    // fcitx5-hazkey-communityも、fcitx-gtkが未設定カーソルを0にクランプするため同じ動作になる
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

/// 候補リフレッシュの間引き
//
// fcitx5-hazkeyのHazkeyState::scheduleCandidateRefresh() / firePendingCandidateRefresh()の写し
// 純粋な立ち上がりエッジと最新優先の立ち下がりデバウンス方針は、hazkey-frontend-common/candidate_refresh_coalescer.hを参照
//
// フロントエンド固有なのはタイマ適合層だけ、Fcitx 5はイベントループ上のEventSourceTimeを使用して、IBusは共有SerialTaskExecutorに遅延タスクを積む
// executorを使うことで間引き状態を全て単一ワーカースレッド上に保つ
// これにより、スレッドをまたぐタイマ寿命の危険 (生の`this`を捕捉するGLibタイムアウトソース) を除く
//
// 間引きはinputCharによる状態変更に続く表示専用リフレッシュだけに適用する
// 対象は3か所の入力可能キー処理で、Fcitx 5と完全に同じ
// 候補移動、ページング、文節境界調整、確定、[BackSpace] / [Delete]、リセットは同期のまま
//
// 以下のメソッドは全て単一ワーカースレッド上で実行するため、ロックは不要
void HazkeyState::scheduleCandidateRefresh(bool isSuggest) {
    pendingRefreshIsSuggest_ = isSuggest;
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());

    // 立ち上がりエッジでは、保留がなく前回リフレッシュから静寂期間が1回分過ぎている
    // 遅延なしで即時実行する
    if (refreshCoalescer_.shouldRunImmediately(
            nowUsec, hazkey::frontend::kCandidateRefreshCoalesceUsec)) {
        // 即時実行後に予約済みの遅延タスクを残してはならない
        // onRun()が保留枠を消費するため、古いタスクは重複になる
        // cancel()は実行済みの後でも安全
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
        // 最新優先では、新規予約の前に直前の遅延タスクを取り消す
        // 新しい要求が期限を保持する
        // バーストは打鍵ごとの発火ではなく、1回の立ち下がり実行に畳み込む
        // 遅延はcoalescer自身の期限から導き、投入遅延で静寂期間を縮めない
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
        // 防御的処理
        // 遅延タスクは早回りしないはずだが、早回りした場合もリフレッシュを落とさない
        // 残り時間で再予約する
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
    // 次の静寂期間は、この変換の開始ではなく完了から測る
    // 変換が遅い場合にも同じ
    // onRunFinished()を参照
    refreshCoalescer_.onRunFinished(static_cast<uint64_t>(g_get_monotonic_time()));
}

void HazkeyState::cancelPendingRefresh() {
    if (refreshToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(refreshToken_);
        refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
    }
    // resetPolicy()を使用、onCancel()は使用しない
    // 新しい組成エポックが前のエポックの実行時刻を引き継いではならない
    // 引き継ぐと初回リフレッシュが静寂期間の全体に渡り遅延する
    refreshCoalescer_.resetPolicy();
}

// 保留の間引きリフレッシュを捨てずに即時実行する
// preeditText_を消費する呼び出し側 ([Return]確定、フォーカスアウト確定、直接変換) が最後に同期リフレッシュした古い値ではなく、最新サーバ状態へ作用するため
//
// これがないと、間引き窓内に遅延した打鍵が確定テキストから抜け落ちる
// 例: [A] [I] [U] [E] [O]の直後に[Return]を押すと、立ち上がりエッジの先頭1文字だけが確定される
void HazkeyState::flushPendingRefresh() {
    if (!refreshCoalescer_.hasPending()) {
        return;
    }
    // 予約タスクを先に取り消し、下のonRun()が枠を保持する
    // 古いタスクが後から実行されるのを防ぐ
    if (refreshToken_ != hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        executor_->cancel(refreshToken_);
        refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;
    }
    const uint64_t nowUsec = static_cast<uint64_t>(g_get_monotonic_time());
    refreshCoalescer_.onRun(nowUsec);
    runPendingCandidateRefresh();
}

void HazkeyState::showNonPredictCandidateList() {
    // 保留中の遅延suggestリフレッシュが後から発火し、非予測リストを上書きしてはならない
    // coalescer自身の保留リフレッシュ実行中は除く
    // その場合は正当に非予測となることがある
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
    // 遅延表示リフレッシュを先に解決し、フォーカス後のリストへ全打鍵を反映する
    flushPendingRefresh();
    if (listVisible_ && cursorIndex_ < 0) {
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    if (!listVisible_) {
        // リフレッシュでsuggestリストが消えた
        // フォーカスキーを飲み込まず、非予測変換へフォールバックする
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
    // Fcitxは、変換対象をハイライト表示する
    // 末尾読みなし候補は文字列全体を対象にする
    // それ以外はc.textだけを対象にし、末尾のsubHiraganaは意図的に素通しにする
    const std::string selection = c.subHiragana.empty() ? preeditText_ : c.text;
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
        // 表示済みだが未フォーカスの場合、fcitxのmoveCursor()は暗黙位置から進めない
        // 先頭候補へフォーカスする
        cursorIndex_ = 0;
        updateCandidateCursor();
        return;
    }
    // round=FALSEのibus_lookup_table_cursor_down()を再現する
    // 最終候補まで進み、次は先頭へ戻る
    cursorIndex_ = advanceCursorIndex(cursorIndex_, static_cast<int>(candidates_.size()));
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
    // round=FALSEのibus_lookup_table_cursor_up()を再現する
    // 先頭候補まで戻り、次は末尾へ戻る
    cursorIndex_ = backCursorIndex(cursorIndex_, static_cast<int>(candidates_.size()));
    updateCandidateCursor();
}

void HazkeyState::nextPage() {
    if (pageSize_ <= 0 || candidates_.empty()) {
        return;
    }
    cursorIndex_ = nextPageStart(cursorIndex_, pageSize_, static_cast<int>(candidates_.size()));
    updateCandidateCursor();
}

void HazkeyState::prevPage() {
    if (pageSize_ <= 0 || candidates_.empty()) {
        return;
    }
    cursorIndex_ = prevPageStart(cursorIndex_, pageSize_);
    updateCandidateCursor();
}

// round=FALSEのibus_lookup_table_page_down() / page_up()を純粋に再現する
// 続けて呼び出し側のpageStartを正規化する
// 元コードではpage_downがfalseなら現在のページ先頭に留まる
// それ以外は、新しいカーソルのページ先頭へ移動する
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
    // Fcitxの[Alt] + [数字]選択を移植する
    // candidateKeyEvent()は振り分け時のリストから選択する (flushなし)
    // preeditKeyEvent()は先に遅延リフレッシュを解決し、古いリストへの選択を防ぐ
    // どちらも数字が指すページ内の候補を選ぶ
    if (flushFirst) {
        flushPendingRefresh();
    }
    if (!listVisible_ || candidates_.empty() || pageSize_ <= 0) {
        return;
    }
    if (keyval < IBUS_KEY_1 || keyval > IBUS_KEY_9) {
        return;
    }
    // フォーカスなしリストはページ0にいる
    // IBusはカーソルを隠しても候補テーブルのカーソルを0に残す
    // fcitxのフォーカスなしリストも、フォーカスまでは先頭ページにいる
    // フォーカス済みリストはHazkeyCandidateList::setCursorIndexと同様に、現在の全体カーソル位置からページを決める
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
    // 候補テーブルは単純なスナップショットからメインループ上だけで構築して送出する
    // ワーカーがIBusLookupTableを所有することはない
    // generationにより、後続のクリックを厳密にこの描画へ対応付けられる
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
    // このリセット後に保留中の間引きリフレッシュを発火させてはならない
    // フォーカスアウト、disable、enableの経路にも当てはまる
    // Fcitx 5のHazkeyState::reset()に合わせて明示的に取り消す
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
    // 遅延表示リフレッシュを先に解決する
    // 解決しないと、フォーカスアウト、disable、確定時に最後に同期リフレッシュした古いpreeditを確定してしまう
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
    // FcitxのHazkeyPreedit::setSimplePreeditHighlighted()を再現する
    // 文字列全体をハイライトして選択範囲にし、preeditカーソルは先頭に置く
    postUi([text](HazkeyUi& ui) { ui.updatePreeditHighlighted(text); });
}

void HazkeyState::setAuxiliaryText(const std::string& text) {
    postUi([text](HazkeyUi& ui) { ui.updateAuxiliaryTextPlain(text); });
}

void HazkeyState::setAuxiliaryTextWithCursor(const std::string& auxUp,
                                             glong underlineStart,
                                             glong underlineEnd,
                                             const std::string& auxDown) {
    // 生ひらがなAuxUpは、サーバカーソル下の文字に下線を引く
    // fcitxのonCursorに付けるUnderline TextFormatFlagに対応する
    // (fcitxアダプタのcomposingTextWithCursorToFcitxText()参照)
    //
    // オフセットはUTF-8文字オフセット
    // AuxUpは結合テキストの接頭辞であるため、ずらす必要はない
    postUi([auxUp, underlineStart, underlineEnd, auxDown](HazkeyUi& ui) {
        ui.updateAuxiliaryTextWithCursor(auxUp, underlineStart, underlineEnd,
                                         auxDown);
    });
}

void HazkeyState::updateAuxiliaryText() {
    // fcitx5のkeyEvent()末尾を再現する
    // AuxUpは候補リストのフォーカス中に"[n/total]"を表示する
    // それ以外は、組成があればサーバカーソル付きの生ひらがなを表示する
    // (fcitxのsetCandidateCursorAUX / setHiraganaAUX)
    //
    // AuxDownは直接入力モードで"[Direct Input]"を表示する
    // 学習データ付きのフォーカス候補では"Deletable"を表示する
    // 組成中は"[Press Tab to Select]"を表示する (fcitxのsetAuxDownText)
    // 直接入力がヒントより優先するのは、fcitxのsetAuxDownText()が先に判定するとおり
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

    // 一時的な切り替えヒントは、Zenzaiまたはライブ変換の切り替えに由来する
    // IBusには他に一時的フィードバックの経路がない (showTransientHint()参照)
    // AuxDownへ重ねることで既存のaux描画経路を再利用する
    // アイドル時の切り替えのように、preeditも直接入力もない場合にもaux枠を表示できる
    // 最新イベントであるため先頭に置く
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
        // この読込はtransportがキャッシュする
        // auxTextModeはサーバ側ではなくここで適用する (cachedAuxTextMode_参照)
        // 生ひらがなを隠す設定では、joinAuxiliaryText()が先行空白なしのAuxDown単体になる
        const auto parts = server_.getComposingHiraganaWithCursor();
        if (!hazkey::frontend::shouldShowAuxText(
                cachedAuxTextMode_, hazkey::frontend::cursorAtEnd(parts))) {
            setAuxiliaryTextWithCursor("", -1, -1, auxDown);
            return;
        }
        const glong beforeChars = g_utf8_strlen(parts.before.c_str(), -1);
        const glong onCursorChars = g_utf8_strlen(parts.onCursor.c_str(), -1);
        setAuxiliaryTextWithCursor(parts.toString(), beforeChars, beforeChars + onCursorChars, auxDown);
        return;
    }
    // 組成中でも直接入力でもない場合は、Fcitxに合わせてAuxUp / AuxDownの両方を消す
    setAuxiliaryText(joinAuxiliaryText("", auxDown));
}

void HazkeyState::registerProperties() {
    // プロパティ (再) 登録の前にサーバプロファイルを読み込む
    // Zenzaiプロパティが保存済み設定を即反映するため
    // 遅延読込は、最初の非リリースキーイベント時まで走らないため、それまでプロパティが古いままになる
    if (!serverProfileLoaded_) {
        loadServerProfile();
    }
    const bool direct = server_.currentInputModeIsDirect();
    const bool zenzai = cachedZenzaiEnabled_;
    const bool liveConvert =
        cachedAutoConvertMode_ !=
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED;
    postUi([direct, zenzai, liveConvert](HazkeyUi& ui) {
        ui.registerProperties(direct, zenzai, liveConvert);
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

void HazkeyState::updateLiveConvertProperty() {
    const bool enabled =
        cachedAutoConvertMode_ !=
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED;
    postUi([enabled](HazkeyUi& ui) { ui.updateLiveConvertProperty(enabled); });
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
        // サーバ側の[Shift]単体タップRPC経路を使用する
        // 直接入力モード遷移とキャッシュ無効化はサーバが握り、フロントエンド単独の状態を持たない
        // 先に、shiftPressedAlone_を落とす
        // [Shift]キー押下中なら、その後のリリースは2度目の単体RELEASEではなく、CANCELを送らねばならず、
        // そうしないと合成タップとリリースで2回トグルする
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
    if (g_strcmp0(propName, "LiveConvert") == 0) {
        // ライブ変換ホットキーと同じ経路:
        // 直前ONモードを記憶して、新モードをサーバへ永続化する
        // 古いプロファイルは先に読み直し (keyEvent同様)、現モード起点でトグルする
        if (!serverProfileLoaded_ || server_.consumeConfigChanged()) {
            loadServerProfile();
        }
        handleLiveConvertToggle();
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
    // クリックはユーザが実際に見た描画に対してメインループ上で解決済み
    // generation不一致はクリック下でリストが変わった意味のため、古い候補へ適用せず捨てる
    if (static_cast<uint64_t>(generation) != lookupGeneration_) {
        return;
    }

    // 未処理の表示リフレッシュが残る前に描画したリストへのクリックは、古い候補を確定して末尾入力を落とす
    // 保留リフレッシュを解決してこの古いクリックは捨て、更新後リストを出して再度クリックしてもらう
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

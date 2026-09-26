/**
 * @file hazkey_frontend.cpp
 * @brief IBus入力コンテキストごとのメインループ側ファサードの実装
 *
 * 公開APIの仕様はヘッダ (hazkey_frontend.h) を参照のこと
 * 同期消費判定とワーカーへの投入、投機状態の整合を実装する
 */
#include "hazkey_frontend.h"
#include <string>
#include <utility>
#include "hazkey_frontend_hooks.h"

/** @brief IBusフロントエンドの名前空間 */
namespace hazkey::ibus {

namespace {

/**
 * @brief プロセス共通のSerialTaskExecutorを返す
 *
 * IBusプロセスごとに実行器を1つ持ち、全HazkeyStateが単一のHazkeyServerConnector単体を共有するため、
 * 全状態の処理を1スレッドに直列化して搬送を単一スレッド化し、RPCを厳密なFIFOにする
 * 意図的なリーク: 実行器のワーカーが参照するHazkeyStateの破棄はエンジン駆動であり、
 *               プロセス終了時のstatic破棄順序を制御できない
 *               終了時のスレッド1つのリークは無害である
 *
 * @return プロセス共通の実行器への参照
 * @internal 翻訳単位内の実装詳細
 */
hazkey::frontend::SerialTaskExecutor& sharedExecutor() {
    static hazkey::frontend::SerialTaskExecutor* executor =
        new hazkey::frontend::SerialTaskExecutor();
    return *executor;
}

/**
 * @brief アプリ側へ素通しさせる修飾子マスク
 *
 * Control / Mod1 / Super / Hyper / Meta / Mod4 のいずれかが含まれる
 *
 * @internal 翻訳単位内の実装詳細
 */
constexpr guint kModifierPassthroughMask =
    IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK |
    IBUS_META_MASK | IBUS_MOD4_MASK;

/**
 * @brief 組成中にIMEが処理するキーかを判定する
 *
 * HazkeyState::preeditKeyEventを写した判定である
 *
 * @param keyval 判定対象のキー値
 * @return IMEが処理する場合はtrue
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
bool isPreeditHandledKey(guint keyval) {
    switch (keyval) {
        case IBUS_KEY_Return:
        case IBUS_KEY_KP_Enter:
        case IBUS_KEY_ISO_Enter:
        case IBUS_KEY_BackSpace:
        case IBUS_KEY_Delete:
        case IBUS_KEY_F6:
        case IBUS_KEY_F7:
        case IBUS_KEY_F8:
        case IBUS_KEY_F9:
        case IBUS_KEY_F10:
        case IBUS_KEY_Muhenkan:
        case IBUS_KEY_Escape:
        case IBUS_KEY_space:
        case IBUS_KEY_Henkan:
        case IBUS_KEY_Up:
        case IBUS_KEY_Down:
        case IBUS_KEY_Tab:
        case IBUS_KEY_ISO_Left_Tab:
        case IBUS_KEY_Left:
        case IBUS_KEY_Right:
        // 組成中は、[Home] / [End]キーが組成カーソルを移動させるため、ここでも消費する必要がある
        // 組成がなければアイドル分岐へ抜けてアプリケーション側に残る
        case IBUS_KEY_Home:
        case IBUS_KEY_KP_Home:
        case IBUS_KEY_End:
        case IBUS_KEY_KP_End:
            return true;
        default:
            return false;
    }
}

/**
 * @brief 候補表示中にIMEが処理するキーかを判定する
 *
 * 数字・入力可能キーへのフォールバックより前のHazkeyState::candidateKeyEventを写した判定である
 *
 * @param keyval 判定対象のキー値
 * @return IMEが処理する場合はtrue
 * @internal 匿名名前空間内の実装専用ヘルパ
 */
bool isCandidateHandledKey(guint keyval) {
    switch (keyval) {
        case IBUS_KEY_Right:
        case IBUS_KEY_Left:
        case IBUS_KEY_Return:
        case IBUS_KEY_KP_Enter:
        case IBUS_KEY_ISO_Enter:
        case IBUS_KEY_Escape:
        case IBUS_KEY_BackSpace:
        case IBUS_KEY_space:
        case IBUS_KEY_Tab:
        case IBUS_KEY_ISO_Left_Tab:
        case IBUS_KEY_Down:
        case IBUS_KEY_Up:
        case IBUS_KEY_F6:
        case IBUS_KEY_F7:
        case IBUS_KEY_F8:
        case IBUS_KEY_F9:
        case IBUS_KEY_F10:
            return true;
        default:
            return false;
    }
}

}  // namespace

HazkeyFrontend::HazkeyFrontend(IBusEngine* engine)
    : ui_(std::make_shared<HazkeyUi>(engine)),
      state_(std::make_shared<HazkeyState>(ui_, &sharedExecutor())) {
    // 取込用ホットキーへstateと同じ既定値を入れておき、最初のキーイベントから組込ホットキーを認識できるようにする
    liveConvert_ = HazkeyState::parseHotkey("", "Control+Shift+L");
    zenzaiToggle_ = HazkeyState::parseHotkey("", "Control+Alt+Z");
    acceptPrediction_ = HazkeyState::parseHotkey("", "F5");
    deleteLearning_ = HazkeyState::parseHotkey("", "Control+D");
}

HazkeyFrontend::~HazkeyFrontend() = default;

void HazkeyFrontend::retire() {
    if (retired_) {
        return;
    }
    // まず新規受付を止め (全vfuncがretired_を見る)、
    // 投入済みワーカータスクが終了して投稿済みUI命令 (特にフォーカスアウト時の確定) をエンジンと描画器が有効なうちに実行できるよう、区切られた機会を与える
    // 排出待ちは投入済みタスクのみを待ち、下の区切られた反復は既に準備済みのソースだけを配送する
    retired_ = true;
    forwardedPressKeyvals_.clear();
    constexpr auto kRetireDrainTimeout = std::chrono::milliseconds(200);
    sharedExecutor().submit(
        [state = state_] { state->cancelPendingRefresh(); });
    sharedExecutor().drainAndWaitFor(kRetireDrainTimeout);
    for (int i = 0; i < 1000 && g_main_context_pending(nullptr); ++i) {
        g_main_context_iteration(nullptr, FALSE);
    }
    if (ui_) {
        ui_->retire();
    }
}

void HazkeyFrontend::enqueue(
    std::function<void(const std::shared_ptr<HazkeyState>&)> task) {
    auto self = shared_from_this();
    auto state = state_;
    ++pendingOps_;
    const hazkey::frontend::SerialTaskExecutor::Token token =
        sharedExecutor().submit([self, state, task = std::move(task)]() mutable {
            task(state);
            const auto snapshot = state->ingressSnapshot();
            hazkey::frontend::postToMainLoop([self, snapshot] {
                self->applyIngress(snapshot);
                if (self->pendingOps_ > 0) {
                    --self->pendingOps_;
                }
            });
        });
    if (token == hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        // 実行器がタスクを拒否した (停止中): 帳尻を戻し、pendingOps_が0より上で固まらないようにする
        if (pendingOps_ > 0) {
            --pendingOps_;
        }
    }
}

void HazkeyFrontend::enqueueKeyOp(guint keyval, guint keycode, guint state, gboolean consume) {
    auto self = shared_from_this();
    auto logic = state_;
    auto ui = ui_;
    ++pendingOps_;
    const hazkey::frontend::SerialTaskExecutor::Token token =
        sharedExecutor().submit(
            [self, logic, ui, keyval, keycode, state, consume] {
                const gboolean handled =
                    logic->processKeyEvent(keyval, keycode, state);
                const auto snapshot = logic->ingressSnapshot();
                hazkey::frontend::postToMainLoop(
                    [self, ui, snapshot, handled, consume, keyval, keycode,
                     state] {
                        self->applyIngress(snapshot);
                        if (self->pendingOps_ > 0) {
                            --self->pendingOps_;
                        }
                        // ワーカーが処理しなかった投機的消費はFIFO順で転送し、キーを欠落させず、解放が対応する押下を追い越さないようにする
                        //
                        // 解放は対応する押下も転送済みの場合にのみ転送する:
                        // ワーカーは解放を処理せず、解放フラグを見られないクライアントは幻のキー押下を受け取ってしまう
                        if (consume && !handled && !self->retired_ &&
                            shouldForwardUnhandledKey(
                                (state & IBUS_RELEASE_MASK) != 0, keyval,
                                self->forwardedPressKeyvals_)) {
                            ui->forwardKeyEvent(keyval, keycode, state);
                        }
                    });
            });
    if (token == hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        if (pendingOps_ > 0) {
            --pendingOps_;
        }
    }
}

void HazkeyFrontend::applyIngress(
    const HazkeyState::IngressSnapshot& snapshot) {
    if (retired_) {
        return;
    }
    specComposing_ = snapshot.composing;
    specListFocused_ = snapshot.listFocused;
    profileLoaded_ = snapshot.profileLoaded;
    liveConvert_ = snapshot.liveConvert;
    zenzaiToggle_ = snapshot.zenzaiToggle;
    acceptPrediction_ = snapshot.acceptPrediction;
    deleteLearning_ = snapshot.deleteLearning;
}

gboolean HazkeyFrontend::decideConsumeKey(guint keyval, guint state,
                                          const DecisionInput& in) {
    // 解放イベントとShiftキー自体はIMEで消費しない (ワーカーがShift状態を扱うが、キーは取り込まない)。
    if ((state & IBUS_RELEASE_MASK) != 0) {
        return FALSE;
    }
    if (keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R) {
        return FALSE;
    }

    // 全体ホットキーは他より先に照合する
    // HazkeyState::processKeyEvent()と全く同じである
    if (HazkeyState::hotkeyMatches(keyval, state, in.liveConvert) ||
        HazkeyState::hotkeyMatches(keyval, state, in.zenzaiToggle)) {
        return TRUE;
    }

    const bool hasModifierPassthrough =
        (state & kModifierPassthroughMask) != 0;
    // サーバプロファイル読込前は設定済みホットキーが不明なため、修飾子組合せは全て投機的に消費する (ワーカーが処理しなければ後で転送する)
    // ここでFALSEを返すと、設定済みのhazkeyホットキーにアプリが反応してしまう
    if (!in.profileLoaded && hasModifierPassthrough) {
        return TRUE;
    }

    if (in.listFocused) {
        if (HazkeyState::hotkeyMatches(keyval, state, in.acceptPrediction) ||
            HazkeyState::hotkeyMatches(keyval, state, in.deleteLearning)) {
            return TRUE;
        }
        if (HazkeyState::isAltDigitKey(keyval, state) ||
            HazkeyState::isAltShiftSpaceOrTab(keyval, state)) {
            return TRUE;
        }
        // ホットキーでないAlt/Super/Meta/Hyper組合せはアプリ側のものである。
        if ((state & (IBUS_MOD1_MASK | IBUS_SUPER_MASK | IBUS_MOD4_MASK |
                      IBUS_META_MASK | IBUS_HYPER_MASK)) != 0) {
            return FALSE;
        }
        // ワーカーのcandidateKeyEventはControl分岐より先にこれらのキーを処理するため、
        // [Ctrl] + [Enter] / [Ctrl] + [BackSpace] / [Ctrl] + [F6]等は処理され、[Ctrl] + [文字]キーは処理されない
        // ここでも同じ順序を保つ
        if (isCandidateHandledKey(keyval)) {
            return TRUE;
        }
        // 厳密な[Ctrl]組合せは直接変換ショートカットだけを消費し、他の[Ctrl]キーは全て転送する
        if ((state & IBUS_CONTROL_MASK) != 0) {
            return HazkeyState::isDirectConversionShortcut(keyval, state) ? TRUE
                                                                          : FALSE;
        }
        if (keyval >= IBUS_KEY_0 && keyval <= IBUS_KEY_9) {
            return TRUE;
        }
        return HazkeyState::isInputableKey(keyval) ? TRUE : FALSE;
    }

    if (in.composing) {
        if (HazkeyState::isAltDigitKey(keyval, state) ||
            HazkeyState::isDirectConversionShortcut(keyval, state)) {
            return TRUE;
        }
        if (hasModifierPassthrough) {
            return FALSE;
        }
        if (isPreeditHandledKey(keyval)) {
            return TRUE;
        }
        return HazkeyState::isInputableKey(keyval) ? TRUE : FALSE;
    }

    // アイドル時: Spaceと印字可能キー (および上で処理済みの修飾子組合せ) だけがIMEのキーであり、それ以外は全てアプリケーション側のものである
    if (hasModifierPassthrough) {
        return FALSE;
    }
    if (keyval == IBUS_KEY_space) {
        return TRUE;
    }
    return HazkeyState::isInputableKey(keyval) ? TRUE : FALSE;
}

bool HazkeyFrontend::shouldForwardUnhandledKey(
    bool isRelease, guint keyval,
    std::unordered_set<guint>& pendingPressKeyvals) {
    if (!isRelease) {
        // 押下を記憶し、対応する解放と対にできるようにする。
        pendingPressKeyvals.insert(keyval);
        return true;
    }
    // 解放は、対応する押下も転送済みの場合にのみアプリ側にとって意味を持つ
    //
    // それ以外の解放は全て捨てる:
    // ワーカーは解放を処理しないため、無闇に転送するとIMEが消費したキーに対する幻のキー押下を届けてしまう
    return pendingPressKeyvals.erase(keyval) > 0;
}

gboolean HazkeyFrontend::processKeyEvent(guint keyval, guint keycode,
                                         guint state) {
    if (retired_) {
        return FALSE;
    }
    const bool isRelease = (state & IBUS_RELEASE_MASK) != 0;
    const bool shiftKey = keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R;

    // 未処理操作の残存中やサーバプロファイル (ひいては設定済みホットキー) 未読込中は、
    // 同期判定がワーカーの処理集合の上位集合である保証がないため (未修飾の独自ホットキーや、待機中キーがこれから焦点を当てる候補等)、
    // その間は全イベント (後から転送される押下が対応する解放を追い越さないよう、解放も含む) を投機的に消費する
    // enqueueKeyOp()がワーカーの未処理分を順序どおりに転送する
    const bool barrier = pendingOps_ > 0 || !profileLoaded_;
    if (barrier) {
        enqueueKeyOp(keyval, keycode, state, TRUE);
        return TRUE;
    }

    if (isRelease || shiftKey) {
        enqueue([keyval, keycode, state](const std::shared_ptr<HazkeyState>& s) {
            s->processKeyEvent(keyval, keycode, state);
        });
        return FALSE;
    }

    // 入力可能キーは組成を開くと楽観的にみなす
    // 直後の[Return] / [Esc] / [矢印]キーもIME所有として認識し続ける
    // applyIngress()と転送フォールバックで修正される
    if (HazkeyState::isInputableKey(keyval)) {
        specComposing_ = true;
    }

    DecisionInput in;
    in.composing = specComposing_;
    in.listFocused = specListFocused_;
    in.profileLoaded = profileLoaded_;
    in.liveConvert = liveConvert_;
    in.zenzaiToggle = zenzaiToggle_;
    in.acceptPrediction = acceptPrediction_;
    in.deleteLearning = deleteLearning_;
    const gboolean consume = decideConsumeKey(keyval, state, in);
    enqueueKeyOp(keyval, keycode, state, consume);
    return consume;
}

void HazkeyFrontend::focusIn() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->focusIn(); });
}

void HazkeyFrontend::focusOut() {
    if (retired_) return;
    specComposing_ = false;
    specListFocused_ = false;
    forwardedPressKeyvals_.clear();
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->focusOut(); });
}

void HazkeyFrontend::reset() {
    if (retired_) return;
    specComposing_ = false;
    specListFocused_ = false;
    forwardedPressKeyvals_.clear();
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->reset(); });
}

void HazkeyFrontend::enable() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->enable(); });
}

void HazkeyFrontend::disable() {
    if (retired_) return;
    specComposing_ = false;
    specListFocused_ = false;
    forwardedPressKeyvals_.clear();
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->disable(); });
}

void HazkeyFrontend::setCapabilities(guint caps) {
    if (retired_) return;
    enqueue([caps](const std::shared_ptr<HazkeyState>& s) {
        s->setCapabilities(caps);
    });
}

bool HazkeyFrontend::activateProperty(const gchar* propName,
                                      guint propState) {
    if (retired_ || propName == nullptr) {
        return false;
    }
    if (g_strcmp0(propName, "InputMode") == 0) {
        // static領域: ワーカー跨ぎの捕獲でも安全である。
        enqueue([](const std::shared_ptr<HazkeyState>& s) {
            s->activateProperty("InputMode", 0);
        });
        return true;
    }
    if (g_strcmp0(propName, "Zenzai") == 0) {
        enqueue([](const std::shared_ptr<HazkeyState>& s) {
            s->activateProperty("Zenzai", 0);
        });
        return true;
    }
    if (g_strcmp0(propName, "LiveConvert") == 0) {
        enqueue([](const std::shared_ptr<HazkeyState>& s) {
            s->activateProperty("LiveConvert", 0);
        });
        return true;
    }
    (void)propState;
    return false;
}

void HazkeyFrontend::setCursorLocation(gint x, gint y, gint w, gint h) {
    if (retired_) return;
    enqueue([x, y, w, h](const std::shared_ptr<HazkeyState>& s) {
        s->setCursorLocation(x, y, w, h);
    });
}

void HazkeyFrontend::setSurroundingText(IBusText* text, guint cursorIndex,
                                        guint anchorPos) {
    if (retired_) return;
    // メインループ上でプレーンな文字列へ複写する
    // IBusTextは保持しない
    const std::string surrounding =
        (text != nullptr && ibus_text_get_text(text) != nullptr)
            ? ibus_text_get_text(text)
            : "";
    enqueue([surrounding, cursorIndex, anchorPos](
                const std::shared_ptr<HazkeyState>& s) {
        s->setSurroundingText(surrounding, cursorIndex, anchorPos);
    });
}

void HazkeyFrontend::pageUp() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->pageUp(); });
}

void HazkeyFrontend::pageDown() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->pageDown(); });
}

void HazkeyFrontend::cursorUp() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->cursorUp(); });
}

void HazkeyFrontend::cursorDown() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->cursorDown(); });
}

void HazkeyFrontend::candidateClicked(guint index, guint button, guint state) {    (void)button;
    (void)state;
    if (retired_) return;
    // ページ内番号は、ユーザーが見た描画そのもののスナップショットに対して解決する
    // そのスナップショットが在るメインループ上で行う
    const HazkeyUi::LookupSnapshot snapshot = ui_->lookupSnapshot();
    if (!snapshot.visible || snapshot.pageSize <= 0) {
        return;
    }
    const int global = HazkeyState::pageLocalToGlobalIndex(
        snapshot.pageSize, snapshot.total,
        snapshot.cursorPos >= 0 ? snapshot.cursorPos : 0,
        static_cast<int>(index));
    if (global < 0) {
        return;
    }
    const int generation = snapshot.generation;
    enqueue([global, generation](const std::shared_ptr<HazkeyState>& s) {
        s->candidateClickedGlobal(global, generation);
    });
}

void shutdownSharedExecutor() { sharedExecutor().shutdown(); }

}  // namespace hazkey::ibus

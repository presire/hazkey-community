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

/**
 * @brief 周辺テキスト待ちの期限タイマへ渡すデータ
 *
 * @internal 翻訳単位内の実装詳細
 */
struct SurroundingGateTimeout {
    std::weak_ptr<HazkeyFrontend> frontend;  ///< 破棄済みのファサードには触れない
    uint64_t generation = 0;                 ///< タイマ登録時の待機世代
};

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

bool HazkeyFrontend::isSecureInputContentType(guint purpose, guint hints) {
#if IBUS_CHECK_VERSION(1, 5, 4)
    if (purpose == IBUS_INPUT_PURPOSE_PASSWORD ||
        purpose == IBUS_INPUT_PURPOSE_PIN) {
        return true;
    }
#else
    (void)purpose;
#endif
#if IBUS_CHECK_VERSION(1, 5, 26)
    return (hints & IBUS_INPUT_HINT_PRIVATE) != 0;
#else
    (void)hints;
    return false;
#endif
}

void HazkeyFrontend::retire() {
    if (retired_) {
        return;
    }
    // まず新規受付を止め (全vfuncがretired_を見る)、
    // 投入済みワーカータスクが終了して投稿済みUI命令 (特にフォーカスアウト時の確定) をエンジンと描画器が有効なうちに実行できるよう、区切られた機会を与える
    // 排出待ちは投入済みタスクのみを待ち、下の区切られた反復は既に準備済みのソースだけを配送する
    retired_ = true;
    forwardedPressKeyvals_.clear();
    gate_.clear();
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

void HazkeyFrontend::enqueueKeyOp(guint keyval, guint keycode, guint state,
                                  gboolean consume, bool gateCheck) {
    auto self = shared_from_this();
    auto logic = state_;
    auto ui = ui_;
    uint64_t generation = gate_.generation();
    const uint64_t contentEpoch = contentEpoch_;
    if (gateCheck) {
        generation = gate_.beginCheck();
        gatedKeyval_ = keyval;
        gatedState_ = state;
    }
    ++pendingOps_;
    const hazkey::frontend::SerialTaskExecutor::Token token =
        sharedExecutor().submit(
            [self, logic, ui, keyval, keycode, state, consume, gateCheck,
             generation, contentEpoch] {
                bool gated = false;
                const gboolean handled = logic->processKeyEvent(
                    keyval, keycode, state, gateCheck ? &gated : nullptr);
                const auto snapshot = logic->ingressSnapshot();
                hazkey::frontend::postToMainLoop(
                    [self, ui, snapshot, handled, consume, keyval, keycode,
                     state, gateCheck, gated, generation, contentEpoch] {
                        self->applyIngress(snapshot);
                        if (self->pendingOps_ > 0) {
                            --self->pendingOps_;
                        }
                        // ワーカーが処理しなかった投機的消費はFIFO順で転送し、キーを欠落させず、解放が対応する押下を追い越さないようにする
                        //
                        // 解放は対応する押下も転送済みの場合にのみ転送する:
                        // ワーカーは解放を処理せず、解放フラグを見られないクライアントは幻のキー押下を受け取ってしまう
                        if (consume && !handled && !self->retired_ &&
                            contentEpoch == self->contentEpoch_ &&
                            shouldForwardUnhandledKey(
                                (state & IBUS_RELEASE_MASK) != 0, keyval,
                                self->forwardedPressKeyvals_)) {
                            ui->forwardKeyEvent(keyval, keycode, state);
                        }
                        if (gateCheck) {
                            self->onSurroundingGateChecked(generation, gated);
                        }
                    });
            });
    if (token == hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        if (pendingOps_ > 0) {
            --pendingOps_;
        }
        if (gateCheck) {
            gate_.cancelCheck();
        }
    }
}

void HazkeyFrontend::onSurroundingGateChecked(uint64_t generation, bool gated) {
    if (retired_) {
        return;
    }
    switch (gate_.onChecked(generation, gated)) {
        case SurroundingGateMachine::CheckAction::Ignore:
            return;
        case SurroundingGateMachine::CheckAction::Release:
            gate_.flush();
            return;
        case SurroundingGateMachine::CheckAction::Resolve:
            resolveSurroundingGate(true);
            return;
        case SurroundingGateMachine::CheckAction::Wait:
            break;
    }
    // enable時の取得要求に応答が無い場合があるため、待機の開始時に取り直す
    ui_->requestSurroundingText();
    g_timeout_add_full(
        G_PRIORITY_DEFAULT, kSurroundingGateTimeoutMs,
        &HazkeyFrontend::onSurroundingGateTimeout,
        new SurroundingGateTimeout{weak_from_this(), gate_.generation()},
        [](gpointer data) { delete static_cast<SurroundingGateTimeout*>(data); });
}

gboolean HazkeyFrontend::onSurroundingGateTimeout(gpointer data) {
    const auto* timeout = static_cast<const SurroundingGateTimeout*>(data);
    if (const auto self = timeout->frontend.lock()) {
        if (!self->retired_ && self->gate_.timeoutApplies(timeout->generation)) {
            self->resolveSurroundingGate(false);
        }
    }
    return G_SOURCE_REMOVE;
}

void HazkeyFrontend::resolveSurroundingGate(bool surroundingArrived) {
    gate_.resolve();
    // 再開する最初の入力は必ず組成を開くため、保持していた後続キーを組成中として扱う
    specComposing_ = true;
    const guint keyval = gatedKeyval_;
    const guint state = gatedState_;
    enqueue([keyval, state, surroundingArrived](
                const std::shared_ptr<HazkeyState>& s) {
        s->resumeGatedInput(keyval, state, surroundingArrived);
    });
    gate_.flush();
}

void HazkeyFrontend::abortSurroundingGate() { gate_.abort(); }

uint64_t HazkeyFrontend::SurroundingGateMachine::beginCheck() {
    phase_ = Phase::Checking;
    arrivedWhileChecking_ = false;
    return ++generation_;
}

void HazkeyFrontend::SurroundingGateMachine::cancelCheck() {
    if (phase_ != Phase::Checking) {
        return;
    }
    phase_ = Phase::Idle;
    ++generation_;
    flush();
}

HazkeyFrontend::SurroundingGateMachine::CheckAction
HazkeyFrontend::SurroundingGateMachine::onChecked(uint64_t generation,
                                                  bool gated) {
    if (phase_ != Phase::Checking || generation != generation_) {
        return CheckAction::Ignore;
    }
    if (!gated) {
        phase_ = Phase::Idle;
        return CheckAction::Release;
    }
    if (arrivedWhileChecking_) {
        return CheckAction::Resolve;
    }
    phase_ = Phase::Waiting;
    return CheckAction::Wait;
}

bool HazkeyFrontend::SurroundingGateMachine::onSurroundingArrived() {
    if (phase_ == Phase::Checking) {
        arrivedWhileChecking_ = true;
        return false;
    }
    return phase_ == Phase::Waiting;
}

bool HazkeyFrontend::SurroundingGateMachine::timeoutApplies(
    uint64_t generation) const {
    return phase_ == Phase::Waiting && generation == generation_;
}

void HazkeyFrontend::SurroundingGateMachine::submitOrHold(
    bool isKey, std::function<void()> run) {
    if (active()) {
        held_.push_back(HeldOp{isKey, std::move(run)});
        return;
    }
    run();
}

void HazkeyFrontend::SurroundingGateMachine::resolve() {
    phase_ = Phase::Idle;
    ++generation_;
}

void HazkeyFrontend::SurroundingGateMachine::flush() {
    while (!active() && !held_.empty()) {
        HeldOp op = std::move(held_.front());
        held_.pop_front();
        op.run();
    }
}

void HazkeyFrontend::SurroundingGateMachine::abort() {
    if (!active()) {
        return;
    }
    phase_ = Phase::Idle;
    ++generation_;
    std::deque<HeldOp> held;
    held.swap(held_);
    for (auto& op : held) {
        if (!op.isKey) {
            op.run();
        }
    }
}

void HazkeyFrontend::SurroundingGateMachine::clear() {
    phase_ = Phase::Idle;
    ++generation_;
    held_.clear();
}

bool HazkeyFrontend::isSurroundingGateCandidate(guint keyval, guint state,
                                                bool composing, bool listFocused,
                                                bool profileLoaded,
                                                bool gateHint) {
    return (state & IBUS_RELEASE_MASK) == 0 && keyval != IBUS_KEY_Shift_L &&
           keyval != IBUS_KEY_Shift_R && keyval != IBUS_KEY_space &&
           (state & kModifierPassthroughMask) == 0 &&
           HazkeyState::isInputableKey(keyval) && !composing && !listFocused &&
           (!profileLoaded || gateHint);
}

void HazkeyFrontend::applyIngress(
    const HazkeyState::IngressSnapshot& snapshot) {
    if (retired_) {
        return;
    }
    specComposing_ = snapshot.composing;
    specListFocused_ = snapshot.listFocused;
    profileLoaded_ = snapshot.profileLoaded;
    surroundingGateHint_ = snapshot.surroundingGate;
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
    if (retired_ || secureInput_) {
        return FALSE;
    }
    // 周辺テキスト待ちの間は、解放と素通しを含む全キーを投機的に消費して保持し、待機の解決後に到着順で投入する
    if (gate_.active()) {
        gate_.submitOrHold(true, [this, keyval, keycode, state] {
            enqueueKeyOp(keyval, keycode, state, TRUE);
        });
        return TRUE;
    }
    const bool isRelease = (state & IBUS_RELEASE_MASK) != 0;
    const bool shiftKey = keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R;
    const bool gateCandidate = isSurroundingGateCandidate(
        keyval, state, specComposing_, specListFocused_, profileLoaded_,
        surroundingGateHint_);

    // 未処理操作の残存中やサーバプロファイル (ひいては設定済みホットキー) 未読込中は、
    // 同期判定がワーカーの処理集合の上位集合である保証がないため (未修飾の独自ホットキーや、待機中キーがこれから焦点を当てる候補等)、
    // その間は全イベント (後から転送される押下が対応する解放を追い越さないよう、解放も含む) を投機的に消費する
    // enqueueKeyOp()がワーカーの未処理分を順序どおりに転送する
    const bool barrier = pendingOps_ > 0 || !profileLoaded_;
    if (barrier) {
        enqueueKeyOp(keyval, keycode, state, TRUE, gateCandidate);
        return TRUE;
    }

    if (isRelease || shiftKey) {
        // FALSEを返したキーはフレームワークがアプリへ転送する
        // 押下を記録して、後続の解放がバリア中に消費されてもenqueueKeyOp()が転送して対にする
        // (設定変更を観測した[Shift]押下の直後は、解放がバリアに入る)
        if (isRelease) {
            forwardedPressKeyvals_.erase(keyval);
        } else {
            forwardedPressKeyvals_.insert(keyval);
        }
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
    if (!consume) {
        // 押下の処理が終わる前に解放が来るとバリアに入るため、フレームワーク転送した押下も記録する
        forwardedPressKeyvals_.insert(keyval);
    }
    enqueueKeyOp(keyval, keycode, state, consume, gateCandidate && consume);
    return consume;
}

void HazkeyFrontend::focusIn() {
    if (retired_) return;
    // ワーカーのfocusIn()がプロファイルを破棄するため、その要約が届く前のキーも未読込として扱う
    profileLoaded_ = false;
    gate_.submitOrHold(false, [this] {
        enqueue([](const std::shared_ptr<HazkeyState>& s) { s->focusIn(); });
    });
}

void HazkeyFrontend::focusOut() {
    if (retired_) return;
    abortSurroundingGate();
    // secureInput_は保持する: ibus-daemonは同じ値のContentTypeを再送しないため、
    // 同じパスワード欄へ戻ったときに保護が外れないようにする
    specComposing_ = false;
    specListFocused_ = false;
    forwardedPressKeyvals_.clear();
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->focusOut(); });
}

void HazkeyFrontend::reset() {
    if (retired_) return;
    abortSurroundingGate();
    specComposing_ = false;
    specListFocused_ = false;
    forwardedPressKeyvals_.clear();
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->reset(); });
}

void HazkeyFrontend::enable() {
    if (retired_) return;
    const bool secure = secureInput_;
    gate_.submitOrHold(false, [this, secure] {
        enqueue([secure](const std::shared_ptr<HazkeyState>& s) {
            s->setSecureInput(secure);
            s->enable();
        });
    });
}

void HazkeyFrontend::disable() {
    if (retired_) return;
    abortSurroundingGate();
    specComposing_ = false;
    specListFocused_ = false;
    forwardedPressKeyvals_.clear();
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->disable(); });
}

void HazkeyFrontend::setCapabilities(guint caps) {
    if (retired_) return;
    gate_.submitOrHold(false, [this, caps] {
        enqueue([caps](const std::shared_ptr<HazkeyState>& s) {
            s->setCapabilities(caps);
        });
    });
}

void HazkeyFrontend::setContentType(guint purpose, guint hints) {
    if (retired_) return;
    const bool secure = isSecureInputContentType(purpose, hints);
    if (secureInput_ == secure) {
        return;
    }
    secureInput_ = secure;
    ++contentEpoch_;
    // ワーカーのキューに積まれた処理と、投稿済みの描画より先に効かせる
    state_->requestSecureInput(secure);
    if (ui_) {
        ui_->setSecureInput(secure);
    }
    if (secure) {
        abortSurroundingGate();
        specComposing_ = false;
        specListFocused_ = false;
        forwardedPressKeyvals_.clear();
    }
    enqueue([secure](const std::shared_ptr<HazkeyState>& s) {
        s->setSecureInput(secure);
    });
}

bool HazkeyFrontend::activateProperty(const gchar* propName,
                                      guint propState) {
    if (retired_ || propName == nullptr) {
        return false;
    }
    // static領域の名前のみを捕獲するため、ワーカー跨ぎの捕獲でも安全である
    const char* name = nullptr;
    if (g_strcmp0(propName, "InputMode") == 0) {
        name = "InputMode";
    } else if (g_strcmp0(propName, "Zenzai") == 0) {
        name = "Zenzai";
    } else if (g_strcmp0(propName, "LiveConvert") == 0) {
        name = "LiveConvert";
    }
    if (name != nullptr) {
        gate_.submitOrHold(false, [this, name] {
            enqueue([name](const std::shared_ptr<HazkeyState>& s) {
                s->activateProperty(name, 0);
            });
        });
        return true;
    }
    (void)propState;
    return false;
}

void HazkeyFrontend::setCursorLocation(gint x, gint y, gint w, gint h) {
    if (retired_) return;
    gate_.submitOrHold(false, [this, x, y, w, h] {
        enqueue([x, y, w, h](const std::shared_ptr<HazkeyState>& s) {
            s->setCursorLocation(x, y, w, h);
        });
    });
}

void HazkeyFrontend::setSurroundingText(IBusText* text, guint cursorIndex,
                                        guint anchorPos) {
    if (retired_ || secureInput_) return;
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
    // 周辺テキストの通知は保持せず、待機の解決に使う
    // 判定中に届いた場合は、ワーカーが保留を返した時点で到着済みとして解決する
    if (gate_.onSurroundingArrived()) {
        resolveSurroundingGate(true);
    }
}

void HazkeyFrontend::pageUp() {
    if (retired_) return;
    gate_.submitOrHold(false, [this] {
        enqueue([](const std::shared_ptr<HazkeyState>& s) { s->pageUp(); });
    });
}

void HazkeyFrontend::pageDown() {
    if (retired_) return;
    gate_.submitOrHold(false, [this] {
        enqueue([](const std::shared_ptr<HazkeyState>& s) { s->pageDown(); });
    });
}

void HazkeyFrontend::cursorUp() {
    if (retired_) return;
    gate_.submitOrHold(false, [this] {
        enqueue([](const std::shared_ptr<HazkeyState>& s) { s->cursorUp(); });
    });
}

void HazkeyFrontend::cursorDown() {
    if (retired_) return;
    gate_.submitOrHold(false, [this] {
        enqueue([](const std::shared_ptr<HazkeyState>& s) { s->cursorDown(); });
    });
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
    gate_.submitOrHold(false, [this, global, generation] {
        enqueue([global, generation](const std::shared_ptr<HazkeyState>& s) {
            s->candidateClickedGlobal(global, generation);
        });
    });
}

void shutdownSharedExecutor() { sharedExecutor().shutdown(); }

}  // namespace hazkey::ibus

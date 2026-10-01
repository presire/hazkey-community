#ifndef IBUS_HAZKEY_HAZKEY_FRONTEND_H
#define IBUS_HAZKEY_HAZKEY_FRONTEND_H

/**
 * @file hazkey_frontend.h
 * @brief IBus入力コンテキストごとのメインループ側ファサードを宣言する
 *
 * 全てのIBus vfunc呼び出しはこのファサードに集約される
 * 実処理はプロセス共通のSerialTaskExecutorワーカーへ委譲し、描画はHazkeyUiが行う
 */

#include <ibus.h>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <unordered_set>
#include "hazkey_state.h"
#include "hazkey_ui.h"
#include "serial_task_executor.h"

/** @brief IBusフロントエンドの名前空間 */
namespace hazkey::ibus {

/**
 * @class HazkeyFrontend
 * @brief 1つのIBus入力コンテキストに対するメインループ側ファサード
 *
 * process_key_eventがキーを消費するかを同期的に判定する
 * ブロック不可のため、判定にはワーカーが各操作後に送ったプレーンな値のみを用い、RPCは行わない
 * 実処理 (RPCとIME状態) をプロセス共通のSerialTaskExecutorワーカー1つにエンキューし、FIFO順序を保つ
 * ワーカー側ロジック (HazkeyState) とメインループ側描画 (HazkeyUi) をshared_ptrで生存させるため、終了時に実行器の排出待ちは不要で破棄済みオブジェクトに触れる心配もない
 */
class HazkeyFrontend : public std::enable_shared_from_this<HazkeyFrontend> {
   public:
    /**
     * @brief エンジンに結び付けたファサードを構築する
     *
     * @param engine 所有するIBusエンジン、HazkeyUiの構築へ渡される
     */
    explicit HazkeyFrontend(IBusEngine* engine);
    /** @brief 所有するファサード資源を破棄する */
    ~HazkeyFrontend();
    /** @brief コピー構築を禁止する */
    HazkeyFrontend(const HazkeyFrontend&) = delete;
    /** @brief コピー代入を禁止する */
    HazkeyFrontend& operator=(const HazkeyFrontend&) = delete;

    /**
     * @brief UIを破棄し、転送を止める
     *
     * メインループ専用でUIを破棄し(GObjectを全て解放)、転送を止める (冪等)
     * エンジン終了前にdestroy vfuncから呼ぶ
     */
    void retire();

    /**
     * @brief キーイベントを同期判定し、実処理をワーカーへ委譲する
     *
     * 未処理操作の残存中やサーバプロファイル未読込中は全イベントを投機的に消費する
     * 解放と[Shift]キー自体は消費せず、ワーカーへ委譲する
     * 入力可能キーは組成を開くと楽観的にみなす
     *
     * @param keyval 押下または解放されたキー値
     * @param keycode 押下または解放されたキーコード
     * @param state 修飾子と解放フラグを含むイベント状態
     * @return イベントを消費する場合はTRUE
     */
    gboolean processKeyEvent(guint keyval, guint keycode, guint state);
    /** @brief フォーカス取得をワーカーへ通知する */
    void focusIn();
    /** @brief フォーカス喪失を通知し、投機状態と転送記憶を消去する */
    void focusOut();
    /** @brief 入力状態を初期化し、投機状態と転送記憶を消去する */
    void reset();
    /** @brief 入力コンテキストの有効化をワーカーへ通知する */
    void enable();
    /** @brief 入力コンテキストの無効化を通知し、投機状態と転送記憶を消去する */
    void disable();
    /**
     * @brief クライアントのケーパビリティをワーカーへ通知する
     *
     * @param caps IBusが通知したケーパビリティマスク
     */
    void setCapabilities(guint caps);
    /**
     * @brief パネル操作に対応するプロパティ起動をワーカーへ委譲する
     *
     * @param propName 操作対象のプロパティ名
     * @param propState IBusが通知したプロパティ状態
     * @return 既知のプロパティでワーカーへ委譲した場合はtrue
     */
    bool activateProperty(const gchar* propName, guint propState);
    /**
     * @brief カーソル位置をワーカーへ通知する
     *
     * @param x カーソル矩形のX座標
     * @param y カーソル矩形のY座標
     * @param w カーソル矩形の幅
     * @param h カーソル矩形の高さ
     */
    void setCursorLocation(gint x, gint y, gint w, gint h);
    /**
     * @brief 周辺テキストをワーカーへ通知する
     *
     * メインループ上でプレーンな文字列へ複写済みであり、IBusTextは保持しない
     *
     * @param text 周辺テキストの複写
     * @param cursorIndex 周辺テキスト中のカーソル位置
     * @param anchorPos 周辺テキスト中のアンカー位置
     */
    void setSurroundingText(IBusText* text, guint cursorIndex, guint anchorPos);
    /** @brief 候補ページを前へ進める */
    void pageUp();
    /** @brief 候補ページを次へ進める */
    void pageDown();
    /** @brief 候補カーソルを上へ移動する */
    void cursorUp();
    /** @brief 候補カーソルを下へ移動する */
    void cursorDown();
    /**
     * @brief 候補クリックを全体候補番号へ写像してワーカーへ委譲する
     *
     * ページ内番号は、ユーザが見た描画そのもののスナップショットに対して解決する
     *
     * @param index クリックされたページ内候補番号
     * @param button クリックに使われたボタン
     * @param state クリック時の修飾子を含むイベント状態
     */
    void candidateClicked(guint index, guint button, guint state);

    /**
     * @brief 同期消費判定への入力値
     *
     * プレーンな値のみを持ち、判定中にRPCは行わない
     * IMEが所有し得るキーでTRUEを返す想定の判定材料であり、テスト用に公開する
     */
    struct DecisionInput {
        bool composing = false;                      ///< 組成中ならtrue
        bool listFocused = false;                    ///< 候補リストに焦点があるならtrue
        bool profileLoaded = false;                  ///< サーバプロファイルを読込済みならtrue
        HazkeyState::HotkeySpec liveConvert{};       ///< ライブ変換トグルのホットキー
        HazkeyState::HotkeySpec zenzaiToggle{};      ///< Zenzaiトグルのホットキー
        HazkeyState::HotkeySpec acceptPrediction{};  ///< 予測受入のホットキー
        HazkeyState::HotkeySpec deleteLearning{};    ///< 学習削除のホットキー
    };
    /**
     * @brief キーを消費するかを同期的に判定する
     *
     * IMEが所有し得るキーでTRUEを返す
     * ワーカーが実際には処理しなかった投機的TRUEはアプリへ転送されるため、TRUEは常に安全である
     * FALSEは保留中状態のどれでも処理し得ないキーにのみ返す
     *
     * @param keyval 判定対象のキー値
     * @param state 修飾子と解放フラグを含むイベント状態
     * @param in プレーンな値のみを持つ判定入力
     * @return 消費する場合はTRUE
     * @note テスト用に公開する
     */
    static gboolean decideConsumeKey(guint keyval, guint state,
                                     const DecisionInput& in);

    /**
     * @brief ワーカーが処理しなかったキーをアプリへ転送すべきか判定する
     *
     * IBusのforward_key_event()は、クライアント側に押下と解放の区別を持たないため、解放は対応する押下も転送済みの場合にのみ転送できる
     * IMEが消費したキーの解放を転送すると、アプリ側には幻のキー押下として現れる
     *
     * @param isRelease 解放イベントならtrue
     * @param keyval 判定対象のキー値
     * @param pendingPressKeyvals 押下を転送済みで解放がまだ未転送のkeyval群、押下と解放の対応付けを保つ
     * @return 転送すべき場合はtrue
     * @note テスト用に公開する
     */
    static bool shouldForwardUnhandledKey(
        bool isRelease, guint keyval,
        std::unordered_set<guint>& pendingPressKeyvals);

    /**
     * @brief 新しい組成を開き得る最初の入力として、周辺テキスト待ちの要否をワーカーへ判定依頼すべきか判定する
     *
     * プロファイル未読込の間は右文脈の設定が不明なため、判定を依頼する
     *
     * @param keyval 判定対象のキー値
     * @param state 修飾子と解放フラグを含むイベント状態
     * @param composing 投機上の組成中状態
     * @param listFocused 投機上の候補焦点状態
     * @param profileLoaded サーバプロファイルを読込済みならtrue
     * @param gateHint ワーカーが右文脈有効かつ周辺テキスト対応と報告した場合はtrue
     * @return 判定を依頼する場合はtrue
     * @note テスト用に公開する
     */
    static bool isSurroundingGateCandidate(guint keyval, guint state,
                                           bool composing, bool listFocused,
                                           bool profileLoaded, bool gateHint);

    /**
     * @brief 周辺テキスト待ちの状態遷移と、待機中に保持した操作のキュー
     *
     * Idle以外の間は、同じコンテキストの後続キーと状態変更操作を保持し、ワーカーへ投入しない
     * SerialTaskExecutorは準備のできた後続タスクを遅延タスクより先に実行するため、遅延タスクでは入力順序を保てない
     * 世代番号は待機の開始・解決・打ち切りのたびに進め、古いワーカー返答と期限タイマを無効化する
     * IBusとワーカーに依存しないため、テスト用に公開する
     */
    class SurroundingGateMachine {
       public:
        /** @brief 待機の段階 */
        enum class Phase {
            Idle,      ///< 待機なし
            Checking,  ///< 最初の入力をワーカーへ投入し、待機の要否の返答を待っている
            Waiting,   ///< 周辺テキストの到着または期限切れを待っている
        };
        /** @brief ワーカーの判定結果に対して呼び出し側が取るべき動作 */
        enum class CheckAction {
            Ignore,   ///< 古い返答または待機外のため何もしない
            Release,  ///< 待機不要。保持した操作を投入する
            Resolve,  ///< 判定中に周辺テキストが到着済み。直ちに解決する
            Wait,     ///< 周辺テキストを再要求し、期限タイマを登録する
        };

        /** @brief 待機中ならtrue */
        bool active() const { return phase_ != Phase::Idle; }
        /** @brief 現在の段階 */
        Phase phase() const { return phase_; }
        /** @brief 現在の待機世代 */
        uint64_t generation() const { return generation_; }

        /**
         * @brief 最初の入力の判定依頼を始める
         *
         * @return 判定依頼に紐付ける待機世代
         */
        uint64_t beginCheck();
        /** @brief 判定依頼の投入に失敗した場合に待機を取り消す */
        void cancelCheck();
        /**
         * @brief ワーカーの判定結果を受ける
         *
         * @param generation 判定依頼に紐付けた待機世代
         * @param gated ワーカーが最初の入力を保留した場合はtrue
         * @return 呼び出し側が取るべき動作
         */
        CheckAction onChecked(uint64_t generation, bool gated);
        /**
         * @brief 周辺テキストの通知を受ける
         *
         * 判定中なら到着済みとして記録し、待機中なら解決すべきことを返す
         *
         * @return 直ちに解決すべき場合はtrue
         */
        bool onSurroundingArrived();
        /**
         * @brief 期限タイマが現在の待機に対して有効か判定する
         *
         * @param generation タイマ登録時の待機世代
         * @return 期限切れとして解決すべき場合はtrue
         */
        bool timeoutApplies(uint64_t generation) const;

        /**
         * @brief 待機中なら操作を保持し、そうでなければ直ちに実行する
         *
         * @param isKey キーイベントならtrue (打ち切り時に再生しない)
         * @param run メインループ上で実行する投入処理
         */
        void submitOrHold(bool isKey, std::function<void()> run);
        /** @brief 待機を解決してIdleへ戻す。保持した操作は flush() で投入する */
        void resolve();
        /** @brief 保持した操作を、待機が再び始まるまで到着順に実行する */
        void flush();
        /** @brief 待機を打ち切り、保持したキーは捨て、状態変更操作だけを到着順に実行する */
        void abort();
        /** @brief 待機を打ち切り、保持した操作を全て破棄する */
        void clear();

       private:
        /** @brief 待機中に保持した操作 */
        struct HeldOp {
            bool isKey = false;         ///< キーイベントならtrue
            std::function<void()> run;  ///< 投入処理
        };
        Phase phase_ = Phase::Idle;      ///< 待機の段階
        uint64_t generation_ = 0;        ///< 待機世代
        bool arrivedWhileChecking_ = false;  ///< 判定中に周辺テキストが届いたか
        std::deque<HeldOp> held_;        ///< 待機中に保持した操作 (到着順)
    };

   private:
    /**
     * @brief 任意のワーカー処理をFIFO順で投入する
     *
     * 完了時にはワーカー側の状態要約をメインループへ送り、投機状態の整合を取る
     *
     * @param task ワーカー上で実行する処理
     */
    void enqueue(std::function<void(const std::shared_ptr<HazkeyState>&)> task);
    /**
     * @brief キー操作をFIFO順で投入し、未処理分を順序どおりに転送する
     *
     * キーを欠落させず、解放が対応する押下を追い越さないようにする
     *
     * @param keyval 押下または解放されたキー値
     * @param keycode 押下または解放されたキーコード
     * @param state 修飾子と解放フラグを含むイベント状態
     * @param consume 同期判定で消費すると決めた場合はTRUE
     * @param gateCheck ワーカーに周辺テキスト待ちの判定を依頼する場合はtrue
     */
    void enqueueKeyOp(guint keyval, guint keycode, guint state, gboolean consume,
                      bool gateCheck = false);
    /**
     * @brief ワーカー完了後の状態要約で投機状態を整合させる
     *
     * @param snapshot ワーカー側の組成状態をまとめた平易な要約
     */
    void applyIngress(const HazkeyState::IngressSnapshot& snapshot);

    /**
     * @brief ワーカーの判定結果を受けて待機を始めるか、保持した操作を再開する
     *
     * @param generation 判定を依頼した時点の待機世代
     * @param gated ワーカーが最初の入力を保留した場合はtrue
     */
    void onSurroundingGateChecked(uint64_t generation, bool gated);
    /**
     * @brief 待機を解決し、保留した最初の入力と保持した操作を順序どおりに投入する
     *
     * @param surroundingArrived 周辺テキストが届いた場合はtrue、期限切れの場合はfalse
     */
    void resolveSurroundingGate(bool surroundingArrived);
    /**
     * @brief 待機を即座に打ち切る
     *
     * 保留した最初の入力と保持したキーは再生せず、保持した状態変更操作だけを順序どおりに投入する
     */
    void abortSurroundingGate();
    /**
     * @brief 期限のワンショットタイマから呼ばれる
     *
     * @param data 待機世代と弱参照を持つ内部データ
     * @return 常にG_SOURCE_REMOVE
     */
    static gboolean onSurroundingGateTimeout(gpointer data);

    // 共有所有
    std::shared_ptr<HazkeyUi> ui_;        ///< メインループ専用の描画エンドポイント
    std::shared_ptr<HazkeyState> state_;  ///< ワーカー側のIMEロジック
    // 終了状態
    bool retired_ = false;                ///< 廃止済みで新規受付を止めた場合はtrue

    // 投機的入力取り込み
    // メインループが所有する投機的なingress状態
    // processKeyEvent()が先回りして更新し、ワーカーの完了時にapplyIngress()が整合を取る
    size_t pendingOps_ = 0;                       ///< 未完了の投入操作数
    bool specComposing_ = false;                  ///< 投機上の組成中状態
    bool specListFocused_ = false;                ///< 投機上の候補焦点状態
    bool profileLoaded_ = false;                  ///< サーバプロファイルの読込済み状態
    HazkeyState::HotkeySpec liveConvert_{};       ///< 取込中のライブ変換ホットキー
    HazkeyState::HotkeySpec zenzaiToggle_{};      ///< 取込中のZenzaiトグルホットキー
    HazkeyState::HotkeySpec acceptPrediction_{};  ///< 取込中の予測受入ホットキー
    HazkeyState::HotkeySpec deleteLearning_{};    ///< 取込中の学習削除ホットキー
    bool surroundingGateHint_ = false;            ///< ワーカーが右文脈有効かつ周辺テキスト対応と報告したか

    // 周辺テキスト待ち (新しい組成の最初の入力を、周辺テキストの到着または期限切れまで保留する)
    static constexpr guint kSurroundingGateTimeoutMs = 50;  ///< 待機の期限
    SurroundingGateMachine gate_;  ///< 待機の状態と保持した操作
    guint gatedKeyval_ = 0;        ///< 保留した最初の入力のキー値
    guint gatedState_ = 0;         ///< 保留した最初の入力の修飾子状態

    // 転送済み押下
    // 押下をアプリへ転送済みで、まだ解放を転送していないkeyval (shouldForwardUnhandledKey参照)
    std::unordered_set<guint> forwardedPressKeyvals_;
};

/**
 * @brief プロセス共通の実行器への新規受け付けを止め、ワーカーに合流する
 *
 * GLibメインループ終了後に1回だけ呼ぶこと
 * プロセス終了時の関数staticなフックとコネクタ破棄がワーカーと競合しなくなる
 */
void shutdownSharedExecutor();

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_FRONTEND_H

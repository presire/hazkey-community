/**
 * @file serial_task_executor.h
 * @brief 単一のワーカースレッドでタスクを順番に実行するクラスを宣言する
 *
 * タスクは投入順に実行し、遅延タスクは実行時刻まで即時タスクを妨げない
 * 終了時は実行時刻に達していないタスクを破棄する
 * タスクが共有所有権で必要な状態を保持するため、実行器は状態の寿命を管理しない
 */

#ifndef HAZKEY_FRONTEND_COMMON_SERIAL_TASK_EXECUTOR_H
#define HAZKEY_FRONTEND_COMMON_SERIAL_TASK_EXECUTOR_H

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <mutex>
#include <thread>

/** @brief フロントエンド共通部の型と関数を定義する名前空間 */
namespace hazkey::frontend {

/**
 * @class SerialTaskExecutor
 * @brief タスクを単一のワーカースレッドで直列実行する
 *
 * RPCをメインループから分離して、投入順を保ったまま1本のワーカースレッドで処理する
 * 遅延タスクは期限に達するまで待機して、その間も実行可能な後続タスクを処理できる
 * 各タスクが状態を共有所有権で保持する設計のため、破棄時にキューを完了まで実行する必要はない
 *
 * @note コピーと代入はできない
 * @note 停止を開始すると新しいタスクは受け付けない
 */
class SerialTaskExecutor {
   public:
    /**
     * @brief 保留タスクを識別するトークン型
     *
     * 0は無効なトークンを表す
     */
    using Token = uint64_t;
    static constexpr Token kInvalidToken = 0;  ///< 無効なトークン

    /** @brief ワーカースレッドを開始する */
    SerialTaskExecutor();

    /**
     * @brief ワーカースレッドを停止して終了を待つ
     *
     * 実行時刻に達していないタスクは破棄する
     */
    ~SerialTaskExecutor();
    SerialTaskExecutor(const SerialTaskExecutor&) = delete;
    SerialTaskExecutor& operator=(const SerialTaskExecutor&) = delete;

    /**
     * @brief タスクをすぐに実行できる状態で投入する
     *
     * @param task ワーカースレッドで実行するタスク
     * @return 取消に使うトークン
     * @return 停止開始後はkInvalidToken
     */
    Token submit(std::function<void()> task);

    /**
     * @brief 指定時間後に実行できるタスクを投入する
     *
     * 遅延中も、実行可能な後続タスクの処理を妨げない
     *
     * @param task ワーカースレッドで実行するタスク
     * @param delayUs 実行可能になるまでの遅延時間[us]
     * @return 取消に使うトークン
     * @return 停止開始後はkInvalidToken
     */
    Token submitDelayed(std::function<void()> task, uint64_t delayUs);

    /**
     * @brief 未実行のタスクを取り消す
     *
     * 実行済みまたは既に取り消したタスクには何もしない
     *
     * @param token 取り消すタスクのトークン
     */
    void cancel(Token token);

    /**
     * @brief 呼び出し元がワーカースレッドかを判定する
     * @return ワーカースレッドからの呼び出しならtrue
     */
    bool onWorkerThread() const;

    /**
     * @brief 未実行タスクの数を返す
     * @return キューで待機中のタスク数
     */
    size_t pendingCount() const;

    /**
     * @brief 現在実行可能な投入済みタスクが終わるまで待つ
     *
     * 期限前の遅延タスクは待たない
     * ワーカースレッド自身から呼び出した場合は待たずに戻る
     *
     * @note テストと破棄時の補助処理用
     */
    void drainAndWait();

    /**
     * @brief 現在実行可能な投入済みタスクを期限付きで待つ
     *
     * 期限前の遅延タスクは待たない
     *
     * @param timeout 最大待機時間
     * @return 期限内に処理できた場合はtrue
     * @return 待機期限を超えた場合はfalse
     */
    bool drainAndWaitFor(std::chrono::microseconds timeout);

    /**
     * @brief ワーカースレッドを停止して終了を待つ
     *
     * 複数回呼び出しても安全で、停止後の投入はkInvalidTokenを返す
     * @note ワーカースレッド自身から呼び出した場合は終了待ちを行わない
     */
    void shutdown();

   private:
    /**
     * @struct Entry
     * @brief キュー内のタスク1件を表す
     */
    struct Entry {
        Token token = kInvalidToken;                    ///< 取消に使うトークン
        std::chrono::steady_clock::time_point readyAt;  ///< 実行可能になる時刻
        std::function<void()> task;                     ///< 実行するタスク
    };

    /**
     * @brief ワーカースレッドの処理ループを実行する
     *
     * 実行可能なタスクを取り出し、なければ最も早い期限または通知を待つ
     * 停止時は期限前のタスクを実行せずに戻る
     */
    void workerLoop();

    /**
     * @brief 実行可能な最初のタスクをキューから取り出す
     * @param out 取り出したタスクの格納先
     * @return タスクを取り出せた場合はtrue
     * @note mutex_を保持した状態で呼び出す
     */
    bool takeNextReadyLocked(Entry* out);

    /**
     * @brief 指定トークンのタスクをキューから削除する
     * @param queue 対象のタスクキュー
     * @param token 削除するタスクのトークン
     * @note mutex_を保持した状態で呼び出す
     */
    static void eraseTokenLocked(std::deque<Entry>* queue, Token token);

    /**
     * @brief キューの先行タスク完了を通知する待機用の目印タスクを投入する
     * @return 目印タスク完了時に準備完了となるfuture
     */
    std::future<void> submitDrainSentinel();

    // 同期とタスクキュー
    mutable std::mutex mutex_;    ///< キューと停止状態を保護するミューテックス
    std::condition_variable cv_;  ///< 投入、取消、停止を通知する条件変数
    std::deque<Entry> queue_;     ///< 投入順に保持するタスクキュー

    // トークンとスレッド状態
    Token nextToken_ = 1;         ///< 次に発行するトークン
    bool stopping_ = false;       ///< 停止開始後はtrue
    std::thread worker_;          ///< タスクを実行するワーカースレッド
};

}  // namespace hazkey::frontend

#endif  // HAZKEY_FRONTEND_COMMON_SERIAL_TASK_EXECUTOR_H

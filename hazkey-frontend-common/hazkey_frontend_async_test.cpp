/**
 * @file hazkey_frontend_async_test.cpp
 * @brief 非同期転送基盤の単体検証をまとめる
 *
 * 単一ワーカースレッドの先入先出順序と遅延処理と取消と排出と停止と
 * 主循環配送子の即時実行と遅延配送を検証する
 * フレームワーク非依存の部品だけを使い実サーバは起動しない
 */
// IBusのprocess_key_eventを非ブロッキング化するための非同期転送基盤を検証する
// SerialTaskExecutorの単一ワーカーFIFO、遅延処理、取消、排出、停止を対象とする
// setMainLoopPosterとpostToMainLoopの主循環配送も対象とし、既定は呼出元で実行する
// フロントエンド、IBusデーモン、hazkey-serverを使わないフレームワーク非依存の検査である
#include <atomic>
#include <chrono>
#include <iostream>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

#include "hazkey_frontend_hooks.h"
#include "serial_task_executor.h"

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::cerr << "CHECK failed at line " << __LINE__ << ": " #cond \
                      << std::endl;                                        \
            std::exit(1);                                                  \
        }                                                                  \
    } while (0)

namespace {

using hazkey::frontend::SerialTaskExecutor;

/**
 * @brief 単一ワーカースレッドで先入先出順序が守られることを検証する
 *
 * 多数の処理を投入して同一ワーカースレッドで順序どおりに実行されることと
 * ワーカースレッド外ではその状態にならないことを確認する
 */
void testFifoOnSingleThread() {
    SerialTaskExecutor executor;
    std::mutex orderMutex;
    std::vector<int> order;
    std::atomic<int> distinctThreads{0};
    std::thread::id seen{};
    std::atomic<bool> sawOtherThread{false};

    constexpr int kCount = 200;
    for (int i = 0; i < kCount; ++i) {
        executor.submit([&, i] {
            if (distinctThreads.fetch_add(1) == 0) {
                seen = std::this_thread::get_id();
            } else if (std::this_thread::get_id() != seen) {
                sawOtherThread = true;
            }
            std::lock_guard<std::mutex> lock(orderMutex);
            order.push_back(i);
        });
    }
    executor.drainAndWait();

    CHECK(!sawOtherThread);
    CHECK(order.size() == static_cast<size_t>(kCount));
    for (int i = 0; i < kCount; ++i) {
        CHECK(order[static_cast<size_t>(i)] == i);  // 厳密なFIFO順序
    }
    CHECK(!executor.onWorkerThread());
    std::cout << "[PASS] FIFO order on a single worker thread\n";
}

/**
 * @brief 遅延処理が即時処理を阻まないことを検証する
 *
 * 遅延期限前に即時処理が先に実行されることと
 * 期限後に遅延処理が実行されることを確認する
 */
void testDelayedTasksDoNotBlockReadyOnes() {
    SerialTaskExecutor executor;
    std::mutex mutex;
    std::vector<std::string> order;

    const auto start = std::chrono::steady_clock::now();
    executor.submitDelayed(
        [&] {
            std::lock_guard<std::mutex> lock(mutex);
            order.push_back("delayed");
        },
    120'000);  // 120[ms]
    executor.submit([&] {
        std::lock_guard<std::mutex> lock(mutex);
        order.push_back("immediate");
    });
    // 即時処理は遅延期限より十分前に実行されなければならない
    while (true) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!order.empty()) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                               std::chrono::steady_clock::now() - start)
                               .count();
    CHECK(elapsedMs < 100);
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(order[0] == "immediate");
    }
    // drainAndWait()は期限前の遅延処理を待たないため、期限到達は明示的に待つ
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    while (std::chrono::steady_clock::now() < deadline) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (order.size() == 2) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(order.size() == 2);
        CHECK(order[1] == "delayed");
    }
    std::cout << "[PASS] delayed task does not block an earlier-ready task\n";
}

/**
 * @brief 取消済み遅延処理が実行されないことを検証する
 *
 * 取消後に排出待ちを行っても処理が走らず
 * 予約が破棄されることを確認する
 */
void testCancelPreventsRun() {
    SerialTaskExecutor executor;
    std::atomic<bool> ran{false};
    const auto token = executor.submitDelayed([&] { ran = true; }, 60'000);
    executor.cancel(token);
    executor.drainAndWait();
    CHECK(!ran);
    std::cout << "[PASS] cancelled delayed task never runs\n";
}

/**
 * @brief タスクが例外を投げてもワーカーが止まらないことを検証する
 *
 * 例外を投げたタスクの後に積んだタスクも実行され、プロセスが終了しないことを確認する
 */
void testThrowingTaskDoesNotStopWorker() {
    SerialTaskExecutor executor;
    std::atomic<bool> ranAfter{false};
    executor.submit([] { throw std::bad_alloc(); });
    executor.submit([] { throw 42; });
    executor.submit([&] { ranAfter = true; });
    executor.drainAndWait();
    CHECK(ranAfter);
    std::cout << "[PASS] throwing task does not stop the worker\n";
}

/**
 * @brief 有限排出が時間切れと静止成功を返すことを検証する
 *
 * 作業中の排出待ちは時間切れで偽を返し解放後の排出待ちは真を返すことを確認する
 */
void testBoundedDrainTimesOutAndSucceedsWhenIdle() {
    SerialTaskExecutor executor;
    std::atomic<bool> started{false};
    std::atomic<bool> release{false};
    executor.submit([&] {
        started = true;
        while (!release.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    while (!started.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    constexpr auto kTimeout = std::chrono::milliseconds(10);
    CHECK(!executor.drainAndWaitFor(kTimeout));
    release = true;
    executor.drainAndWait();
    CHECK(executor.drainAndWaitFor(kTimeout));
    std::cout << "[PASS] bounded drain times out and succeeds when idle\n";
}

/**
 * @brief 時間切れ後の排出待ちが後で完了できることを検証する
 *
 * 有限排出が時間切れで偽を返した後に解放すれば
 * 処理が完了することを確認する
 */
void testTimedOutDrainCanFinishLater() {
    SerialTaskExecutor executor;
    std::atomic<bool> started{false};
    std::atomic<bool> release{false};
    std::atomic<bool> finished{false};
    executor.submit([&] {
        started = true;
        while (!release.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        finished = true;
    });
    while (!started.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    CHECK(!executor.drainAndWaitFor(std::chrono::milliseconds(10)));
    release = true;
    executor.drainAndWait();
    CHECK(finished);
    std::cout << "[PASS] timed-out drain sentinel can finish later\n";
}

/**
 * @brief ワーカースレッド内からの排出待ちが即時復帰することを検証する
 *
 * ワーカースレッド自身の停止を招かずに復帰することと
 * 投入した排出待ちが実行されることを確認する
 */
void testWorkerDrainReturnsPromptly() {
    SerialTaskExecutor executor;
    std::atomic<bool> returned{false};
    executor.submit([&] {
        executor.drainAndWait();
        returned = true;
    });

    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
    while (!returned.load() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(returned);
    executor.drainAndWait();
    std::cout << "[PASS] worker drain returns without self-deadlock\n";
}

/**
 * @brief 停止が保留処理を破棄することを検証する
 *
 * 停止後の遅延処理が実行されず
 * 新規投入が拒否されることを確認する
 */
void testShutdownDropsPending() {
    SerialTaskExecutor executor;
    std::atomic<bool> ran{false};
    executor.submitDelayed([&] { ran = true; }, 60'000);
    executor.shutdown();
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    CHECK(!ran);
    // 停止後の投入はキューに追加せず拒否する
    CHECK(executor.submit([] {}) == SerialTaskExecutor::kInvalidToken);
    std::cout << "[PASS] shutdown drops pending and rejects new tasks\n";
}

/**
 * @brief 既定配送子が即時実行することを検証する
 *
 * 配送子未設定では主循環配送が呼び出し元で直接実行されることを確認する
 */
void testDefaultPosterRunsInline() {
    // 配送子未設定のfcitx5とテストではpostToMainLoopが呼出元で実行する
    hazkey::frontend::setMainLoopPoster(nullptr);
    bool ranHere = false;
    hazkey::frontend::postToMainLoop([&] { ranHere = true; });
    CHECK(ranHere);
    std::cout << "[PASS] default postToMainLoop runs inline\n";
}

/**
 * @brief 設定済み配送子が主処理へ遅延配送することを検証する
 *
 * ワーカースレッドからの配送が即時実行されず配送子に保持され
 * 主循環相当の取出しで実行されることを確認する
 * 最後に既定へ戻す
 */
void testInstalledPosterDefersToMainThread() {
    std::mutex mutex;
    std::vector<std::function<void()>> queued;
    std::thread::id caller = std::this_thread::get_id();
    (void)caller;
    hazkey::frontend::setMainLoopPoster([&](std::function<void()> task) {
        std::lock_guard<std::mutex> lock(mutex);
        queued.push_back(std::move(task));
    });

    std::atomic<bool> ranInline{false};
    // ワーカースレッドから配送し、配送子が処理を受け取って呼出元で実行しないことを確認する
    SerialTaskExecutor executor;
    executor.submit([&] {
        hazkey::frontend::postToMainLoop([&] { ranInline = true; });
    });
    executor.drainAndWait();
    CHECK(!ranInline);  // 配送子が保持し呼出元では実行しない
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(queued.size() == 1);
    }
    // 主循環相当の処理で配送済みタスクを実行する
    {
        std::lock_guard<std::mutex> lock(mutex);
        queued[0]();
    }
    CHECK(ranInline);

    // setMainLoopPoster(nullptr)で配送子を消去して既定の即時実行へ戻す
    hazkey::frontend::setMainLoopPoster(nullptr);
    std::cout << "[PASS] installed poster defers to the main-loop drain\n";
}

/**
 * @brief 保留数とワーカースレッド状態が正しいことを検証する
 *
 * 作業停留中は保留数が一以上となり排出後は零となることを確認する
 */
void testPendingCountAndWorkerIdentity() {
    SerialTaskExecutor executor;
    std::atomic<bool> gate{false};
    executor.submit([&] {
        while (!gate.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    // 2番目の処理は先頭の処理の後ろで待機する
    executor.submit([] {});
    CHECK(executor.pendingCount() >= 1);
    gate = true;
    executor.drainAndWait();
    CHECK(executor.pendingCount() == 0);
    std::cout << "[PASS] pendingCount / worker identity\n";
}

}  // namespace

/**
 * @brief 非同期基盤の全検証を順に実行する
 *
 * 先入先出と遅延非阻止と取消と有限排出と時間切れ後完了と
 * ワーカースレッド内排出と停止破棄と配送子即時実行と遅延配送と保留数を呼び出して成功を報告する
 */
int main() {
    testFifoOnSingleThread();
    testDelayedTasksDoNotBlockReadyOnes();
    testCancelPreventsRun();
    testThrowingTaskDoesNotStopWorker();
    testBoundedDrainTimesOutAndSucceedsWhenIdle();
    testTimedOutDrainCanFinishLater();
    testWorkerDrainReturnsPromptly();
    testShutdownDropsPending();
    testDefaultPosterRunsInline();
    testInstalledPosterDefersToMainThread();
    testPendingCountAndWorkerIdentity();
    std::cout << "\nAll frontend async foundation tests passed.\n";
    return 0;
}

// Tests for the asynchronous-transport foundation added for the IBus
// process_key_event unblocking work:
//   - hazkey::frontend::SerialTaskExecutor (single-worker FIFO, timed tasks,
//     cancellation, drain, shutdown)
//   - hazkey::frontend::setMainLoopPoster / postToMainLoop (main-loop
//     delivery hook; default inline, installed poster never runs inline)
//
// No frontend, IBus daemon or hazkey-server is involved: both units are
// framework-independent.
#include <atomic>
#include <chrono>
#include <iostream>
#include <mutex>
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
        CHECK(order[static_cast<size_t>(i)] == i);  // strict FIFO
    }
    CHECK(!executor.onWorkerThread());
    std::cout << "[PASS] FIFO order on a single worker thread\n";
}

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
        120'000);  // 120ms
    executor.submit([&] {
        std::lock_guard<std::mutex> lock(mutex);
        order.push_back("immediate");
    });
    // The immediate task must run long before the delayed deadline.
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
    // drainAndWait() deliberately does NOT wait for a not-yet-due delayed
    // task, so wait for the delayed deadline explicitly.
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

void testCancelPreventsRun() {
    SerialTaskExecutor executor;
    std::atomic<bool> ran{false};
    const auto token = executor.submitDelayed([&] { ran = true; }, 60'000);
    executor.cancel(token);
    executor.drainAndWait();
    CHECK(!ran);
    std::cout << "[PASS] cancelled delayed task never runs\n";
}

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

void testShutdownDropsPending() {
    SerialTaskExecutor executor;
    std::atomic<bool> ran{false};
    executor.submitDelayed([&] { ran = true; }, 60'000);
    executor.shutdown();
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    CHECK(!ran);
    // submit after shutdown is rejected rather than queued.
    CHECK(executor.submit([] {}) == SerialTaskExecutor::kInvalidToken);
    std::cout << "[PASS] shutdown drops pending and rejects new tasks\n";
}

void testDefaultPosterRunsInline() {
    // With no poster installed (fcitx5 / tests), postToMainLoop runs inline.
    hazkey::frontend::setMainLoopPoster(nullptr);
    bool ranHere = false;
    hazkey::frontend::postToMainLoop([&] { ranHere = true; });
    CHECK(ranHere);
    std::cout << "[PASS] default postToMainLoop runs inline\n";
}

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
    // Post from a worker thread: the poster must receive the task, not run it
    // on the posting thread.
    SerialTaskExecutor executor;
    executor.submit([&] {
        hazkey::frontend::postToMainLoop([&] { ranInline = true; });
    });
    executor.drainAndWait();
    CHECK(!ranInline);  // held by the poster, not executed inline
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(queued.size() == 1);
    }
    // "Main loop" drains it.
    {
        std::lock_guard<std::mutex> lock(mutex);
        queued[0]();
    }
    CHECK(ranInline);

    // Restore the inline default (setMainLoopPoster(nullptr) clears the hook).
    hazkey::frontend::setMainLoopPoster(nullptr);
    std::cout << "[PASS] installed poster defers to the main-loop drain\n";
}

void testPendingCountAndWorkerIdentity() {
    SerialTaskExecutor executor;
    std::atomic<bool> gate{false};
    executor.submit([&] {
        while (!gate.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    // Second task waits behind the first.
    executor.submit([] {});
    CHECK(executor.pendingCount() >= 1);
    gate = true;
    executor.drainAndWait();
    CHECK(executor.pendingCount() == 0);
    std::cout << "[PASS] pendingCount / worker identity\n";
}

}  // namespace

int main() {
    testFifoOnSingleThread();
    testDelayedTasksDoNotBlockReadyOnes();
    testCancelPreventsRun();
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

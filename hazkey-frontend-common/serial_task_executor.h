#ifndef HAZKEY_FRONTEND_COMMON_SERIAL_TASK_EXECUTOR_H
#define HAZKEY_FRONTEND_COMMON_SERIAL_TASK_EXECUTOR_H

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace hazkey::frontend {

// A single background worker that runs submitted tasks in FIFO order on one
// thread.
//
// Why this exists: the shared transport (HazkeyServerConnector::transact) is
// fully synchronous and its UNIX-socket reads can block for up to 10 seconds.
// A frontend that calls it from its UI/main-loop thread therefore freezes
// while a slow or wedged hazkey-server responds. Routing ALL access to the
// connector and to the frontend's input state through one executor thread
// keeps the transport single-threaded (so its ordering, timeout, reconnect
// and read-through-cache semantics are unchanged) while freeing the main
// loop; the executor thread becomes the sole owner of that state.
//
// FIFO guarantee: a task starts only after every task submitted before it has
// completed, so callers can serialize access to unlocked state simply by
// routing every touch through the executor.
//
// Timed tasks: submitDelayed() schedules a task for a future steady-clock
// deadline without blocking later submissions. The worker always runs the
// earliest *ready* task; if none is ready it sleeps until the earliest
// deadline (waking early on a new submit/cancel). Delayed tasks back the
// candidate-refresh coalescer's trailing edge (see
// hazkey-frontend-common/candidate_refresh_coalescer.h), replacing the former
// frontend-owned GLib timer.
//
// Lifetime: the executor owns no user state. Callers keep their state alive by
// having each task capture a std::shared_ptr to it, so teardown never needs to
// drain the queue and no task can outlive the state it touches.
class SerialTaskExecutor {
   public:
    // Opaque handle for a pending task. 0 means "no task".
    using Token = uint64_t;
    static constexpr Token kInvalidToken = 0;

    SerialTaskExecutor();
    ~SerialTaskExecutor();
    SerialTaskExecutor(const SerialTaskExecutor&) = delete;
    SerialTaskExecutor& operator=(const SerialTaskExecutor&) = delete;

    // Runs `task` on the worker thread. Returns a token usable with cancel()
    // while the task is still pending; returns kInvalidToken once the
    // executor is stopping (the task is then dropped).
    Token submit(std::function<void()> task);

    // Like submit(), but the task becomes eligible only after `delayUs`
    // microseconds. The caller is expected to cancel the previous token
    // before scheduling the next one (latest-wins).
    Token submitDelayed(std::function<void()> task, uint64_t delayUs);

    // Cancels a not-yet-started task. No-op if it already ran or was
    // cancelled. Safe to call from any thread, including the worker.
    void cancel(Token token);

    // True when the caller is the executor's worker thread.
    bool onWorkerThread() const;

    // Number of tasks not yet started (a running task is not counted).
    size_t pendingCount() const;

    // Blocks until every task submitted so far has completed. A delayed task
    // that is not yet due does not block this. Test/teardown helper only;
    // production lifetime is handled by the tasks' shared_ptr captures.
    void drainAndWait();

    // Drains and stops the worker, then joins it. Idempotent. After this,
    // submit() returns kInvalidToken.
    void shutdown();

   private:
    struct Entry {
        Token token = kInvalidToken;
        std::chrono::steady_clock::time_point readyAt;
        std::function<void()> task;
    };

    void workerLoop();
    // Removes and returns the earliest task whose deadline has been reached,
    // preferring earlier submissions. Returns false when `stopping_` and no
    // ready task remains. Must be called with `mutex_` held.
    bool takeNextReadyLocked(Entry* out);
    static void eraseTokenLocked(std::deque<Entry>* queue, Token token);

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    // All tasks live in one deque in submission order; delayed ones carry a
    // future readyAt. Small queues make the linear scans below cheap.
    std::deque<Entry> queue_;
    Token nextToken_ = 1;
    bool stopping_ = false;
    std::thread worker_;
};

}  // namespace hazkey::frontend

#endif  // HAZKEY_FRONTEND_COMMON_SERIAL_TASK_EXECUTOR_H

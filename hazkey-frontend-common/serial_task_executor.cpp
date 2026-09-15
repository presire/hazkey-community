#include "serial_task_executor.h"

#include <algorithm>
#include <future>
#include <memory>
#include <utility>

namespace hazkey::frontend {

SerialTaskExecutor::SerialTaskExecutor() {
    worker_ = std::thread([this] { workerLoop(); });
}

SerialTaskExecutor::~SerialTaskExecutor() { shutdown(); }

SerialTaskExecutor::Token SerialTaskExecutor::submit(std::function<void()> task) {
    return submitDelayed(std::move(task), 0);
}

SerialTaskExecutor::Token SerialTaskExecutor::submitDelayed(
    std::function<void()> task, uint64_t delayUs) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) {
        return kInvalidToken;
    }
    Entry entry;
    entry.token = nextToken_++;
    entry.readyAt = std::chrono::steady_clock::now() +
                    std::chrono::microseconds(delayUs);
    entry.task = std::move(task);
    queue_.push_back(std::move(entry));
    const Token token = queue_.back().token;
    cv_.notify_all();
    return token;
}

void SerialTaskExecutor::eraseTokenLocked(std::deque<Entry>* queue, Token token) {
    if (queue == nullptr || token == kInvalidToken) {
        return;
    }
    for (auto it = queue->begin(); it != queue->end(); ++it) {
        if (it->token == token) {
            queue->erase(it);
            return;
        }
    }
}

void SerialTaskExecutor::cancel(Token token) {
    if (token == kInvalidToken) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    eraseTokenLocked(&queue_, token);
}

bool SerialTaskExecutor::onWorkerThread() const {
    return worker_.get_id() == std::this_thread::get_id();
}

size_t SerialTaskExecutor::pendingCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return queue_.size();
}

bool SerialTaskExecutor::takeNextReadyLocked(Entry* out) {
    const auto now = std::chrono::steady_clock::now();
    for (auto it = queue_.begin(); it != queue_.end(); ++it) {
        if (it->readyAt <= now) {
            *out = std::move(*it);
            queue_.erase(it);
            return true;
        }
    }
    return false;
}

void SerialTaskExecutor::workerLoop() {
    for (;;) {
        Entry next;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            while (!takeNextReadyLocked(&next)) {
                // Shutdown drops any remaining (not-yet-due) tasks: callers
                // own their state's lifetime through the tasks' shared_ptr
                // captures, so nothing here needs to run to completion.
                if (stopping_) {
                    return;
                }
                auto earliest = std::chrono::steady_clock::time_point::max();
                for (const auto& entry : queue_) {
                    earliest = std::min(earliest, entry.readyAt);
                }
                if (earliest == std::chrono::steady_clock::time_point::max()) {
                    cv_.wait(lock, [this] {
                        return stopping_ || !queue_.empty();
                    });
                } else {
                    // Wakes early on a new submit/cancel, which re-evaluates
                    // whether a task became the earliest.
                    cv_.wait_until(lock, earliest);
                }
            }
        }
        next.task();
    }
}

std::future<void> SerialTaskExecutor::submitDrainSentinel() {
    auto done = std::make_shared<std::promise<void>>();
    std::future<void> finished = done->get_future();
    const Token token = submit([done] { done->set_value(); });
    if (token == kInvalidToken) {
        done->set_value();  // already stopping: nothing left to drain
    }
    return finished;
}

void SerialTaskExecutor::drainAndWait() {
    // A worker cannot wait for its own sentinel without deadlocking.
    if (onWorkerThread()) {
        return;
    }
    submitDrainSentinel().wait();
}

bool SerialTaskExecutor::drainAndWaitFor(std::chrono::microseconds timeout) {
    // A worker cannot wait for its own sentinel without deadlocking.
    if (onWorkerThread()) {
        return true;
    }
    return submitDrainSentinel().wait_for(timeout) ==
           std::future_status::ready;
}

void SerialTaskExecutor::shutdown() {
    if (onWorkerThread()) {
        // Never join ourselves; a worker-initiated shutdown is a caller bug.
        return;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

}  // namespace hazkey::frontend

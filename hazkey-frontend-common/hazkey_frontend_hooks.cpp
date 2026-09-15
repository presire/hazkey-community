#include "hazkey_frontend_hooks.h"

#include <atomic>
#include <utility>

namespace hazkey::frontend {

namespace {

LogSink& logSinkStorage() {
    static LogSink sink;
    return sink;
}

ServerSpawner& serverSpawnerStorage() {
    static ServerSpawner spawner;
    return spawner;
}

MainLoopPoster& mainLoopPosterStorage() {
    static MainLoopPoster poster;
    return poster;
}

LogLevelPredicate& logLevelPredicateStorage() {
    static LogLevelPredicate predicate;
    return predicate;
}

}  // namespace

void setLogSink(LogSink sink) { logSinkStorage() = std::move(sink); }

void logMessage(LogLevel level, const std::string& message) {
    const LogSink& sink = logSinkStorage();
    if (sink) {
        sink(level, message);
    }
}

void setServerSpawner(ServerSpawner spawner) {
    serverSpawnerStorage() = std::move(spawner);
}

void setLogLevelEnabled(LogLevelPredicate predicate) {
    logLevelPredicateStorage() = std::move(predicate);
}

bool isLogLevelEnabled(LogLevel level) {
    const LogLevelPredicate& predicate = logLevelPredicateStorage();
    return !predicate || predicate(level);
}

void spawnServer(bool forceRestart) {
    const ServerSpawner& spawner = serverSpawnerStorage();
    if (spawner) {
        spawner(forceRestart);
    }
}

void setMainLoopPoster(MainLoopPoster poster) {
    static std::atomic<bool> installed{false};
    if (!poster) {
        // Passing an empty function clears the hook (tests restore the inline
        // default) and releases the install slot for a later install.
        mainLoopPosterStorage() = nullptr;
        installed.store(false);
        return;
    }
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) {
        return;  // first real install wins; concurrent/repeat installs ignored
    }
    mainLoopPosterStorage() = std::move(poster);
}

void postToMainLoop(std::function<void()> task) {
    const MainLoopPoster& poster = mainLoopPosterStorage();
    if (poster) {
        poster(std::move(task));
        return;
    }
    // No worker-based frontend installed a poster (fcitx5, tests): keep the
    // historical single-threaded behavior by running inline.
    task();
}

}  // namespace hazkey::frontend

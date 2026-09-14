#include "hazkey_frontend_hooks.h"

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

}  // namespace hazkey::frontend

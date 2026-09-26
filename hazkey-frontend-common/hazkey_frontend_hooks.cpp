/**
 * @file hazkey_frontend_hooks.cpp
 * @brief 共通通信層へ登録するフックの保存と呼び出しを実装する
 *
 * 公開関数の意味は、ヘッダ側の文書を正として、匿名名前空間内に各フックの保存先を置く
 */

#include "hazkey_frontend_hooks.h"
#include <atomic>
#include <utility>

namespace hazkey::frontend {

namespace {

/**
 * @brief ログ出力先の保存領域を返す
 *
 * 関数内静的変数で1件だけ保持する
 *
 * @return ログ出力先への参照
 */
LogSink& logSinkStorage() {
    static LogSink sink;
    return sink;
}

/**
 * @brief サーバ起動処理の保存領域を返す
 *
 * 関数内静的変数で1件だけ保持する
 *
 * @return サーバ起動処理への参照
 */
ServerSpawner& serverSpawnerStorage() {
    static ServerSpawner spawner;
    return spawner;
}

/**
 * @brief メインループ配送先の保存領域を返す
 *
 * 関数内静的変数で1件だけ保持する
 *
 * @return メインループ配送先への参照
 */
MainLoopPoster& mainLoopPosterStorage() {
    static MainLoopPoster poster;
    return poster;
}

/**
 * @brief ログレベル有効判定の保存領域を返す
 *
 * 関数内静的変数で1件だけ保持する
 *
 * @return 有効判定関数への参照
 */
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
        // 空の関数でフックを解除して、後から再登録できるようにする
        mainLoopPosterStorage() = nullptr;
        installed.store(false);
        return;
    }
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) {
        return;  // 最初に登録した空でない関数のみを使用する
    }
    mainLoopPosterStorage() = std::move(poster);
}

void postToMainLoop(std::function<void()> task) {
    const MainLoopPoster& poster = mainLoopPosterStorage();
    if (poster) {
        poster(std::move(task));
        return;
    }
    // 配送先が未登録なら従来通り呼び出し元のスレッドで実行する
    task();
}

}  // namespace hazkey::frontend

/**
 * @file hazkey_frontend_glib.cpp
 * @brief GLib向けフロントエンドフックの実装
 *
 * 公開APIの仕様はヘッダ (hazkey_frontend_glib.h) を参照のこと
 * メインループ配送、ログ出力、サーバ起動のGLib結線を実装する
 */
#include "hazkey_frontend_glib.h"
#include "hazkey_frontend_hooks.h"
#include <glib.h>
#include <atomic>
#include <functional>
#include <string>
#include <utility>
#include <vector>

/** @brief IBusフロントエンドの名前空間 */
namespace hazkey::ibus {

void installGlibFrontendHooks() {
    // ワーカータスクがフックを読むより前に1回だけ導入する (本呼出しの直後にエンジンがフロントエンドを構築する)
    // 2つ目のエンジン実体から再導入すると実行中ワーカーと競合する
    static std::atomic<bool> installed{false};
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) {
        return;
    }

    // ワーカースレッド側IMEロジック向けのメインループ配送
    //
    // g_idle_add_full()は、全体既定メインコンテキスト (ibus_main()が回すコンテキスト) へアイドルソースを結び付ける
    // g_main_context_invoke()とは異なり、呼出し側 (ワーカー) スレッド上でコールバックを直実行することは決してなく、
    // G_PRIORITY_DEFAULT指定で低優先アイドル処理に枯渇させられない
    // 等優先ソースは結付順に配送されるため、UI更新はFIFO順を保つ
    hazkey::frontend::setMainLoopPoster([](std::function<void()> task) {
        auto* heapTask = new std::function<void()>(std::move(task));
        g_idle_add_full(
            G_PRIORITY_DEFAULT,
            [](gpointer data) -> gboolean {
                auto* fn = static_cast<std::function<void()>*>(data);
                (*fn)();
                return G_SOURCE_REMOVE;
            },
            heapTask,
            [](gpointer data) {
                delete static_cast<std::function<void()>*>(data);
            });
    });

    hazkey::frontend::setLogLevelEnabled([](hazkey::frontend::LogLevel level) {
        switch (level) {
            case hazkey::frontend::LogLevel::Debug:
            case hazkey::frontend::LogLevel::Info:
                // シンクは両水準ともG_LOG_DOMAIN上のg_debug()経由で記録する
                // その領域に対する既定ログ書出し側自身の破棄判断を写す:
                // G_MESSAGES_DEBUGとg_log_set_debug_enabled()の双方を対象とし、g_log_get_debug_enabled()単体では足りない
#if GLIB_CHECK_VERSION(2, 68, 0)
                return !g_log_writer_default_would_drop(G_LOG_LEVEL_DEBUG, G_LOG_DOMAIN);
#else
                return true;
#endif
            case hazkey::frontend::LogLevel::Warning:
            case hazkey::frontend::LogLevel::Error:
                return true;
        }
        return true;
    });
    hazkey::frontend::setLogSink(
        [](hazkey::frontend::LogLevel level, const std::string& message) {
            switch (level) {
                case hazkey::frontend::LogLevel::Debug:
                case hazkey::frontend::LogLevel::Info:
                    g_debug("hazkey: %s", message.c_str());
                    break;
                case hazkey::frontend::LogLevel::Warning:
                case hazkey::frontend::LogLevel::Error:
                    g_warning("hazkey: %s", message.c_str());
                    break;
            }
        });

    hazkey::frontend::setServerSpawner([](bool forceRestart) {
        std::vector<std::string> arguments{"hazkey-community-server"};
        if (forceRestart) {
            arguments.emplace_back("-r");
        }

        std::vector<gchar*> argv;
        argv.reserve(arguments.size() + 1);
        for (std::string& argument : arguments) {
            argv.push_back(argument.data());
        }
        argv.push_back(nullptr);

        GError* error = nullptr;
        if (!g_spawn_async(nullptr, argv.data(), nullptr, G_SPAWN_SEARCH_PATH,
                           nullptr, nullptr, nullptr, &error)) {
            g_warning("hazkey: failed to spawn hazkey-community-server: %s", error->message);
            g_error_free(error);
        }
    });
}

}  // namespace hazkey::ibus

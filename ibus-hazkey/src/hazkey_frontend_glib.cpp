#include "hazkey_frontend_glib.h"

#include "hazkey_frontend_hooks.h"

#include <glib.h>

#include <atomic>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace hazkey::ibus {

void installGlibFrontendHooks() {
    // Install once, before any worker task can read these hooks (the engine
    // constructs its frontend right after this call). Re-installing from a
    // second engine instance would race with a running worker.
    static std::atomic<bool> installed{false};
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) {
        return;
    }

    // Main-loop delivery for the worker-thread IME logic.
    //
    // g_idle_add_full() attaches an idle source to the global default main
    // context, which is the context ibus_main() runs. Unlike
    // g_main_context_invoke(), it NEVER runs the callback inline on the
    // calling (worker) thread, and G_PRIORITY_DEFAULT keeps it from being
    // starved by lower-priority idle work. Sources at equal priority are
    // dispatched in attach order, so UI updates keep FIFO order.
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
                // The sink logs both levels through g_debug() on
                // G_LOG_DOMAIN. Mirror the default log writer's own drop
                // decision for that domain: it covers both G_MESSAGES_DEBUG
                // and g_log_set_debug_enabled(), which g_log_get_debug_enabled()
                // alone does not.
#if GLIB_CHECK_VERSION(2, 68, 0)
                return !g_log_writer_default_would_drop(G_LOG_LEVEL_DEBUG,
                                                        G_LOG_DOMAIN);
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

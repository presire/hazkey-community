#include "hazkey_frontend_glib.h"

#include "hazkey_frontend_hooks.h"

#include <glib.h>

#include <string>
#include <vector>

namespace hazkey::ibus {

void installGlibFrontendHooks() {
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
        std::vector<std::string> arguments{"hazkey-server"};
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
            g_warning("hazkey: failed to spawn hazkey-server: %s", error->message);
            g_error_free(error);
        }
    });
}

}  // namespace hazkey::ibus

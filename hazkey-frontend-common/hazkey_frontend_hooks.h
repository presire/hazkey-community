#ifndef HAZKEY_FRONTEND_HOOKS_H
#define HAZKEY_FRONTEND_HOOKS_H

#include <functional>
#include <sstream>
#include <string>

// Frontend injection points for the shared hazkey transport.
//
// The transport in hazkey_server_connector.{h,cpp} is framework-independent.
// The three frontend-specific concerns are injected here instead of being
// compiled into the transport:
//   1. logging  - setLogSink() / setLogLevelEnabled()
//   2. server   - setServerSpawner() (fcitx::startProcess / g_spawn_async)
//   3. preedit  - ComposingTextWithCursor return type (frames build their own)
//
// Defaults are no-ops, so the transport never depends on a frontend process or
// logging API. Each frontend installs its hooks before the first
// HazkeyServerConnector is constructed (the connector may spawn the server
// while connecting).
namespace hazkey::frontend {

enum class LogLevel { Debug, Info, Warning, Error };

using LogSink =
    std::function<void(LogLevel level, const std::string& message)>;

void setLogSink(LogSink sink);

void logMessage(LogLevel level, const std::string& message);

// Optional cheap gate: lets a frontend skip formatting when its own logging
// backend would discard the level anyway (e.g. FCITX_DEBUG() with fcitx log
// level < Debug, g_debug() without G_MESSAGES_DEBUG). When no predicate is
// installed every level is considered enabled, preserving the previous
// behavior of always delivering to the sink.
using LogLevelPredicate = std::function<bool(LogLevel level)>;

void setLogLevelEnabled(LogLevelPredicate predicate);

bool isLogLevelEnabled(LogLevel level);

// Stream helper so transport call sites keep the `<< a << b` style; the
// accumulated line is delivered to logMessage() when the temporary dies.
class LogStream {
   public:
    explicit LogStream(LogLevel level)
        : level_(level), enabled_(isLogLevelEnabled(level)) {}
    ~LogStream() {
        if (enabled_) {
            logMessage(level_, stream_.str());
        }
    }

    LogStream(const LogStream&) = delete;
    LogStream& operator=(const LogStream&) = delete;

    template <typename T>
    LogStream& operator<<(const T& value) {
        if (enabled_) {
            stream_ << value;
        }
        return *this;
    }

   private:
    LogLevel level_;
    bool enabled_;
    std::ostringstream stream_;
};

using ServerSpawner = std::function<void(bool forceRestart)>;

void setServerSpawner(ServerSpawner spawner);

// Spawns (forceRestart=false) or force-restarts (forceRestart=true)
// hazkey-server through the installed spawner. No-op when none is installed.
void spawnServer(bool forceRestart);

// Neutral result of the getHiraganaWithCursor RPC: the composing text split
// around the server-reported cursor. Frontends build their own presentation
// (fcitx::Text with an underline on onCursor; IBus preedit + attribute).
struct ComposingTextWithCursor {
    std::string before;
    std::string onCursor;
    std::string after;

    // Full text (before + onCursor + after). Matches fcitx::Text::toString()
    // for the equivalent underlined text, so callers/tests that only compare
    // the full string need no frontend text type.
    std::string toString() const { return before + onCursor + after; }
};

}  // namespace hazkey::frontend

#endif  // HAZKEY_FRONTEND_HOOKS_H

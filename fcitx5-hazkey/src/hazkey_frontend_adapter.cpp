#include "hazkey_frontend_adapter.h"

#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>

#include <string>
#include <vector>

namespace fcitx {

namespace {

fcitx::LogLevel toFcitxLogLevel(hazkey::frontend::LogLevel level) {
    switch (level) {
        case hazkey::frontend::LogLevel::Debug:
            return fcitx::LogLevel::Debug;
        case hazkey::frontend::LogLevel::Info:
            return fcitx::LogLevel::Info;
        case hazkey::frontend::LogLevel::Warning:
            return fcitx::LogLevel::Warn;
        case hazkey::frontend::LogLevel::Error:
            return fcitx::LogLevel::Error;
    }
    return fcitx::LogLevel::Error;
}

}  // namespace

void installHazkeyFrontendHooks() {
    hazkey::frontend::setLogLevelEnabled([](hazkey::frontend::LogLevel level) {
        return fcitx::Log::defaultCategory().checkLogLevel(toFcitxLogLevel(level));
    });
    hazkey::frontend::setLogSink(
        [](hazkey::frontend::LogLevel level, const std::string& message) {
            switch (level) {
                case hazkey::frontend::LogLevel::Debug:
                    FCITX_DEBUG() << message;
                    break;
                case hazkey::frontend::LogLevel::Info:
                    FCITX_INFO() << message;
                    break;
                case hazkey::frontend::LogLevel::Warning:
                    FCITX_WARN() << message;
                    break;
                case hazkey::frontend::LogLevel::Error:
                    FCITX_ERROR() << message;
                    break;
            }
        });
    hazkey::frontend::setServerSpawner([](bool forceRestart) {
        std::vector<std::string> args;
        args.reserve(2);
        args.push_back("hazkey-server");
        if (forceRestart) {
            args.push_back("-r");
        }
        fcitx::startProcess(args, "/");
    });
}

Text composingTextWithCursorToFcitxText(
    const hazkey::frontend::ComposingTextWithCursor& parts) {
    // Preserve the pre-extraction behavior of the error/empty path: the old
    // connector returned a default-constructed fcitx::Text (zero segments).
    // fcitx::Text::append("") still appends an empty segment (Text::empty()
    // tests the segment count), so an all-empty result must not be
    // materialized into a non-empty Text.
    if (parts.before.empty() && parts.onCursor.empty() && parts.after.empty()) {
        return Text();
    }
    Text text = Text(parts.before);
    text.append(parts.onCursor, TextFormatFlag::Underline);
    text.append(parts.after);
    return text;
}

}  // namespace fcitx

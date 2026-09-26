#include "hazkey_frontend_adapter.h"
#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>
#include <string>
#include <vector>

namespace fcitx {

namespace {

/// 共通transportのログレベルをFcitxログレベルへ対応付ける
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

/// Fcitxロガーとプロセス起動関数を共通transportへ登録する
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
        args.push_back("hazkey-community-server");
        if (forceRestart) {
            args.push_back("-r");
        }
        fcitx::startProcess(args, "/");
    });
}

/// カーソル上文字を下線表示するfcitxテキストを構築する
Text composingTextWithCursorToFcitxText(
    const hazkey::frontend::ComposingTextWithCursor& parts) {
    // エラー時または空の結果では、従来通りセグメント数0のfcitx::Textを返す
    // fcitx::Text::append("")は空文字列でもセグメントを追加して、Text::empty()はセグメント数を判定する
    // そのため、全要素が空の場合は、セグメントを持つテキストとして構築しない
    if (parts.before.empty() && parts.onCursor.empty() && parts.after.empty()) {
        return Text();
    }
    Text text = Text(parts.before);
    text.append(parts.onCursor, TextFormatFlag::Underline);
    text.append(parts.after);
    return text;
}

}  // namespace fcitx

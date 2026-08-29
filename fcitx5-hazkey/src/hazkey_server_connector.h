#ifndef HAZKEY_SERVER_CONNECTOR_H
#define HAZKEY_SERVER_CONNECTOR_H

#include <fcitx-utils/log.h>
#include <fcitx/text.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <map>
#include <optional>
#include <string>
#include <utility>

#include "base.pb.h"
#include "commands.pb.h"
#include "config.pb.h"

class HazkeyServerConnector {
   public:
    // HazkeyServerConnector();
    // ~HazkeyServerConnector();

    HazkeyServerConnector() {
        // kill_existing_hazkey_server();
        connectServer();
        FCITX_DEBUG() << "Connector initialized";
    };

    std::string getSocketPath();

    void connectServer();

    void startHazkeyServer(bool force_restart);

    std::optional<hazkey::ResponseEnvelope> transact(
        const hazkey::RequestEnvelope& send_data);

    std::string getComposingText(
        hazkey::commands::GetComposingString::CharType type,
        std::string currentPreedit);

    fcitx::Text getComposingHiraganaWithCursor();

    void inputChar(std::string text);

    void shiftKeyEvent(bool isRelease);

    bool currentInputModeIsDirect();

    void deleteLeft();

    void deleteRight();

    void moveCursor(int offset);

    struct ClauseBoundaryResult {
        hazkey::commands::CandidatesResult candidates;
        std::string hiragana;
    };

    std::optional<ClauseBoundaryResult> adjustClauseBoundary(int offset);

    void setContext(std::string context, int anchor);

    std::optional<hazkey::config::CurrentConfig> getServerConfig();
    bool setServerConfig(const hazkey::config::CurrentConfig& config);

    void newComposingText();

    void completePrefix(int index);

    void saveLearningData();

    struct CandidateData {
        std::string candidateText;
        std::string subHiragana;
    };

    hazkey::commands::CandidatesResult getCandidates(bool isSuggest);

    // Shared across all input contexts: remembers the last non-DISABLED
    // auto-convert mode so the hotkey can restore it on toggle-on.
    hazkey::config::Profile_AutoConvertMode& rememberedOnMode() {
        return rememberedOnMode_;
    }

   private:
    bool retryConnect();
    bool isHazkeyServerRunning();
    bool requestSuccess(hazkey::ResponseEnvelope);

    // Read-through cache for the per-key hot-path reads. Cleared by every
    // state-mutating RPC, by the non-suggest candidate request (the server
    // inserts a composition separator there, which mutates read state), and
    // whenever the connection is (re)established (server restart loses all
    // composition state). Read methods serve same-epoch results without a
    // round trip and only cache SUCCESS responses.
    void invalidateCache();

    struct TextWithCursorParts {
        std::string beforeCursor;
        std::string onCursor;
        std::string afterCursor;
    };
    int sock_ = -1;
    std::string socket_path_;
    hazkey::config::Profile_AutoConvertMode rememberedOnMode_ =
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
    std::optional<TextWithCursorParts> cachedHiraganaWithCursor_;
    // Keyed by (CharType, client preedit): alphabet conversions depend on
    // the preedit (cycleAlphabetCase); the other types only on server state,
    // which stays constant until the next state-mutating RPC.
    std::map<std::pair<int, std::string>, std::string> cachedComposingText_;
    std::optional<hazkey::commands::CandidatesResult> cachedCandidatesSuggest_;
    std::optional<hazkey::commands::CandidatesResult> cachedCandidatesFull_;
    std::optional<bool> cachedInputModeDirect_;
};

#endif  // HAZKEY_SERVER_CONNECTOR_H

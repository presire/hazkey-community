#ifndef HAZKEY_SERVER_CONNECTOR_H
#define HAZKEY_SERVER_CONNECTOR_H

#include <fcitx-utils/log.h>
#include <fcitx/text.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <chrono>
#include <functional>
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

    // ---- Test-only hooks (never set outside test binaries) -------------
    // hazkey-ime-cpu-latency todo 2: these exist solely so
    // hazkey_client_transact_safety_test can exercise the timeout/
    // reconnect/force-restart paths deterministically and quickly, without
    // waiting on the real 10-second read ceiling or spawning a real
    // hazkey-server process. Production code never calls these setters, so
    // default (disabled) values keep production behavior byte-identical.

    // Overrides the client's response-read timeout (production default:
    // 10 seconds -- see kProductionReadTimeoutSeconds in
    // hazkey_server_connector.cpp). Pass 0 (or any non-positive value) to
    // restore the production default.
    static void setTestReadTimeoutSeconds(int seconds) {
        testReadTimeoutSeconds_ = seconds;
    }

    // Overrides the "recently responsive" contention window used by
    // connectServer() to decide whether a run of connect failures should
    // still trigger a forced server restart (production default: see
    // kForceRestartContentionWindowMs in hazkey_server_connector.cpp).
    // Pass a negative value to restore the production default.
    static void setTestForceRestartWindowMs(long milliseconds) {
        testForceRestartWindowMs_ = milliseconds;
    }

    // Replaces the real fcitx::startProcess()-based server spawn in
    // startHazkeyServer() with a test observer/no-op. Pass an empty
    // std::function (or nullptr) to restore the real implementation.
    static void setTestStartServerHook(std::function<void(bool)> hook) {
        testStartServerHook_ = std::move(hook);
    }

    // Restores every test hook above to its "use production behavior"
    // default in one call.
    static void clearTestHooks() {
        testReadTimeoutSeconds_ = 0;
        testForceRestartWindowMs_ = -1;
        testStartServerHook_ = nullptr;
    }
    // ---------------------------------------------------------------------

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
    //
    // Note: hazkey-settings opening a connection while fcitx5 is already
    // connected causes the server (socketManager.swift's
    // handleNewConnection) to evict fcitx5's existing client. That eviction
    // surfaces here as an ordinary write/read failure and flows through the
    // same invalidate-and-reconnect path as a server restart. This is a
    // known, accepted interaction (hazkey-ime-cpu-latency plan todo 2) --
    // not treated as a blocking bug, since the reconnect path already
    // recovers correctly.
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

    // Updated in transact() at the end of every full request/response round
    // trip that receives and parses a well-formed ResponseEnvelope
    // (independent of that RPC's application-level status field -- a
    // FAILED business response still proves the transport/server is alive).
    // connectServer() uses this to distinguish "server never responded"
    // (force restart is warranted) from "server answered moments ago and is
    // merely slow to accept under CPU contention" (force restart is
    // suppressed -- see kForceRestartContentionWindowMs in
    // hazkey_server_connector.cpp). time_point::min() means "never
    // succeeded since this connector was constructed".
    std::chrono::steady_clock::time_point lastSuccessfulTransaction_ =
        std::chrono::steady_clock::time_point::min();

    // See setTestReadTimeoutSeconds()/setTestForceRestartWindowMs()/
    // setTestStartServerHook() above.
    static inline int testReadTimeoutSeconds_ = 0;
    static inline long testForceRestartWindowMs_ = -1;
    static inline std::function<void(bool)> testStartServerHook_;
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

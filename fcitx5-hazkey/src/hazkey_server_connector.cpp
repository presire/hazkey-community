#include "hazkey_server_connector.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/textformatflags.h>
#include <fcitx/text.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "base.pb.h"
#include "commands.pb.h"
#include "config.pb.h"

static std::mutex transact_mutex;

namespace {

const char* requestType(const hazkey::RequestEnvelope& request) {
    switch (request.payload_case()) {
        case hazkey::RequestEnvelope::kSetContext: return "set_context";
        case hazkey::RequestEnvelope::kNewComposingText: return "new_composing_text";
        case hazkey::RequestEnvelope::kInputChar: return "input_char";
        case hazkey::RequestEnvelope::kModifierEvent: return "modifier_event";
        case hazkey::RequestEnvelope::kDeleteLeft: return "delete_left";
        case hazkey::RequestEnvelope::kDeleteRight: return "delete_right";
        case hazkey::RequestEnvelope::kPrefixComplete: return "prefix_complete";
        case hazkey::RequestEnvelope::kMoveCursor: return "move_cursor";
        case hazkey::RequestEnvelope::kAdjustClauseBoundary: return "adjust_clause_boundary";
        case hazkey::RequestEnvelope::kGetHiraganaWithCursor: return "get_hiragana_with_cursor";
        case hazkey::RequestEnvelope::kGetComposingString: return "get_composing_string";
        case hazkey::RequestEnvelope::kGetCandidates: return "get_candidates";
        case hazkey::RequestEnvelope::kGetCurrentInputMode: return "get_current_input_mode";
        case hazkey::RequestEnvelope::kSaveLearningData: return "save_learning_data";
        case hazkey::RequestEnvelope::kGetConfig: return "get_config";
        case hazkey::RequestEnvelope::kSetConfig: return "set_config";
        case hazkey::RequestEnvelope::kClearAllHistory: return "clear_all_history";
        case hazkey::RequestEnvelope::kReloadZenzaiModel: return "reload_zenzai_model";
        case hazkey::RequestEnvelope::kGetDefaultProfile: return "get_default_profile";
        case hazkey::RequestEnvelope::PAYLOAD_NOT_SET: return "none";
    }
    return "none";
}

class ClientPerfMeasurement {
   public:
    explicit ClientPerfMeasurement(const hazkey::RequestEnvelope& request) {
        const char* path = std::getenv("HAZKEY_PERF_EVIDENCE");
        if (path == nullptr || path[0] == '\0') {
            return;
        }
        path_ = path;
        type_ = requestType(request);
        startedAt_ = std::chrono::steady_clock::now();
    }

    ~ClientPerfMeasurement() {
        if (path_.empty()) {
            return;
        }
        const auto elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - startedAt_);
        std::ofstream output(path_, std::ios::app);
        output << "{\"type\":\"" << type_ << "\",\"total_ms\":"
               << elapsed.count() << "}\n";
    }

   private:
    std::chrono::steady_clock::time_point startedAt_;
    std::string path_;
    std::string type_;
};

}  // namespace

std::string HazkeyServerConnector::getSocketPath() {
    const char* xdg_runtime_dir = std::getenv("XDG_RUNTIME_DIR");
    uid_t uid = getuid();
    std::string sockname = "hazkey-server." + std::to_string(uid) + ".sock";
    if (xdg_runtime_dir && xdg_runtime_dir[0] != '\0') {
        return std::string(xdg_runtime_dir) + "/" + sockname;
    } else {
        return "/tmp/" + sockname;
    }
}

void HazkeyServerConnector::startHazkeyServer(bool force_restart) {
    // Test-only hook (see setTestStartServerHook() in the header): lets
    // tests observe/intercept spawn decisions without launching a real
    // hazkey-server process. Unset (the production default) falls through
    // to the real fcitx::startProcess() call below.
    if (testStartServerHook_) {
        testStartServerHook_(force_restart);
        return;
    }
    std::vector<std::string> args;
    args.reserve(2);
    args.push_back("hazkey-server");
    if (force_restart) {
        args.push_back("-r");
    }
    fcitx::startProcess(args, "/");
}

bool writeAll(int fd, const void* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, (const char*)data + sent, len - sent);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(fd, &wfds);
                timeval tv = {2, 0};  // 2sec write timeout ceiling
                int r = select(fd + 1, NULL, &wfds, NULL, &tv);
                if (r <= 0) {
                    FCITX_ERROR() << "write timeout";
                    return false;
                }
                continue;
            }
            return false;
        }
        sent += n;
    }
    return true;
}

// Client-side read ceiling for a single server response. `timeoutSeconds`
// is the production 10-second value in every real code path (see
// HazkeyServerConnector::transact()'s kProductionReadTimeoutSeconds); the
// comment here used to (incorrectly) say "2sec" even though the value was
// always 10. Decision (hazkey-ime-cpu-latency plan todo 2): keep the
// 10-second ceiling itself unchanged -- it is the value every prior session
// documented, and it is the hard limit any future server-side processing
// deadline (e.g. HAZKEY_ZENZAI_DEADLINE_MS) must stay below, since a
// response arriving after this point is indistinguishable from a
// stalled/dead server. `timeoutSeconds` is overridable ONLY through
// HazkeyServerConnector::setTestReadTimeoutSeconds(), used exclusively by
// hazkey_client_transact_safety_test; production code always passes 10.
bool readAll(int fd, void* data, size_t len, int timeoutSeconds) {
    size_t recved = 0;
    while (recved < len) {
        ssize_t n = read(fd, (char*)data + recved, len - recved);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fd_set rfds;
                FD_ZERO(&rfds);
                FD_SET(fd, &rfds);
                timeval tv = {timeoutSeconds, 0};  // 10sec read timeout ceiling
                int r = select(fd + 1, &rfds, NULL, NULL, &tv);
                if (r <= 0) {
                    FCITX_ERROR() << "read timeout";
                    return false;
                }
                continue;
            }
            return false;
        }
        if (n == 0) return false;  // closed
        recved += n;
    }
    return true;
}

void HazkeyServerConnector::connectServer() {
    std::string socket_path = getSocketPath();

    // try restarting server only 1 time
    // on 1st attempt (minus 1)
    constexpr int ATTEMPT_TRY_START = 0;
    // on 4th attempt (minus 1)
    constexpr int ATTEMPT_TRY_START_FORCE = 3;

    constexpr int MAX_RETRIES = 8;
    constexpr int RETRY_INTERVAL_MS = 150;

    int attempt;
    for (attempt = 0; attempt < MAX_RETRIES; ++attempt) {
        sock_ = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock_ < 0) {
            FCITX_ERROR() << "Failed to create socket";
            std::this_thread::sleep_for(
                std::chrono::milliseconds(RETRY_INTERVAL_MS));
            continue;
        }
        int fcntlRes =
            fcntl(sock_, F_SETFL, fcntl(sock_, F_GETFL, 0) | O_NONBLOCK);
        if (fcntlRes != 0) {
            FCITX_ERROR() << "fcntl() failed";
            close(sock_);
            sock_ = -1;
            std::this_thread::sleep_for(
                std::chrono::milliseconds(RETRY_INTERVAL_MS));
            continue;
        }

        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, socket_path.c_str(), sizeof(addr.sun_path) - 1);

        int ret = connect(sock_, (sockaddr*)&addr, sizeof(addr));
        if (ret == 0) {
            // Connected
            return;
        }
        if (errno == EINPROGRESS) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(sock_, &wfds);
            timeval tv = {2, 0};
            int sel = select(sock_ + 1, NULL, &wfds, NULL, &tv);
            if (sel > 0 && FD_ISSET(sock_, &wfds)) {
                int so_error = 0;
                socklen_t len = sizeof(so_error);
                getsockopt(sock_, SOL_SOCKET, SO_ERROR, &so_error, &len);
                if (so_error == 0) {
                    // Connected
                    return;
                }
            }
        }
        FCITX_INFO() << "Failed to connect hazkey-server, retry "
                     << (attempt + 1);
        close(sock_);
        sock_ = -1;
        if (attempt == ATTEMPT_TRY_START) {
            // A dead server still needs exactly one non-forced spawn
            // attempt; unchanged by the hardening below.
            startHazkeyServer(false);
        } else if (attempt == ATTEMPT_TRY_START_FORCE) {
            // Hardening (hazkey-ime-cpu-latency plan todo 2): ordinary
            // CPU-load-induced slow accepts on a server that answered us
            // moments ago must not be mistaken for a wedged server. Only
            // force-restart if the server has never responded, or hasn't
            // responded in a while.
            constexpr long kForceRestartContentionWindowMs = 5000;
            const long contentionWindowMs =
                testForceRestartWindowMs_ >= 0
                    ? testForceRestartWindowMs_
                    : kForceRestartContentionWindowMs;
            const auto now = std::chrono::steady_clock::now();
            const bool recentlyResponsive =
                lastSuccessfulTransaction_ !=
                    std::chrono::steady_clock::time_point::min() &&
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    now - lastSuccessfulTransaction_)
                        .count() < contentionWindowMs;
            if (recentlyResponsive) {
                FCITX_INFO()
                    << "Skipping force-restart: hazkey-server completed a "
                       "successful transaction within the last "
                    << contentionWindowMs
                    << "ms; treating this as CPU contention rather than a "
                       "wedged server.";
            } else {
                startHazkeyServer(true);
            }
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(RETRY_INTERVAL_MS));
    }
    FCITX_INFO() << "Failed to connect hazkey-server after " << MAX_RETRIES
                 << " attempts";
}

void HazkeyServerConnector::invalidateCache() {
    cachedHiraganaWithCursor_.reset();
    cachedComposingText_.clear();
    cachedCandidatesSuggest_.reset();
    cachedCandidatesFull_.reset();
    cachedInputModeDirect_.reset();
}

std::optional<hazkey::ResponseEnvelope> HazkeyServerConnector::transact(
    const hazkey::RequestEnvelope& send_data) {
    ClientPerfMeasurement perfMeasurement(send_data);
    std::lock_guard<std::mutex> lock(transact_mutex);

    if (sock_ == -1) {
        FCITX_INFO() << "Socket not connected, attempting to connect...";
        connectServer();
        if (sock_ == -1) {
            FCITX_ERROR() << "Failed to establish connection to hazkey-server";
            return std::nullopt;
        }
        // The server may have been (re)started while we were disconnected:
        // its composition state is gone, so cached reads must not be served.
        invalidateCache();
    }

    std::string msg;
    if (!send_data.SerializeToString(&msg)) {
        FCITX_ERROR() << "Failed to serialize protobuf message.";
        return std::nullopt;
    }

    FCITX_DEBUG() << "Sending message of size: " << msg.size();

    // write length
    uint32_t writeLen = htonl(msg.size());
    if (!writeAll(sock_, &writeLen, 4)) {
        FCITX_INFO()
            << "Failed to communicate with server while writing data length. "
               "reconnecting to hazkey-server...";
        close(sock_);
        sock_ = -1;
        connectServer();
        // Reconnected (possibly to a restarted server): drop cached reads.
        invalidateCache();
        return std::nullopt;
    }

    // write data
    if (!writeAll(sock_, msg.c_str(), msg.size())) {
        FCITX_INFO() << "Failed to communicate with server while writing data. "
                        "reconnecting to hazkey-server...";
        close(sock_);
        sock_ = -1;
        connectServer();
        // Reconnected (possibly to a restarted server): drop cached reads.
        invalidateCache();
        return std::nullopt;
    }

    FCITX_DEBUG() << "Successfully wrote data to server";

    // Production read-timeout ceiling is 10 seconds; only
    // hazkey_client_transact_safety_test overrides it, via
    // setTestReadTimeoutSeconds(), to exercise this path quickly.
    constexpr int kProductionReadTimeoutSeconds = 10;
    const int readTimeoutSeconds = testReadTimeoutSeconds_ > 0
                                        ? testReadTimeoutSeconds_
                                        : kProductionReadTimeoutSeconds;

    // read response length
    uint32_t readLenBuf;
    if (!readAll(sock_, &readLenBuf, 4, readTimeoutSeconds)) {
        FCITX_ERROR() << "Failed to read buffer length.";
        close(sock_);
        sock_ = -1;
        return std::nullopt;
    }

    uint32_t readLen = ntohl(readLenBuf);
    FCITX_DEBUG() << "Server response size: " << readLen;

    if (readLen > 2 * 1024 * 1024) {  // 2MB limit
        FCITX_ERROR() << "Response size too large: " << readLen;
        close(sock_);
        sock_ = -1;
        return std::nullopt;
    }

    std::vector<char> buf(readLen);
    if (!readAll(sock_, buf.data(), readLen, readTimeoutSeconds)) {
        FCITX_ERROR() << "Failed to read response body.";
        close(sock_);
        sock_ = -1;
        return std::nullopt;
    }

    hazkey::ResponseEnvelope resp;
    if (!resp.ParseFromArray(buf.data(), readLen)) {
        FCITX_ERROR() << "Failed to parse received data\n";
        return std::nullopt;
    }

    // A full request/response round trip completed and parsed: the
    // transport and server are demonstrably alive right now, regardless of
    // this particular RPC's application-level status. connectServer() uses
    // this timestamp to avoid mistaking an ordinary CPU-contention slow
    // accept on a recently-responsive server for a wedged one.
    lastSuccessfulTransaction_ = std::chrono::steady_clock::now();

    FCITX_DEBUG() << "Successfully received and parsed response";
    return resp;
}

std::string HazkeyServerConnector::getComposingText(
    hazkey::commands::GetComposingString::CharType type,
    std::string currentPreedit) {
    const auto cacheKey =
        std::make_pair(static_cast<int>(type), currentPreedit);
    if (auto it = cachedComposingText_.find(cacheKey);
        it != cachedComposingText_.end()) {
        return it->second;
    }
    hazkey::RequestEnvelope request;
    auto props = request.mutable_get_composing_string();
    props->set_char_type(type);
    props->set_current_preedit(currentPreedit);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting getComposingText().";
        return "";
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "getComposingText: " << "Server returned an error: "
                      << responseVal.error_message();
        return "";
    }
    // old protobuf doesn't have has_text() method.
    // if (!responseVal.has_text()) {
    //     FCITX_ERROR() << "getComposingText: "
    //                   << "Server returned unexpected response";
    //     return "";
    // }
    cachedComposingText_[cacheKey] = responseVal.text();
    return responseVal.text();
}

fcitx::Text HazkeyServerConnector::getComposingHiraganaWithCursor() {
    if (cachedHiraganaWithCursor_.has_value()) {
        const auto& parts = cachedHiraganaWithCursor_.value();
        fcitx::Text text = fcitx::Text(parts.beforeCursor);
        text.append(parts.onCursor, fcitx::TextFormatFlag::Underline);
        text.append(parts.afterCursor);
        return text;
    }
    hazkey::RequestEnvelope request;
    request.mutable_get_hiragana_with_cursor();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR()
            << "Error while transacting getComposingHiraganaWithCursor().";
        return fcitx::Text();
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "getHiraganaWithCursor: "
                      << "Server returned an error: "
                      << responseVal.error_message();
        return fcitx::Text();
    }
    if (!responseVal.has_text_with_cursor()) {
        FCITX_ERROR() << "getHiraganaWithCursor: "
                      << "Server returned unexpected response";
        return fcitx::Text();
    }
    cachedHiraganaWithCursor_ = TextWithCursorParts{
        responseVal.text_with_cursor().beforecursosr(),
        responseVal.text_with_cursor().oncursor(),
        responseVal.text_with_cursor().aftercursor()};
    fcitx::Text text =
        fcitx::Text(responseVal.text_with_cursor().beforecursosr());
    text.append(responseVal.text_with_cursor().oncursor(),
                fcitx::TextFormatFlag::Underline);
    text.append(responseVal.text_with_cursor().aftercursor());
    return text;
}

void HazkeyServerConnector::inputChar(std::string text) {
    // State-mutating RPC: any cached read is stale from here on.
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_input_char();
    props->set_text(text);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting inputChar().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "inputChar: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

void HazkeyServerConnector::shiftKeyEvent(bool isRelease) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_modifier_event();
    props->set_event_type(
        isRelease ? hazkey::commands::ModifierEvent_EventType_RELEASE
                  : hazkey::commands::ModifierEvent_EventType_PRESS);
    props->set_mod_type(hazkey::commands::ModifierEvent_ModifierType_SHIFT);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting shiftKeyEvent().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "shiftKeyEvent: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

bool HazkeyServerConnector::currentInputModeIsDirect() {
    if (cachedInputModeDirect_.has_value()) {
        return cachedInputModeDirect_.value();
    }
    hazkey::RequestEnvelope request;
    auto _ = request.mutable_get_current_input_mode();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting currentInputModeIsDirect().";
        return false;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "currentInputModeIsDirect: "
                      << "Server returned an error: "
                      << responseVal.error_message();
        return false;
    }
    cachedInputModeDirect_ =
        responseVal.current_input_mode_info().input_mode() ==
        hazkey::commands::CurrentInputModeInfo::InputMode::
            CurrentInputModeInfo_InputMode_DIRECT;
    return cachedInputModeDirect_.value();
}

void HazkeyServerConnector::deleteLeft() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_delete_left();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting deleteLeft().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "deleteLeft: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

void HazkeyServerConnector::deleteRight() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_delete_right();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting deleteRight().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "deleteRight: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

void HazkeyServerConnector::moveCursor(int offset) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_move_cursor();
    props->set_offset(offset);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting moveCursor().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "moveCursor:" << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

std::optional<HazkeyServerConnector::ClauseBoundaryResult>
HazkeyServerConnector::adjustClauseBoundary(int offset) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_adjust_clause_boundary();
    props->set_offset(offset);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting adjustClauseBoundary().";
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "adjustClauseBoundary: "
                      << "Server returned an error: "
                      << responseVal.error_message();
        return std::nullopt;
    }
    if (!responseVal.has_clause_boundary_result()) {
        FCITX_ERROR() << "adjustClauseBoundary: "
                      << "Server returned unexpected response";
        return std::nullopt;
    }

    ClauseBoundaryResult result;
    result.candidates = responseVal.clause_boundary_result().candidates();
    result.hiragana = responseVal.clause_boundary_result().hiragana();
    return result;
}

void HazkeyServerConnector::setContext(std::string context, int anchor) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_set_context();
    props->set_context(context);
    props->set_anchor(anchor);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting setContext().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "setContext:" << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

void HazkeyServerConnector::newComposingText() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_new_composing_text();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR()
            << "Error while transacting createComposingTextInstance().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "createComposingTextInstance:"
                      << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

void HazkeyServerConnector::completePrefix(int index) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_prefix_complete();
    props->set_index(index);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting completePrefix().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "completePrefix: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

void HazkeyServerConnector::saveLearningData() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_save_learning_data();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting saveLearningData().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "saveLearningData:"
                      << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

std::optional<hazkey::config::CurrentConfig> HazkeyServerConnector::getServerConfig() {
    hazkey::RequestEnvelope request;
    request.mutable_get_config();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting getServerConfig().";
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "getServerConfig: " << "Server returned an error: "
                      << responseVal.error_message();
        return std::nullopt;
    }
    return responseVal.current_config();
}

bool HazkeyServerConnector::setServerConfig(
    const hazkey::config::CurrentConfig& config) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto* sc = request.mutable_set_config();
    *sc->mutable_profiles() = config.profiles();
    *sc->mutable_file_hashes() = config.file_hashes();
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting setServerConfig().";
        return false;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "setServerConfig: " << "Server returned an error: "
                      << responseVal.error_message();
        return false;
    }
    return true;
}

hazkey::commands::CandidatesResult HazkeyServerConnector::getCandidates(
    bool isSuggestMode) {
    // The non-suggest request makes the server insert a composition
    // separator, which mutates the state all other reads depend on, so it
    // must invalidate cached reads before it executes.
    if (!isSuggestMode) {
        invalidateCache();
    }
    auto& cacheSlot =
        isSuggestMode ? cachedCandidatesSuggest_ : cachedCandidatesFull_;
    if (cacheSlot.has_value()) {
        return cacheSlot.value();
    }
    hazkey::RequestEnvelope request;
    auto props = request.mutable_get_candidates();
    props->set_is_suggest(isSuggestMode);
    auto response = transact(request);
    if (response == std::nullopt) {
        FCITX_ERROR() << "Error while transacting getCandidates().";
        std::vector<CandidateData> empty_vec;
        return hazkey::commands::CandidatesResult();
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        FCITX_ERROR() << "getCandidates: " << "Server returned an error: "
                      << responseVal.error_message();
        std::vector<CandidateData> empty_vec;
        return hazkey::commands::CandidatesResult();
    }
    // TODO: Error handling when response has no candidate
    // if (responseVal..has_candidates()) {
    //     FCITX_ERROR() << "getCandidates: "
    //                   << "Server returned unexpected response";
    //     std::vector<CandidateData> empty_vec;
    //     return hazkey::commands::CandidatesResult();
    // }
    cacheSlot = responseVal.candidates();
    return responseVal.candidates();
}

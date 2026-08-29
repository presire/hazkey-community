// Cache invalidation coverage for HazkeyServerConnector (todo 3 perf work).
//
// Drives the REAL HazkeyServerConnector against an in-process fake UNIX
// socket server (same harness pattern as hazkey_client_rpc_probe_test) and
// verifies, for every invalidation event (reset, focus/context change,
// input-mode transition, live-convert toggle, commit, candidate change —
// all realized through the connector's state-mutating RPCs):
//   1. no stale auxiliary/preedit value is served after the event, and
//   2. state-mutating RPCs always pass through to the server (never elided).
//
// Response values are stamped with a per-arrival sequence number, so a stale
// cache serve is detectable by value, not only by request count.

#include <arpa/inet.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fcitx/text.h>

#include "base.pb.h"
#include "commands.pb.h"
#include "config.pb.h"
#include "hazkey_server_connector.h"

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::cerr << "CHECK failed at line " << __LINE__ << ": " #cond   \
                      << std::endl;                                          \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

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

bool readAll(int fd, void* data, size_t size) {
    auto* bytes = static_cast<char*>(data);
    size_t offset = 0;
    while (offset < size) {
        const ssize_t count = read(fd, bytes + offset, size - offset);
        if (count <= 0) {
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

bool writeAll(int fd, const void* data, size_t size) {
    const auto* bytes = static_cast<const char*>(data);
    size_t offset = 0;
    while (offset < size) {
        const ssize_t count = write(fd, bytes + offset, size - offset);
        if (count <= 0) {
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

// Fake in-process server. Accepts sequential clients (so the reconnect
// scenario works), counts requests per type, and stamps every response with
// a globally unique arrival sequence so stale serves are detectable by value.
class FakeServer {
   public:
    explicit FakeServer(const std::string& path) : path_(path) {
        listenFd_ = socket(AF_UNIX, SOCK_STREAM, 0);
        CHECK(listenFd_ >= 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
        CHECK(bind(listenFd_, reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) == 0);
        CHECK(listen(listenFd_, 4) == 0);
        thread_ = std::thread([this] { serveLoop(); });
    }

    ~FakeServer() {
        stop_ = true;
        shutdown(listenFd_, SHUT_RDWR);
        close(listenFd_);
        shutdown(clientFd_, SHUT_RDWR);
        if (thread_.joinable()) {
            thread_.join();
        }
        unlink(path_.c_str());
    }

    void resetCounts() {
        std::lock_guard<std::mutex> lock(mutex_);
        counts_.clear();
    }

    std::map<std::string, int> counts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return counts_;
    }

    // Close the active client connection so the connector's next transact
    // fails and must reconnect (reconnect must invalidate the read cache).
    void dropClient() { shutdown(clientFd_, SHUT_RDWR); }

    void failNextGetCandidates() { failGetCandidates_++; }

   private:
    void serveLoop() {
        while (!stop_) {
            const int clientFd = accept(listenFd_, nullptr, nullptr);
            if (clientFd < 0) {
                if (stop_) break;
                continue;
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                clientFd_ = clientFd;
            }
            timeval timeout = {5, 0};
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout));
            serveClient(clientFd);
            close(clientFd);
        }
    }

    void serveClient(int fd) {
        while (true) {
            uint32_t networkLength = 0;
            if (!readAll(fd, &networkLength, sizeof(networkLength))) {
                break;
            }
            const uint32_t length = ntohl(networkLength);
            std::string wire(length, '\0');
            if (!readAll(fd, wire.data(), wire.size())) {
                break;
            }
            hazkey::RequestEnvelope request;
            CHECK(request.ParseFromString(wire));
            hazkey::ResponseEnvelope response;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                const std::string type = requestType(request);
                ++counts_[type];  // count arrivals regardless of injected status
                if (type == "get_candidates" && failGetCandidates_ > 0) {
                    failGetCandidates_--;
                    response.set_status(hazkey::FAILED);
                    response.set_error_message("injected failure");
                } else {
                    ++arrivalSeq_;
                    buildResponse(request, std::to_string(arrivalSeq_),
                                  &response);
                }
            }
            std::string responseWire;
            CHECK(response.SerializeToString(&responseWire));
            const uint32_t responseLength = htonl(responseWire.size());
            if (!writeAll(fd, &responseLength, sizeof(responseLength)) ||
                !writeAll(fd, responseWire.data(), responseWire.size())) {
                break;
            }
        }
    }

    static void buildResponse(const hazkey::RequestEnvelope& request,
                              const std::string& stamp,
                              hazkey::ResponseEnvelope* response) {
        response->set_status(hazkey::SUCCESS);
        switch (request.payload_case()) {
            case hazkey::RequestEnvelope::kGetHiraganaWithCursor: {
                auto* text = response->mutable_text_with_cursor();
                text->set_beforecursosr("B" + stamp);
                text->set_oncursor("|");
                text->set_aftercursor("A" + stamp);
                break;
            }
            case hazkey::RequestEnvelope::kGetComposingString:
                response->set_text("S" + stamp);
                break;
            case hazkey::RequestEnvelope::kGetCandidates: {
                auto* candidates = response->mutable_candidates();
                candidates->add_candidates()->set_text("C" + stamp);
                candidates->set_live_text("L" + stamp);
                candidates->set_live_text_index(0);
                candidates->set_page_size(1);
                break;
            }
            case hazkey::RequestEnvelope::kAdjustClauseBoundary: {
                auto* boundary = response->mutable_clause_boundary_result();
                boundary->set_hiragana("H" + stamp);
                auto* candidates = boundary->mutable_candidates();
                candidates->add_candidates()->set_text("C" + stamp);
                candidates->set_live_text("L" + stamp);
                candidates->set_page_size(1);
                break;
            }
            case hazkey::RequestEnvelope::kGetCurrentInputMode:
                response->mutable_current_input_mode_info()->set_input_mode(
                    hazkey::commands::CurrentInputModeInfo::InputMode::
                        CurrentInputModeInfo_InputMode_DIRECT);
                break;
            default:
                break;  // plain SUCCESS for mutations and other reads
        }
    }

    int listenFd_ = -1;
    int clientFd_ = -1;
    std::string path_;
    std::thread thread_;
    mutable std::mutex mutex_;
    std::map<std::string, int> counts_;
    long arrivalSeq_ = 0;
    int failGetCandidates_ = 0;
    std::atomic<bool> stop_{false};
};

int countOf(const std::map<std::string, int>& counts, const std::string& type) {
    auto it = counts.find(type);
    return it == counts.end() ? 0 : it->second;
}

void primeComposition(HazkeyServerConnector& connector) {
    connector.newComposingText();
    connector.inputChar("あ");
}

// Read methods serve same-epoch repeats from the cache: one round trip per
// type, identical values.
void readThroughHits(FakeServer& server, HazkeyServerConnector& connector) {
    server.resetCounts();
    primeComposition(connector);
    const auto h1 = connector.getComposingHiraganaWithCursor();
    const auto h2 = connector.getComposingHiraganaWithCursor();
    auto counts = server.counts();
    CHECK(countOf(counts, "get_hiragana_with_cursor") == 1);
    CHECK(!h1.toString().empty());
    CHECK(h1.toString() == h2.toString());
    const auto c1 = connector.getCandidates(true);
    const auto c2 = connector.getCandidates(true);
    counts = server.counts();
    CHECK(countOf(counts, "get_candidates") == 1);
    CHECK(!c1.live_text().empty());
    CHECK(c1.live_text() == c2.live_text());
    const auto s1 = connector.getComposingText(
        hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
    const auto s2 = connector.getComposingText(
        hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
    counts = server.counts();
    CHECK(countOf(counts, "get_composing_string") == 1);
    CHECK(!s1.empty());
    CHECK(s1 == s2);
    CHECK(connector.currentInputModeIsDirect());
    CHECK(connector.currentInputModeIsDirect());
    counts = server.counts();
    CHECK(countOf(counts, "get_current_input_mode") == 1);
    std::cout << "[PASS] read-through hits served from cache" << std::endl;
}

// Every state-mutating RPC (which is how reset, focus/context change,
// input-mode transition, live-convert toggle, commit, and candidate change
// reach the server) must (a) always pass through and (b) invalidate the read
// cache so no stale auxiliary/preedit value is served afterwards.
void mutationInvalidates(FakeServer& server, HazkeyServerConnector& connector) {
    struct MutationCase {
        const char* name;
        std::function<void(HazkeyServerConnector&)> apply;
        const char* rpcType;
    };
    const std::vector<MutationCase> cases = {
        {"inputChar (candidate change)",
         [](HazkeyServerConnector& c) { c.inputChar("い"); }, "input_char"},
        {"deleteLeft",
         [](HazkeyServerConnector& c) { c.deleteLeft(); }, "delete_left"},
        {"deleteRight",
         [](HazkeyServerConnector& c) { c.deleteRight(); }, "delete_right"},
        {"moveCursor (candidate change)",
         [](HazkeyServerConnector& c) { c.moveCursor(1); }, "move_cursor"},
        {"adjustClauseBoundary (candidate change)",
         [](HazkeyServerConnector& c) { c.adjustClauseBoundary(1); },
         "adjust_clause_boundary"},
        {"newComposingText (reset / focus change)",
         [](HazkeyServerConnector& c) { c.newComposingText(); },
         "new_composing_text"},
        {"completePrefix (commit)",
         [](HazkeyServerConnector& c) { c.completePrefix(0); },
         "prefix_complete"},
        {"setContext (context change)",
         [](HazkeyServerConnector& c) { c.setContext("ctx", 0); },
         "set_context"},
        {"shiftKeyEvent (input-mode transition)",
         [](HazkeyServerConnector& c) { c.shiftKeyEvent(false); },
         "modifier_event"},
        {"setServerConfig (live-convert toggle)",
         [](HazkeyServerConnector& c) {
             hazkey::config::CurrentConfig config;
             c.setServerConfig(config);
         },
         "set_config"},
    };
    for (const auto& mutationCase : cases) {
        server.resetCounts();
        primeComposition(connector);
        server.resetCounts();  // count only this case's traffic
        const auto h1 = connector.getComposingHiraganaWithCursor();
        CHECK(connector.getComposingHiraganaWithCursor().toString() ==
              h1.toString());  // warmed from cache
        auto counts = server.counts();
        CHECK(countOf(counts, "get_hiragana_with_cursor") == 1);
        mutationCase.apply(connector);
        counts = server.counts();
        CHECK(countOf(counts, mutationCase.rpcType) == 1);
        const auto h2 = connector.getComposingHiraganaWithCursor();
        counts = server.counts();
        CHECK(countOf(counts, "get_hiragana_with_cursor") == 2);
        CHECK(h2.toString() != h1.toString());  // fresh value, not stale
        const auto candidates = connector.getCandidates(true);
        counts = server.counts();
        CHECK(countOf(counts, "get_candidates") == 1);
        CHECK(!candidates.live_text().empty());
        const auto composing = connector.getComposingText(
            hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
        counts = server.counts();
        CHECK(countOf(counts, "get_composing_string") == 1);
        CHECK(!composing.empty());
        std::cout << "[PASS] invalidation on " << mutationCase.name
                  << " (" << mutationCase.rpcType << ")" << std::endl;
    }
}

// Suggest and non-suggest candidate requests have distinct cache slots, and
// the non-suggest request is invalidate-first (the server inserts a
// composition separator there, which mutates read state).
void suggestAndFullDistinctSlots(FakeServer& server,
                                 HazkeyServerConnector& connector) {
    server.resetCounts();
    primeComposition(connector);
    server.resetCounts();
    const auto h1 = connector.getComposingHiraganaWithCursor();
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") == 1);
    const auto suggest = connector.getCandidates(true);
    CHECK(countOf(server.counts(), "get_candidates") == 1);
    CHECK(connector.getCandidates(true).live_text() == suggest.live_text());
    CHECK(countOf(server.counts(), "get_candidates") == 1);  // suggest slot hit
    const auto full1 = connector.getCandidates(false);
    CHECK(countOf(server.counts(), "get_candidates") == 2);
    const auto full2 = connector.getCandidates(false);
    CHECK(countOf(server.counts(), "get_candidates") == 3);  // invalidate-first
    CHECK(full1.live_text() != full2.live_text());  // re-executed: fresh data
    CHECK(full1.live_text() != suggest.live_text());  // slots never conflated
    const auto h2 = connector.getComposingHiraganaWithCursor();
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") == 2);
    CHECK(h2.toString() != h1.toString());  // no stale serve after full list
    std::cout << "[PASS] suggest/full cache slots distinct, full is "
                 "invalidate-first" << std::endl;
}

// A FAILED response must not be cached: the immediate retry executes and
// returns the server's data.
void failureNotCached(FakeServer& server, HazkeyServerConnector& connector) {
    server.resetCounts();
    primeComposition(connector);
    server.resetCounts();
    server.failNextGetCandidates();
    const auto failed = connector.getCandidates(true);
    CHECK(failed.candidates_size() == 0);  // error default
    CHECK(countOf(server.counts(), "get_candidates") == 1);
    const auto retried = connector.getCandidates(true);
    CHECK(retried.candidates_size() == 1);
    CHECK(countOf(server.counts(), "get_candidates") == 2);
    std::cout << "[PASS] failure responses are not cached" << std::endl;
}

// After the server drops the connection (restart), the connector reconnects;
// any read served after the reconnection must be re-fetched, never served
// from a cache entry that predates the disconnect. (A cached read issued
// while the connection is idle-dead is legitimately served from cache
// without a round trip; the cache only matters once a transact runs.)
void reconnectInvalidates(FakeServer& server, HazkeyServerConnector& connector) {
    server.resetCounts();
    primeComposition(connector);
    server.resetCounts();
    const auto h1 = connector.getComposingHiraganaWithCursor();
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") == 1);
    server.dropClient();
    // Ride out the dropped connection: retry the mutation until it reaches
    // the reconnected server. Whichever reconnect path runs (write failure
    // or sock_==-1 entry) must have invalidated the read cache.
    bool mutationDelivered = false;
    for (int attempt = 0; attempt < 10 && !mutationDelivered; ++attempt) {
        connector.inputChar("い");
        mutationDelivered = countOf(server.counts(), "input_char") >= 1;
    }
    CHECK(mutationDelivered);
    const auto h2 = connector.getComposingHiraganaWithCursor();
    CHECK(!h2.toString().empty());
    CHECK(h2.toString() != h1.toString());  // fresh value => cache invalidated
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") >= 2);
    std::cout << "[PASS] reconnect invalidates the read cache" << std::endl;
}

}  // namespace

int main() {
    // The reconnect scenario writes to a connection the server dropped; keep
    // the process alive so write() surfaces EPIPE instead of dying.
    signal(SIGPIPE, SIG_IGN);

    char directoryTemplate[] = "/tmp/hazkey-client-cache-test-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath =
        root + "/hazkey-server." + std::to_string(getuid()) + ".sock";
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    {
        // The fake server must be listening before the connector is
        // constructed: the connector would otherwise spawn the real server.
        FakeServer server(socketPath);
        HazkeyServerConnector connector;
        readThroughHits(server, connector);
        mutationInvalidates(server, connector);
        suggestAndFullDistinctSlots(server, connector);
        failureNotCached(server, connector);
        reconnectInvalidates(server, connector);
    }

    std::cout << "[PASS] hazkey_client_cache_test: all scenarios green"
              << std::endl;
    std::filesystem::remove_all(root);
    return 0;
}

// Regression coverage for hazkey-ime-cpu-latency plan todo 2: transaction
// timeout/reconnect/force-restart safety under CPU contention.
//
// Test A (lateResponseNeverParsedAfterTimeout): proves a client read
// timeout discards the socket before the next request is issued, and that a
// response the (simulated wedged) server writes late, onto the now-discarded
// connection, is never parsed by a later transact() on a fresh connection.
//
// Test B (forceRestartHardening): proves connectServer()'s force-restart
// branch (ATTEMPT_TRY_START_FORCE, the 4th connect attempt) still fires for
// a server that has never responded (unchanged, a dead server needs it),
// is suppressed for a contention window after a genuine successful
// transaction (ordinary CPU-contention slow accept), and fires again once
// that window has elapsed.
//
// Both tests drive the REAL HazkeyServerConnector against in-process fake
// AF_UNIX servers, in an isolated XDG_RUNTIME_DIR, using the connector's
// test-only hooks (setTestReadTimeoutSeconds / setTestForceRestartWindowMs /
// setTestStartServerHook) so nothing here spawns a real hazkey-server
// process or waits on the real 10-second read ceiling.

#include <arpa/inet.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "base.pb.h"
#include "commands.pb.h"
#include "config.pb.h"
#include "hazkey_server_connector.h"

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::cerr << "CHECK failed at line " << __LINE__ << ": " #cond \
                      << std::endl;                                        \
            std::exit(1);                                                  \
        }                                                                  \
    } while (0)

namespace {

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

hazkey::RequestEnvelope makeCandidatesRequest() {
    hazkey::RequestEnvelope request;
    request.mutable_get_candidates()->set_is_suggest(true);
    return request;
}

// Fake in-process server for Test A. Accepts sequential connections (each
// on its own thread, so a delayed response on one connection never blocks
// another), and stamps each connection's response with its 1-indexed accept
// order so a stale cross-connection parse is detectable by value.
class DelayableFakeServer {
   public:
    explicit DelayableFakeServer(const std::string& path) : path_(path) {
        listenFd_ = socket(AF_UNIX, SOCK_STREAM, 0);
        CHECK(listenFd_ >= 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
        CHECK(bind(listenFd_, reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) == 0);
        CHECK(listen(listenFd_, 4) == 0);
        acceptThread_ = std::thread([this] { acceptLoop(); });
    }

    ~DelayableFakeServer() {
        stop_ = true;
        shutdown(listenFd_, SHUT_RDWR);
        close(listenFd_);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (int fd : clientFds_) {
                shutdown(fd, SHUT_RDWR);
            }
        }
        if (acceptThread_.joinable()) {
            acceptThread_.join();
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto& worker : workers_) {
                if (worker.joinable()) {
                    worker.join();
                }
            }
        }
        unlink(path_.c_str());
    }

    // Delay (ms) before responding to the request received on connection
    // number `connIndex` (1-indexed, in accept order). Unset = respond
    // immediately.
    void setResponseDelayMs(int connIndex, int delayMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        delaysMs_[connIndex] = delayMs;
    }

   private:
    void acceptLoop() {
        while (!stop_) {
            const int clientFd = accept(listenFd_, nullptr, nullptr);
            if (clientFd < 0) {
                if (stop_) break;
                continue;
            }
            int connIndex;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                connIndex = ++connCount_;
                clientFds_.push_back(clientFd);
                workers_.emplace_back([this, clientFd, connIndex] {
                    serveClient(clientFd, connIndex);
                    close(clientFd);
                });
            }
        }
    }

    void serveClient(int fd, int connIndex) {
        uint32_t networkLength = 0;
        if (!readAll(fd, &networkLength, sizeof(networkLength))) return;
        const uint32_t length = ntohl(networkLength);
        std::string wire(length, '\0');
        if (!readAll(fd, wire.data(), wire.size())) return;
        hazkey::RequestEnvelope request;
        CHECK(request.ParseFromString(wire));

        int delayMs = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = delaysMs_.find(connIndex);
            if (it != delaysMs_.end()) delayMs = it->second;
        }
        if (delayMs > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
        }

        hazkey::ResponseEnvelope response;
        response.set_status(hazkey::SUCCESS);
        auto* candidates = response.mutable_candidates();
        candidates->add_candidates()->set_text("STAMP-" +
                                                std::to_string(connIndex));
        candidates->set_live_text("L" + std::to_string(connIndex));
        candidates->set_page_size(1);

        std::string responseWire;
        CHECK(response.SerializeToString(&responseWire));
        const uint32_t responseLength = htonl(responseWire.size());
        // Best-effort: the peer may already be gone (timed-out client
        // closed its socket) -- SIGPIPE is ignored in main(), so a failed
        // write here just returns quietly.
        writeAll(fd, &responseLength, sizeof(responseLength));
        writeAll(fd, responseWire.data(), responseWire.size());
    }

    int listenFd_ = -1;
    std::string path_;
    std::thread acceptThread_;
    std::mutex mutex_;
    std::vector<int> clientFds_;
    std::vector<std::thread> workers_;
    std::map<int, int> delaysMs_;
    int connCount_ = 0;
    std::atomic<bool> stop_{false};
};

// Test A: a response that arrives after the client's read timeout must
// never be parsed. The client must discard (close) that socket before its
// next request, so the next request always lands on a fresh connection.
void lateResponseNeverParsedAfterTimeout() {
    char directoryTemplate[] = "/tmp/hazkey-transact-safety-test-A-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath =
        root + "/hazkey-server." + std::to_string(getuid()) + ".sock";
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    // 1 second instead of the production 10 seconds, purely so this test
    // runs quickly; the mechanism under test is identical either way.
    HazkeyServerConnector::setTestReadTimeoutSeconds(1);

    {
        DelayableFakeServer server(socketPath);
        // Connection 1 (established by the connector's constructor) will
        // respond far later than the 1s client read timeout.
        server.setResponseDelayMs(1, 2000);

        HazkeyServerConnector connector;

        const auto firstResponse = connector.transact(makeCandidatesRequest());
        CHECK(!firstResponse.has_value());  // timed out: discarded, not parsed

        // Let connection 1's delayed write land on the now-closed client fd
        // (harmless EPIPE; SIGPIPE is ignored in main()) well before this
        // test process exits, so it cannot race with anything below.
        std::this_thread::sleep_for(std::chrono::milliseconds(2200));

        // The next request must go out on a brand-new connection (index 2)
        // and must see only that connection's fresh, immediate response.
        const auto secondResponse =
            connector.transact(makeCandidatesRequest());
        CHECK(secondResponse.has_value());
        CHECK(secondResponse->status() == hazkey::SUCCESS);
        CHECK(secondResponse->candidates().candidates(0).text() ==
              "STAMP-2");
    }

    HazkeyServerConnector::clearTestHooks();
    std::filesystem::remove_all(root);
    std::cout << "[PASS] late response on a timed-out connection is never "
                 "parsed; next request reconnects fresh"
              << std::endl;
}

struct SpawnCall {
    bool force;
};

// Test B, case 1: a connector that has never completed a successful
// transact() must still force-restart at ATTEMPT_TRY_START_FORCE -- a
// genuinely dead server still needs the forced restart, unchanged by this
// hardening.
void forceRestartStillFiresForNeverSuccessfulConnector() {
    std::vector<SpawnCall> calls;
    HazkeyServerConnector::setTestStartServerHook(
        [&calls](bool force) { calls.push_back({force}); });

    char directoryTemplate[] = "/tmp/hazkey-transact-safety-test-B1-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    // Intentionally never create a listener at this path: every connect()
    // attempt fails for the whole retry loop.
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    { HazkeyServerConnector connector; }  // blocks through all MAX_RETRIES

    bool sawNonForced = false;
    bool sawForced = false;
    for (const auto& call : calls) {
        if (call.force) {
            sawForced = true;
        } else {
            sawNonForced = true;
        }
    }
    CHECK(sawNonForced);  // attempt 1 still spawns non-forced
    CHECK(sawForced);     // never succeeded => force restart still fires

    HazkeyServerConnector::setTestStartServerHook(nullptr);
    std::filesystem::remove_all(root);
    std::cout << "[PASS] force-restart still fires for a connector that "
                 "never had a successful transaction"
              << std::endl;
}

// Test B, cases 2 & 3: a connector with one genuine success, then a lost
// server. Case 2 uses the production contention window (5s), which
// comfortably covers the brief gap since the last success, so the forced
// restart must be suppressed (ordinary CPU-contention slow accept). Case 3
// shrinks the window via the test hook so the same gap now exceeds it, and
// the forced restart must fire again.
void forceRestartWindowGatesRecentSuccess() {
    char directoryTemplate[] = "/tmp/hazkey-transact-safety-test-B23-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath =
        root + "/hazkey-server." + std::to_string(getuid()) + ".sock";
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);
    HazkeyServerConnector::setTestReadTimeoutSeconds(1);

    std::vector<SpawnCall> calls;
    HazkeyServerConnector::setTestStartServerHook(
        [&calls](bool force) { calls.push_back({force}); });

    std::unique_ptr<HazkeyServerConnector> connector;
    {
        // The fake server must exist before the connector is constructed,
        // or the constructor would exhaust its retries against a socket
        // path that does not exist yet.
        DelayableFakeServer server(socketPath);
        connector = std::make_unique<HazkeyServerConnector>();
        const auto response = connector->transact(makeCandidatesRequest());
        CHECK(response.has_value());
        CHECK(response->status() == hazkey::SUCCESS);
        // `server` is destroyed at the end of this block: its listening
        // socket is closed and unlinked, and the accepted client fd is
        // shut down -- connector's sock_ is now stale.
    }

    // Case 2: production window (5s) comfortably covers the retry loop's
    // ~1.2s span since the transact() above, so the forced restart must be
    // suppressed.
    calls.clear();
    HazkeyServerConnector::setTestForceRestartWindowMs(-1);
    // Two calls guarantee connectServer() runs to completion at least once:
    // the first may fail via a write EPIPE (which calls connectServer()
    // inline) or via a read timeout (which does not); either way sock_ is
    // left disconnected, so the second call's entry path is guaranteed to
    // invoke connectServer().
    connector->transact(makeCandidatesRequest());
    const auto caseTwoResponse = connector->transact(makeCandidatesRequest());
    CHECK(!caseTwoResponse.has_value());  // no listener: every retry fails
    bool caseTwoForced = false;
    for (const auto& call : calls) {
        if (call.force) caseTwoForced = true;
    }
    CHECK(!caseTwoForced);
    std::cout << "[PASS] force-restart suppressed for a server that "
                 "answered within the contention window"
              << std::endl;

    // Case 3: shrink the window well below the retry loop's ~450ms
    // time-to-attempt-4, so the same "no listener" condition now exceeds
    // the window and the forced restart fires again.
    calls.clear();
    HazkeyServerConnector::setTestForceRestartWindowMs(50);
    connector->transact(makeCandidatesRequest());
    const auto caseThreeResponse =
        connector->transact(makeCandidatesRequest());
    CHECK(!caseThreeResponse.has_value());
    bool caseThreeForced = false;
    for (const auto& call : calls) {
        if (call.force) caseThreeForced = true;
    }
    CHECK(caseThreeForced);
    std::cout << "[PASS] force-restart resumes once the contention window "
                 "has elapsed"
              << std::endl;

    HazkeyServerConnector::clearTestHooks();
    std::filesystem::remove_all(root);
}

}  // namespace

int main() {
    // Test A deliberately writes to a socket the client has already
    // closed; keep the process alive so write() surfaces EPIPE instead of
    // raising SIGPIPE.
    signal(SIGPIPE, SIG_IGN);

    lateResponseNeverParsedAfterTimeout();
    forceRestartStillFiresForNeverSuccessfulConnector();
    forceRestartWindowGatesRecentSuccess();

    std::cout
        << "[PASS] hazkey_client_transact_safety_test: all scenarios green"
        << std::endl;
    return 0;
}

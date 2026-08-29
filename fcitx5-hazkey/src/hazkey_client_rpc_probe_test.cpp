#include <arpa/inet.h>
#include <assert.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <mutex>
#include <regex>
#include <string>
#include <thread>
#include <vector>

#include "hazkey_server_connector.h"

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

class FakeServer {
   public:
    explicit FakeServer(const std::string& path) : path_(path) {
        listenFd_ = socket(AF_UNIX, SOCK_STREAM, 0);
        assert(listenFd_ >= 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
        assert(bind(listenFd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        assert(listen(listenFd_, 1) == 0);
        thread_ = std::thread([this] { serve(); });
    }

    ~FakeServer() {
        if (listenFd_ >= 0) {
            close(listenFd_);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        unlink(path_.c_str());
    }

    std::map<std::string, int> counts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return counts_;
    }

   private:
    void serve() {
        const int clientFd = accept(listenFd_, nullptr, nullptr);
        if (clientFd < 0) {
            return;
        }
        timeval timeout = {1, 0};
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        while (true) {
            uint32_t networkLength = 0;
            if (!readAll(clientFd, &networkLength, sizeof(networkLength))) {
                break;
            }
            const uint32_t length = ntohl(networkLength);
            std::string wire(length, '\0');
            if (!readAll(clientFd, wire.data(), wire.size())) {
                break;
            }
            hazkey::RequestEnvelope request;
            assert(request.ParseFromString(wire));
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ++counts_[requestType(request)];
            }
            hazkey::ResponseEnvelope response;
            response.set_status(hazkey::SUCCESS);
            response.mutable_text_with_cursor();
            std::string responseWire;
            assert(response.SerializeToString(&responseWire));
            const uint32_t responseLength = htonl(responseWire.size());
            if (!writeAll(clientFd, &responseLength, sizeof(responseLength))
                || !writeAll(clientFd, responseWire.data(), responseWire.size())) {
                break;
            }
        }
        close(clientFd);
    }

    int listenFd_ = -1;
    std::string path_;
    std::thread thread_;
    mutable std::mutex mutex_;
    std::map<std::string, int> counts_;
};

std::map<std::string, int> countsFromEvidence(const std::string& path) {
    std::ifstream input(path);
    std::map<std::string, int> counts;
    const std::regex typePattern("\\\"type\\\":\\\"([^\\\"]+)\\\"");
    std::string line;
    while (std::getline(input, line)) {
        std::smatch match;
        if (std::regex_search(line, match, typePattern)) {
            ++counts[match[1].str()];
        }
    }
    return counts;
}

std::map<std::string, int> baselineFromFile(const std::string& path) {
    std::ifstream input(path);
    std::map<std::string, int> counts;
    const std::regex countPattern("\\\"([^\\\"]+)\\\"\\s*:\\s*([0-9]+)");
    std::string contents((std::istreambuf_iterator<char>(input)), {});
    for (std::sregex_iterator it(contents.begin(), contents.end(), countPattern), end; it != end; ++it) {
        counts[(*it)[1].str()] = std::stoi((*it)[2].str());
    }
    return counts;
}

void writeBaseline(const std::string& path, const std::map<std::string, int>& counts) {
    std::ofstream output(path);
    output << "{\n";
    for (auto it = counts.begin(); it != counts.end(); ++it) {
        output << "  \"" << it->first << "\": " << it->second;
        output << (std::next(it) == counts.end() ? "\n" : ",\n");
    }
    output << "}\n";
}

void replayCorpus(HazkeyServerConnector& connector) {
    // Matches CorpusFixtures.swift: full, suggestion, prefix, kana-number,
    // relative-date, and non-learnable-kana-number-commit readings.
    const std::vector<std::vector<std::string>> readings = {
        {"に", "ほ", "ん"}, {"に", "ほ", "ん"}, {"に", "ほ", "ん", "ご"},
        {"に", "じ", "ゅ", "う"}, {"き", "ょ", "う"}, {"に", "じ", "ゅ", "う"}};
    for (size_t index = 0; index < readings.size(); ++index) {
        connector.newComposingText();
        for (const auto& character : readings[index]) {
            connector.inputChar(character);
        }
        if (index == 2) {
            connector.moveCursor(-1);
        }
        // Models the per-key-event read pattern of HazkeyState: the
        // pre-display composing-text read (showPreeditCandidateList) and the
        // fallback read inside showCandidateList are issued back to back
        // with identical arguments within one key event, and the auxiliary
        // hiragana read (setHiraganaAUX) is re-issued whenever the displayed
        // value is unchanged. The connector read cache must absorb the
        // duplicates so the executed counts stay at the baseline floor.
        connector.getComposingText(
            hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
        connector.getCandidates(true);
        connector.getComposingText(
            hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
        connector.getComposingHiraganaWithCursor();
        connector.getComposingHiraganaWithCursor();
        if (index == 5) {
            // The commit reading enters full-conversion mode before
            // selecting a candidate; the non-suggest request is issued
            // without a cursor move (Escape-from-clause-boundary path).
            connector.getCandidates(false);
        }
    }
}

}  // namespace

int main() {
    char directoryTemplate[] = "/tmp/hazkey-client-rpc-probe-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    assert(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath = root + "/hazkey-server." + std::to_string(getuid()) + ".sock";
    const std::string evidencePath = root + "/evidence.jsonl";
    assert(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);
    assert(setenv("HAZKEY_PERF_EVIDENCE", evidencePath.c_str(), 1) == 0);

    std::map<std::string, int> serverCounts;
    {
        FakeServer server(socketPath);
        {
            HazkeyServerConnector connector;
            replayCorpus(connector);
        }
        serverCounts = server.counts();
    }

    const auto observed = countsFromEvidence(evidencePath);
    assert(observed == serverCounts);
    const std::string baselinePath =
        (std::filesystem::path(__FILE__).parent_path() / "rpc_baseline_cpp.json").string();
    if (!std::filesystem::exists(baselinePath)) {
        writeBaseline(baselinePath, observed);
    }
    // The committed baseline (rpc_baseline_cpp.json) is immutable. Post-change
    // counts go to a NEW file and are compared per type: state-mutating RPCs
    // must pass through unchanged, read RPCs must be at or below the baseline
    // with same-epoch duplicates absorbed by the connector read cache.
    const std::string afterPath =
        (std::filesystem::path(__FILE__).parent_path() / "rpc_after_cache.json").string();
    writeBaseline(afterPath, observed);
    const auto baseline = baselineFromFile(baselinePath);
    // State-mutating RPCs pass through unchanged (ordering preserved):
    assert(observed.at("input_char") == baseline.at("input_char"));
    assert(observed.at("move_cursor") == baseline.at("move_cursor"));
    assert(observed.at("new_composing_text") == baseline.at("new_composing_text"));
    // Deterministic corpus + deterministic read cache => exact executed
    // counts: 12 composing-text reads and 12 auxiliary hiragana reads are
    // issued, 6 of each execute (same-epoch duplicates served from cache);
    // 7 candidate reads execute (6 suggest + 1 non-suggest, which is
    // invalidate-first by design).
    assert(observed.at("get_composing_string") == 6);
    assert(observed.at("get_hiragana_with_cursor") == 6);
    assert(observed.at("get_candidates") == 7);
    // Read types never exceed the immutable baseline; get_candidates is
    // strictly fewer (baseline fetched both list flavors for every reading):
    assert(observed.at("get_candidates") < baseline.at("get_candidates"));
    assert(observed.at("get_hiragana_with_cursor") <=
           baseline.at("get_hiragana_with_cursor"));
    std::cout << "[PASS] RPC counts (after=baseline): ";
    for (const auto& [type, count] : observed) {
        std::cout << type << "=" << count;
        if (auto it = baseline.find(type); it != baseline.end()) {
            std::cout << "/" << it->second;
        }
        std::cout << " ";
    }
    std::cout << "\n";
    std::cout << "[INFO] after-counts written to " << afterPath << "\n";
    std::filesystem::remove_all(root);
    return 0;
}

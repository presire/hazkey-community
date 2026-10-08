/**
 * @file hazkey_client_rpc_probe_test.cpp
 * @brief 要求種別別実行回数の基準検証をまとめる
 *
 * 固定入力シナリオの再現で状態変更要求が通過することと、読取重複が保存で吸収され実行回数が基準以下に収まることを確認する
 * 実接続器とプロセス内模擬ソケットだけを使い実サーバは起動しない
 */
#include <arpa/inet.h>
#include <assert.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
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

/**
 * @brief 要求封筒の種類名を検査用に変換する
 *
 * ペイロード種別から短い英字名を返して、種類別の到達回数を数える集計に使用する
 */
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
        case hazkey::RequestEnvelope::kAcceptPrediction: return "accept_prediction";
        case hazkey::RequestEnvelope::kDeleteCandidateLearningData: return "delete_candidate_learning_data";
        case hazkey::RequestEnvelope::kGetHiraganaWithCursor: return "get_hiragana_with_cursor";
        case hazkey::RequestEnvelope::kGetComposingString: return "get_composing_string";
        case hazkey::RequestEnvelope::kGetCandidates: return "get_candidates";
        case hazkey::RequestEnvelope::kGetCurrentInputMode: return "get_current_input_mode";
        case hazkey::RequestEnvelope::kSaveLearningData: return "save_learning_data";
        case hazkey::RequestEnvelope::kGetConfig: return "get_config";
        case hazkey::RequestEnvelope::kSetConfig: return "set_config";
        case hazkey::RequestEnvelope::kClearAllHistory: return "clear_all_history";
        case hazkey::RequestEnvelope::kReloadZenzaiModel: return "reload_zenzai_model";
        case hazkey::RequestEnvelope::kToggleZenzai: return "toggle_zenzai";
        case hazkey::RequestEnvelope::kGetDefaultProfile: return "get_default_profile";
        case hazkey::RequestEnvelope::kGetLearningHistory: return "get_learning_history";
        case hazkey::RequestEnvelope::kDeleteLearningEntries: return "delete_learning_entries";
        case hazkey::RequestEnvelope::PAYLOAD_NOT_SET: return "none";
    }
    return "none";
}

/**
 * @brief 指定長を受信し切るまで読取を繰り返す
 *
 * 要求長と要求本体の受信に使用して、途中で切断や失敗があれば偽を返す
 */
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

/**
 * @brief 指定長を送信し切るまで書込を繰り返す
 *
 * 応答長と応答本体の送信に使用して、途中で切断や失敗があれば偽を返す
 */
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

/**
 * @brief 要求回数を数えるプロセス内模擬サーバ
 *
 * 一接続分の要求を種類別に数えて成功応答を返して、固定入力シナリオの再現による実行回数の基準検証を支える
 */
class FakeServer {
   public:
    /**
     * @brief 模擬ソケットを開設して応答循環を起動する
     *
     * 指定パスのUNIXソケットを作成して待ち受けを開始して、応答循環を別スレッドで動かす
     */
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

    /**
     * @brief 待受けを閉じて資源を破棄する
     *
     * 受付スレッドの合流を待ち、ソケット表示を取り除く
     */
    ~FakeServer() {
        if (listenFd_ >= 0) {
            close(listenFd_);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        unlink(path_.c_str());
    }

    /**
     * @brief 種類別到達回数の写しを返す
     *
     * 記録証跡との一致確認と基準照合のために、現在の集計を複写して返す
     */
    std::map<std::string, int> counts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return counts_;
    }

   private:
    /**
     * @brief 一接続分の要求応答循環を処理する
     *
     * 到達回数を数えて成功応答を返して、切断まで繰り返す
     */
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

    int listenFd_ = -1;                  ///< 待受けソケット記述子
    std::string path_;                   ///< 模擬ソケットの配置パス
    std::thread thread_;                 ///< 応答循環の実行スレッド

    // 集計状態
    mutable std::mutex mutex_;           ///< 到達回数を保護するミューテックス
    std::map<std::string, int> counts_;  ///< 種類別の到達回数集計
};

/**
 * @brief 記録証跡から種別別実行回数を復元する
 *
 * 証跡行の種類表記を数え上げて、模擬サーバの集計と照合できる形へ戻す
 */
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

/**
 * @brief 基準ファイルから種別別回数を読み込む
 *
 * 不変基準の内容を連想配列へ復元して、状態変更の通過と読取の上限検証に使用する
 */
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

/**
 * @brief 種別別回数を基準形式で書き出す
 *
 * 初回は基準として保存し以降は今回分として保存して、種類別の比較に使用する
 */
void writeBaseline(const std::string& path, const std::map<std::string, int>& counts) {
    std::ofstream output(path);
    output << "{\n";
    for (auto it = counts.begin(); it != counts.end(); ++it) {
        output << "  \"" << it->first << "\": " << it->second;
        output << (std::next(it) == counts.end() ? "\n" : ",\n");
    }
    output << "}\n";
}

/**
 * @brief 固定入力シナリオの入力と読取手順を再現する
 *
 * 全変換・予測・接頭辞・仮名数字・相対日付・学習なし確定の読列を入力して、表示前読取・予備読取・補助読取の重複を含む実利用順序を再現する
 * 重複が保存で吸収されることが基準検証の要点である
 */
void replayCorpus(HazkeyServerConnector& connector) {
    // CorpusFixtures.swiftに合わせて通常変換、予測、接頭辞、かな数字、相対日付、学習しないかな数字確定の読みを使用する
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
        // HazkeyStateのキーイベントごとの読取順を再現する
        // 同じ引数の組成文字列読取と補助ひらがな読取を重複させて、接続器の読取キャッシュが重複を吸収することを確認する
        connector.getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
        connector.getCandidates(true);
        connector.getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
        connector.getComposingHiraganaWithCursor();
        connector.getComposingHiraganaWithCursor();
        if (index == 5) {
            // 確定用の読みは候補選択前に通常変換へ入り、カーソル移動なしで通常候補を取得する
            connector.getCandidates(false);
        }
    }
}

void sendEvidenceProbe(const std::string& root, const std::string& evidencePath) {
    assert(setenv("HAZKEY_PERF_EVIDENCE", evidencePath.c_str(), 1) == 0);
    const std::string socketPath =
        root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
    FakeServer server(socketPath);
    {
        HazkeyServerConnector connector;
        connector.inputChar("probe");
    }
}

void testUnsafePerfEvidenceTargets(const std::string& root) {
    const std::string symlinkPath = root + "/evidence-link.jsonl";
    const std::string targetPath = root + "/evidence-target.jsonl";
    const std::string fifoPath = root + "/evidence.fifo";
    {
        std::ofstream target(targetPath);
        target << "sentinel\n";
    }
    assert(symlink(targetPath.c_str(), symlinkPath.c_str()) == 0);
    sendEvidenceProbe(root, symlinkPath);
    {
        std::ifstream target(targetPath);
        const std::string contents((std::istreambuf_iterator<char>(target)), {});
        assert(contents == "sentinel\n");
    }
    assert(std::filesystem::is_symlink(symlinkPath));

    assert(mkfifo(fifoPath.c_str(), 0600) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        alarm(5);
        sendEvidenceProbe(root, fifoPath);
        _exit(0);
    }
    int status = 0;
    pid_t waited = -1;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    assert(waited == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(std::filesystem::is_fifo(fifoPath));
}

}  // namespace

/**
 * @brief 要求回数の基準検証を一括して実行する
 *
 * 固定入力シナリオの再現と証跡一致と不変基準との照合を行い、状態変更の通過と読取上限を検証して成功を報告する
 */
int main() {
    char directoryTemplate[] = "/tmp/hazkey-client-rpc-probe-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    assert(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath = root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
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
    // コミット済み基準ファイルは変更せず、今回の回数を別ファイルへ保存して種別ごとに比較する
    // 状態変更RPCは不変、読取RPCは同一期間の重複をキャッシュで吸収して基準以下とする
    const std::string afterPath = (std::filesystem::path(__FILE__).parent_path() / "rpc_after_cache.json").string();
    writeBaseline(afterPath, observed);
    const auto baseline = baselineFromFile(baselinePath);

    // 状態変更RPCは順序を保ってそのまま通過する
    assert(observed.at("input_char") == baseline.at("input_char"));
    assert(observed.at("move_cursor") == baseline.at("move_cursor"));
    assert(observed.at("new_composing_text") == baseline.at("new_composing_text"));

    // 固定入力シナリオと固定キャッシュにより、実行回数を確定できる
    // 組成文字列と補助ひらがなは各12回要求して、同一期間の重複を吸収して各6回実行する
    // 候補読取は、予測6回と先に無効化する通常候補1回の計7回実行する
    assert(observed.at("get_composing_string") == 6);
    assert(observed.at("get_hiragana_with_cursor") == 6);
    assert(observed.at("get_candidates") == 7);

    // 読取種別は不変基準を超えず、候補読取は基準より少ない
    assert(observed.at("get_candidates") < baseline.at("get_candidates"));
    assert(observed.at("get_hiragana_with_cursor") <=
           baseline.at("get_hiragana_with_cursor"));
    testUnsafePerfEvidenceTargets(root);
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

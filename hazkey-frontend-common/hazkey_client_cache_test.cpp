/**
 * @file hazkey_client_cache_test.cpp
 * @brief 接続器読取キャッシュの無効化検証をまとめる
 *
 * 同一期間内の再読取が往復なしで返ることと状態変更で古い値が残らないことと
 * 失敗や再接続後に新鮮な値が返ることを模擬サーバで確認する
 * 実接続器とプロセス内模擬ソケットだけを使い実サーバは起動しない
 */

// HazkeyServerConnectorの読取キャッシュ無効化を検証する
//
// 実際のHazkeyServerConnectorをプロセス内の模擬UNIXソケットサーバへ接続し、
// 初期化、フォーカスまたはコンテキスト変更、入力モード遷移、ライブ変換切替、
// 確定、候補変更に対応する状態変更RPCについて以下を検証する
//
// 1. 操作後に古い補助表示またはプレエディット値を返さない
// 2. 状態変更RPCを省略せず常にサーバへ送る
//
// 各応答には到達順番号を含め、要求回数だけでなく値でも古いキャッシュを検出する

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
 * @brief 到達順番号を応答へ付与するプロセス内模擬サーバ
 *
 * 順次接続を受け付けて種類別回数を数えて、応答値へ到達順番号を付与して古い値の混入を値で検出可能にする
 * 再接続検証のために複数回の接続切替へ対応する
 */
class FakeServer {
   public:
    /**
     * @brief 模擬ソケットを開設して受付スレッドを起動する
     *
     * 指定パスのUNIXソケットを作成して待受けを開始して、受付循環を別スレッドで動かす
     */
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

    /**
     * @brief 受付を停止して資源を破棄する
     *
     * 待受けと接続中ソケットを閉じて受付スレッドの合流を待ち、ソケット表示を取り除く
     */
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

    /**
     * @brief 種類別回数と修飾子記録を消去する
     *
     * 個別検証の通信量だけを数えるために、検証開始直前で集計を零へ戻す
     */
    void resetCounts() {
        std::lock_guard<std::mutex> lock(mutex_);
        counts_.clear();
        modifierEvents_.clear();
    }

    /**
     * @brief 種類別到達回数の写しを返す
     *
     * 検証側が期待回数と照合するために、現在の集計を複写して返す
     */
    std::map<std::string, int> counts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return counts_;
    }

    /**
     * @brief 受信した修飾子事象の写しを返す
     *
     * 押下と解放の種別順序を検証するために、蓄積した事象列を複写して返す
     */
    std::vector<hazkey::commands::ModifierEvent_EventType> modifierEvents()
        const {
        std::lock_guard<std::mutex> lock(mutex_);
        return modifierEvents_;
    }

    /**
     * @brief 接続中相手を切断して再接続検証の起点を作る
     *
     * 次回通信を失敗させて再接続経路へ誘導して、再接続時に読取キャッシュが捨てられることを検証可能にする
     */
    void dropClient() { shutdown(clientFd_, SHUT_RDWR); }

    /**
     * @brief 次回の候補取得へ失敗応答を仕込む
     *
     * 失敗応答が保存されないことの検証に使用して、呼び出し回数分だけ失敗応答を返す予約を積む
     */
    void failNextGetCandidates() { failGetCandidates_++; }

   private:
    /**
     * @brief 待受け循環で順次接続を受け付ける
     *
     * 再接続検証のため切断後も待受けを続け、接続ごとに受信循環へ引き渡す
     */
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

    /**
     * @brief 一接続分の要求応答循環を処理する
     *
     * 到達回数を数えて応答へ順番号を付与して、予約済みの失敗応答があれば優先して返す
     */
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
                ++counts_[type];  // 注入した応答状態にかかわらず到達回数を数える
                if (request.has_modifier_event()) {
                    modifierEvents_.push_back(
                        request.modifier_event().event_type());
                }
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

    /**
     * @brief 要求種別に応じた模擬応答を組み立てる
     *
     * 順番号を値へ埋め込んで古い値の混入を検出可能にして、変更系やその他読取は成功だけを返す
     */
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
                break;  // 変更系とその他の読取には成功応答だけを返す
        }
    }

    int listenFd_ = -1;                                                      ///< 待受けソケット記述子
    int clientFd_ = -1;                                                      ///< 接続中相手記述子
    std::string path_;                                                       ///< 模擬ソケットの配置パス
    std::thread thread_;                                                     ///< 受付循環の実行スレッド

    // 受付と集計の状態
    mutable std::mutex mutex_;                                               ///< 集計と接続状態を保護するミューテックス
    std::map<std::string, int> counts_;                                      ///< 種類別の到達回数集計
    std::vector<hazkey::commands::ModifierEvent_EventType> modifierEvents_;  ///< 受信した修飾子事象列
    long arrivalSeq_ = 0;                                                    ///< 応答へ付与する到達順番号
    int failGetCandidates_ = 0;                                              ///< 失敗応答の残り予約回数
    std::atomic<bool> stop_{false};                                          ///< 受付停止フラグ
};

/**
 * @brief 種類別集計から指定種別の回数を取り出す
 *
 * 存在しない種別は零として扱い、期待回数との照合に使う
 */
int countOf(const std::map<std::string, int>& counts, const std::string& type) {
    auto it = counts.find(type);
    return it == counts.end() ? 0 : it->second;
}

/**
 * @brief 後続読取の前提となる合成を開始する
 *
 * 新規合成と一文字入力で読取対象を作り、各検証の共通準備に使用する
 */
void primeComposition(HazkeyServerConnector& connector) {
    connector.newComposingText();
    connector.inputChar("あ");
}

/**
 * @brief 同一期間内の再読取が保存値で返ることを検証する
 *
 * 仮名補助と候補と合成文字列と入力方式の再読取で往復が1回に抑えられ、値が同一であることを確認する
 */
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
    const auto s1 = connector.getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
    const auto s2 = connector.getComposingText(hazkey::commands::GetComposingString_CharType_HIRAGANA, "");
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

/**
 * @brief 状態変更後に古い読取値が残らないことを検証する
 *
 * 初期化や焦点切替や方式切替や確定や候補変更に相当する各変更要求が通過し、直後の仮名補助読取が再取得され値が更新されることを確認する
 */
void mutationInvalidates(FakeServer& server, HazkeyServerConnector& connector) {
    /**
     * @brief 無効化検証の一件分の変更操作を表す
     *
     * 表示名と適用処理と通過確認用の要求種別を一組にして、全ての状態変更経路を同じ手順で検証する
     */
    struct MutationCase {
        const char* name;                                   ///< 検証表示用の操作名
        std::function<void(HazkeyServerConnector&)> apply;  ///< 接続器へ加える変更操作
        const char* rpcType;                                ///< 通過確認する要求種別名
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
        server.resetCounts();  // このケースの通信だけを数える
        const auto h1 = connector.getComposingHiraganaWithCursor();
        CHECK(connector.getComposingHiraganaWithCursor().toString() ==
               h1.toString());  // キャッシュから返ることを確認する
        auto counts = server.counts();
        CHECK(countOf(counts, "get_hiragana_with_cursor") == 1);
        mutationCase.apply(connector);
        counts = server.counts();
        CHECK(countOf(counts, mutationCase.rpcType) == 1);
        const auto h2 = connector.getComposingHiraganaWithCursor();
        counts = server.counts();
        CHECK(countOf(counts, "get_hiragana_with_cursor") == 2);
        CHECK(h2.toString() != h1.toString());  // 古い値ではなく再取得値である
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

/**
 * @brief 予測候補と通常候補の保存場所が別であることを検証する
 *
 * 予測要求の再読取は保存値で返り、通常要求は先に無効化して再取得され、
 * 両者の値が混ざらないことと仮名補助も更新されることを確認する
 */
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
    CHECK(countOf(server.counts(), "get_candidates") == 1);  // 予測候補用キャッシュに一致する
    const auto full1 = connector.getCandidates(false);
    CHECK(countOf(server.counts(), "get_candidates") == 2);
    const auto full2 = connector.getCandidates(false);
    CHECK(countOf(server.counts(), "get_candidates") == 3);  // 先に無効化して再取得する
    CHECK(full1.live_text() != full2.live_text());           // 再実行された新しい値である
    CHECK(full1.live_text() != suggest.live_text());         // 保存先を混同しない
    const auto h2 = connector.getComposingHiraganaWithCursor();
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") == 2);
    CHECK(h2.toString() != h1.toString());                   // 通常候補の後に古い値を返さない
    std::cout << "[PASS] suggest/full cache slots distinct, full is "
                 "invalidate-first" << std::endl;
}

/**
 * @brief 失敗応答が保存されないことを検証する
 *
 * 仕込み失敗の直後に再読取が再実行され
 * 正規候補が返ることを確認する
 */
void failureNotCached(FakeServer& server, HazkeyServerConnector& connector) {
    server.resetCounts();
    primeComposition(connector);
    server.resetCounts();
    server.failNextGetCandidates();
    const auto failed = connector.getCandidates(true);
    CHECK(failed.candidates_size() == 0);  // 失敗時の既定値
    CHECK(countOf(server.counts(), "get_candidates") == 1);
    const auto retried = connector.getCandidates(true);
    CHECK(retried.candidates_size() == 1);
    CHECK(countOf(server.counts(), "get_candidates") == 2);
    std::cout << "[PASS] failure responses are not cached" << std::endl;
}

/**
 * @brief 再接続後に古い保存値が使われないことを検証する
 *
 * 切断後の変更要求で再接続を誘発し、直後の仮名補助読取が再取得され値が更新されることを確認する
 */
void reconnectInvalidates(FakeServer& server, HazkeyServerConnector& connector) {
    server.resetCounts();
    primeComposition(connector);
    server.resetCounts();
    const auto h1 = connector.getComposingHiraganaWithCursor();
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") == 1);
    server.dropClient();

    // 再接続したサーバへ届くまで変更操作を再試行する
    // 書込失敗と未接続入口のどちらでも読取キャッシュを無効化しなければならない
    bool mutationDelivered = false;
    for (int attempt = 0; attempt < 10 && !mutationDelivered; ++attempt) {
        connector.inputChar("い");
        mutationDelivered = countOf(server.counts(), "input_char") >= 1;
    }
    CHECK(mutationDelivered);
    const auto h2 = connector.getComposingHiraganaWithCursor();
    CHECK(!h2.toString().empty());
    CHECK(h2.toString() != h1.toString());  // 新しい値ならキャッシュは無効化済み
    CHECK(countOf(server.counts(), "get_hiragana_with_cursor") >= 2);
    std::cout << "[PASS] reconnect invalidates the read cache" << std::endl;
}

/**
 * @brief [Shift]キー解放種別が単独状態を反映することを検証する
 *
 * 単独押下の解放では継続種別が返り他キー併用では取消種別が返り、順序通りに記録されることを確認する
 */
void shiftReleaseTypeTracksLoneState(FakeServer& server,
                                     HazkeyServerConnector& connector) {
    server.resetCounts();
    connector.shiftKeyEvent(true, false);
    connector.shiftKeyEvent(true, true);
    const auto events = server.modifierEvents();
    CHECK(events.size() == 2);
    CHECK(events[0] == hazkey::commands::ModifierEvent_EventType_CANCEL);
    CHECK(events[1] == hazkey::commands::ModifierEvent_EventType_RELEASE);
    std::cout << "[PASS] shift release type tracks lone state" << std::endl;
}

}  // namespace

/**
 * @brief 読取キャッシュの全検証を順に実行する
 *
 * 保存読取・状態変更無効化・[Shift]キー種別・予測通常の保存分離・失敗非保存・再接続無効化を呼び出して成功を報告する
 */
int main() {
    // 再接続シナリオでは切断済みソケットへ書き込むため、SIGPIPEを無視してEPIPEとして扱う
    signal(SIGPIPE, SIG_IGN);

    char directoryTemplate[] = "/tmp/hazkey-client-cache-test-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath = root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    {
        // 接続器の構築前に模擬サーバを待受状態にする
        // そうしない場合、接続器が実サーバを起動する
        FakeServer server(socketPath);
        HazkeyServerConnector connector;
        readThroughHits(server, connector);
        mutationInvalidates(server, connector);
        shiftReleaseTypeTracksLoneState(server, connector);
        suggestAndFullDistinctSlots(server, connector);
        failureNotCached(server, connector);
        reconnectInvalidates(server, connector);
    }

    std::cout << "[PASS] hazkey_client_cache_test: all scenarios green"
              << std::endl;
    std::filesystem::remove_all(root);
    return 0;
}

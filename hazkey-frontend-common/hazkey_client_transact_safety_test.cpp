/**
 * @file hazkey_client_transact_safety_test.cpp
 * @brief 通信の時間切れと再開と強制再起動の検証をまとめる
 *
 * 遅延応答が破棄され次回は新規接続で新鮮な応答だけを見ることと、成功直後は強制再起動を抑え窓を過ぎれば再び行うことを確認する
 * 実接続器とプロセス内模擬ソケットと検査用接続子だけを使い実サーバは起動しない
 */

// CPU競合時の通信タイムアウト、再接続、強制再起動の安全性を検証する
//
// 検証Aは読取タイムアウト後にソケットを破棄して、遅れて届いた応答を次の新規接続で解釈しないことを確認する
// 検証Bは1度も成功していない接続では、4回目の接続試行で強制再起動して、成功直後は競合待機時間内で抑止し、時間経過後に再開することを確認する
//
// 隔離したXDG_RUNTIME_DIRにプロセス内AF_UNIX模擬サーバを作り、テスト専用フックを使用する
// 実際のhazkey-community-serverを起動せず、既定の10秒読取待機も使用しない

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
 * @brief 候補取得の検証用要求を組み立てる
 *
 * 予測種別の要求封筒を生成して、時間切れ検証と再起動窓検証の共通入力に使う
 */
hazkey::RequestEnvelope makeCandidatesRequest() {
    hazkey::RequestEnvelope request;
    request.mutable_get_candidates()->set_is_suggest(true);
    return request;
}

/**
 * @brief 応答遅延を設定できるプロセス内模擬サーバ
 *
 * 接続ごとに別スレッドで応答し受付順番号を応答へ付与して、古い接続の遅延応答の混入を値で検出可能にする
 * 時間切れ検証のために接続別の遅延設定へ対応する
 */
class DelayableFakeServer {
   public:
    /**
     * @brief 模擬ソケットを開設して受付循環を起動する
     *
     * 指定パスのUNIXソケットを作成して待受けを開始して、受付循環を別スレッドで動かす
     */
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

    /**
     * @brief 受付と作業スレッドを停止して資源を破棄する
     *
     * 待受けと接続中記述子を閉じて全作業の合流を待ち、ソケット表示を取り除く
     */
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

    /**
     * @brief 指定接続の応答遅延を設定する
     *
     * 受付順の接続番号ごとに遅延時間を持たせて、未設定の接続は即時応答のままにする
     */

    // 受付順の接続番号ごとに応答前の遅延時間を設定する
    // 未設定の接続には直ちに応答する
    void setResponseDelayMs(int connIndex, int delayMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        delaysMs_[connIndex] = delayMs;
    }

   private:
    /**
     * @brief 待受け循環で順次接続を受け付ける
     *
     * 接続ごとに作業スレッドを起こして受信処理へ渡して、停止合図まで繰り返す
     */
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

    /**
     * @brief 1接続分の要求応答を処理する
     *
     * 設定済みの遅延を挟んで受付順番号を付与した応答を返して、相手が既に閉じていれば書込失敗を静かに終える
     */
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

        // タイムアウトしたクライアントは、ソケットを閉じている場合がある
        // main()でSIGPIPEを無視するため、書込失敗はそのまま終了する
        writeAll(fd, &responseLength, sizeof(responseLength));
        writeAll(fd, responseWire.data(), responseWire.size());
    }

    int listenFd_ = -1;                 ///< 待受けソケット記述子
    std::string path_;                  ///< 模擬ソケットの配置パス
    std::thread acceptThread_;          ///< 受付循環の実行スレッド

    // 受付と接続状態
    std::mutex mutex_;                  ///< 接続状態と遅延設定を保護するミューテックス
    std::vector<int> clientFds_;        ///< 接続中記述子の一覧
    std::vector<std::thread> workers_;  ///< 接続別作業スレッドの一覧
    std::map<int, int> delaysMs_;       ///< 接続番号別の応答遅延設定
    int connCount_ = 0;                 ///< 受付順の接続番号
    std::atomic<bool> stop_{false};     ///< 受付停止フラグ
};

/**
 * @brief 時間切れ後の遅延応答が解釈されないことを検証する
 *
 * 初回要求を時間切れさせて破棄し遅延書込の到着を待った後、次回要求が新規接続で新鮮な応答だけを見ることを確認する
 */
void lateResponseNeverParsedAfterTimeout() {
    char directoryTemplate[] = "/tmp/hazkey-transact-safety-test-A-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath =
        root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    // テストを短時間で終えるため読取待機を1秒にするが、検証対象の仕組みは既定値と同じである
    HazkeyServerConnector::setTestReadTimeoutSeconds(1);

    {
        DelayableFakeServer server(socketPath);

        // 接続器の構築時に確立する1番目の接続は、1秒の読取待機より遅く応答する
        server.setResponseDelayMs(1, 2000);

        HazkeyServerConnector connector;

        const auto firstResponse = connector.transact(makeCandidatesRequest());
        CHECK(!firstResponse.has_value());  // タイムアウトしたソケットは破棄して解釈しない

        // 1番目の遅延書込を閉じたソケットへ到達させ、以後の検証と競合しないよう待機する
        std::this_thread::sleep_for(std::chrono::milliseconds(2200));

        // 次の要求は新しい2番目の接続だけを使用して、その即時応答だけを受け取る
        const auto secondResponse = connector.transact(makeCandidatesRequest());
        CHECK(secondResponse.has_value());
        CHECK(secondResponse->status() == hazkey::SUCCESS);
        CHECK(secondResponse->candidates().candidates(0).text() == "STAMP-2");
    }

    HazkeyServerConnector::clearTestHooks();
    std::filesystem::remove_all(root);
    std::cout << "[PASS] late response on a timed-out connection is never "
                 "parsed; next request reconnects fresh"
              << std::endl;
}

/**
 * @brief 検査用起動子の呼び出し記録を表す
 *
 * 強制再起動の有無だけを保持して、接続試行列の挙動検証に使用する
 */
struct SpawnCall {
    bool force;  ///< 強制再起動付きの起動要求であるか
};

/**
 * @brief 成功歴なしでは強制再起動が残ることを検証する
 *
 * 応答歴のない接続器が全試行で失敗した時に、非強制の初回起動と強制再起動の両方が記録されることを確認する
 * 完全停止した実サーバ相当でも再起動が行われる前提を保証する
 */
void forceRestartStillFiresForNeverSuccessfulConnector() {
    std::vector<SpawnCall> calls;
    HazkeyServerConnector::setTestStartServerHook([&calls](bool force) { calls.push_back({force}); });

    char directoryTemplate[] = "/tmp/hazkey-transact-safety-test-B1-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);

    // 待受けソケットを作らず、再試行中の全接続試行を失敗させる
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    { HazkeyServerConnector connector; }  // 全再試行が終わるまで待機する

    bool sawNonForced = false;
    bool sawForced = false;
    for (const auto& call : calls) {
        if (call.force) {
            sawForced = true;
        } else {
            sawNonForced = true;
        }
    }
    CHECK(sawNonForced);  // 初回は通常起動を試す
    CHECK(sawForced);     // 成功歴がないため強制再起動も試す

    HazkeyServerConnector::setTestStartServerHook(nullptr);
    std::filesystem::remove_all(root);
    std::cout << "[PASS] force-restart still fires for a connector that "
                 "never had a successful transaction"
              << std::endl;
}

/**
 * @brief 成功直後の強制再起動の抑止と再開を検証する
 *
 * 1度成功した接続器が相手喪失後に再接続を試みた時に、実運用窓では強制再起動が抑えられ短縮窓では再び行われることを確認する
 * 混雑時の低速受付と実停止の区別が要点である
 */
void forceRestartWindowGatesRecentSuccess() {
    char directoryTemplate[] = "/tmp/hazkey-transact-safety-test-B23-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    CHECK(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath = root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
    CHECK(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);
    HazkeyServerConnector::setTestReadTimeoutSeconds(1);

    std::vector<SpawnCall> calls;
    HazkeyServerConnector::setTestStartServerHook([&calls](bool force) { calls.push_back({force}); });

    std::unique_ptr<HazkeyServerConnector> connector;
    {
        // 接続器の構築前に模擬サーバを待受状態にして、実在しないパスへの再試行消費を防ぐ
        DelayableFakeServer server(socketPath);
        connector = std::make_unique<HazkeyServerConnector>();
        const auto response = connector->transact(makeCandidatesRequest());
        CHECK(response.has_value());
        CHECK(response->status() == hazkey::SUCCESS);

        // ブロック終了で模擬サーバを破棄して、待受けと接続済みソケットを閉じる
        // この時点で接続器のソケットは古くなる
    }

    // ケース2では、既定の5秒競合待機時間が直前の成功からの再試行時間を覆うため、強制再起動を抑止する
    calls.clear();
    HazkeyServerConnector::setTestForceRestartWindowMs(-1);

    // 2回呼び出し、接続経路を少なくとも1回は最後まで実行する
    // 書込失敗と読取タイムアウトのどちらでも接続解除後の2回目で再接続を試みる
    connector->transact(makeCandidatesRequest());
    const auto caseTwoResponse = connector->transact(makeCandidatesRequest());
    CHECK(!caseTwoResponse.has_value());  // 待受けが無いため全再試行が失敗する
    bool caseTwoForced = false;
    for (const auto& call : calls) {
        if (call.force) caseTwoForced = true;
    }
    CHECK(!caseTwoForced);
    std::cout << "[PASS] force-restart suppressed for a server that "
                 "answered within the contention window"
              << std::endl;

    // ケース3では、待機時間を4回目の接続試行までの時間より短くして、同じ待受けなし状態で強制再起動を再開する
    calls.clear();
    HazkeyServerConnector::setTestForceRestartWindowMs(50);
    connector->transact(makeCandidatesRequest());
    const auto caseThreeResponse = connector->transact(makeCandidatesRequest());
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

/**
 * @brief 通信安全の全検証を順に実行する
 *
 * 遅延応答破棄と成功歴なしの強制再起動と成功直後の抑止再開を呼び出して、成功を報告する
 */
int main() {
    // 検証Aではクライアントが閉じたソケットへ書き込むため、SIGPIPEを無視してEPIPEとして扱う
    signal(SIGPIPE, SIG_IGN);

    lateResponseNeverParsedAfterTimeout();
    forceRestartStillFiresForNeverSuccessfulConnector();
    forceRestartWindowGatesRecentSuccess();

    std::cout
        << "[PASS] hazkey_client_transact_safety_test: all scenarios green"
        << std::endl;
    return 0;
}

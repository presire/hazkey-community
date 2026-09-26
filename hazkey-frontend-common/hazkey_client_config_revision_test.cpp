/**
 * @file hazkey_client_config_revision_test.cpp
 * @brief 設定改訂検出の一回通知検証をまとめる
 *
 * 初回観測を基準として増加を一回だけ報告することと不変では報告しないことと
 * 初期化相当も変化として報告することを模擬サーバで確認する
 *
 * 通常応答に載る改訂番号だけを使い実サーバは起動しない
 */

// HazkeyServerConnectorが通常応答の設定リビジョン変化を検出して、1回だけ通知することを検証する
// フロントエンドは、設定適用直後にキャッシュ済みプロファイルを再読込できる

#include <arpa/inet.h>
#include <assert.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include "hazkey_server_connector.h"

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
 * @brief 改訂番号付き応答を返すプロセス内模擬サーバ
 *
 * 現在の改訂番号を全応答へ載せて返して、検証側が基準と増加と不変と初期化を順に確認できるようにする
 */
class RevisionServer {
   public:
    /**
     * @brief 模擬ソケットを開設して応答循環を起動する
     *
     * 指定パスのUNIXソケットを作成して待ち受けを開始して、応答循環を別スレッドで動かす
     */
    explicit RevisionServer(const std::string& path) : path_(path) {
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
    ~RevisionServer() {
        if (listenFd_ >= 0) {
            close(listenFd_);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        unlink(path_.c_str());
    }

    /**
     * @brief 次回以降の応答へ載せる改訂番号を設定する
     *
     * 基準と増加と不変と初期化相当の各段階を再現するために、検証の合間で値を切り替える
     */
    void setRevision(uint64_t revision) {
        std::lock_guard<std::mutex> lock(mutex_);
        revision_ = revision;
    }

   private:
    /**
     * @brief 一接続分の要求応答循環を処理する
     *
     * 設定取得相当の成功応答へ現在の改訂番号を載せて返して、切断まで繰り返す
     */
    void serve() {
        const int clientFd = accept(listenFd_, nullptr, nullptr);
        if (clientFd < 0) {
            return;
        }
        timeval timeout = {2, 0};
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
            uint64_t revision = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                revision = revision_;
            }
            hazkey::ResponseEnvelope response;
            response.set_status(hazkey::SUCCESS);
            response.mutable_current_config();
            response.set_config_revision(revision);
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

    int listenFd_ = -1;         ///< 待受けソケット記述子
    std::string path_;          ///< 模擬ソケットの配置パス
    std::thread thread_;        ///< 応答循環の実行スレッド
    mutable std::mutex mutex_;  ///< 改訂番号を保護するミューテックス
    uint64_t revision_ = 0;     ///< 現在の模擬改訂番号
};

}  // namespace

/**
 * @brief 設定改訂検出の全段階を順に実行する
 *
 * 基準確定と増加の一回通知と不変の非通知と初期化の変化通知を確認して、成功を報告する
 */
int main() {
    char directoryTemplate[] = "/tmp/hazkey-config-revision-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    assert(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath =
        root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
    assert(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    RevisionServer server(socketPath);
    server.setRevision(5);

    HazkeyServerConnector connector;

    // 初回に観測したリビジョンは基準値として記録するだけである
    assert(connector.getServerConfig().has_value());
    assert(connector.configRevision() == 5);
    assert(!connector.consumeConfigChanged());

    // リビジョン増加は1回だけ通知する
    server.setRevision(6);
    assert(connector.getServerConfig().has_value());
    assert(connector.consumeConfigChanged());
    assert(!connector.consumeConfigChanged());

    // 変化しないリビジョンは通知しない
    assert(connector.getServerConfig().has_value());
    assert(!connector.consumeConfigChanged());

    // サーバ再起動によるリセットも変化として扱う
    server.setRevision(0);
    assert(connector.getServerConfig().has_value());
    assert(connector.consumeConfigChanged());

    std::cout << "[PASS] config revision change detection\n";
    return 0;
}

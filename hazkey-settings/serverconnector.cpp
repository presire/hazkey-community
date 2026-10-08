/**
 * @file serverconnector.cpp
 * @brief ServerConnectorのUNIXドメインソケット搬送実装
 *
 * ヘッダで宣言した設定RPCに加え、長さプレフィックス付きprotobufの送受信、接続リトライ、セッションソケットの寿命管理を実装する
 */

#include "serverconnector.h"
#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <qcontainerfwd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <QCoreApplication>
#include <QDir>
#include <QMessageBox>
#include <QProcess>
#include <algorithm>
#include <chrono>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include "constants.h"
#include "qdir.h"
#include "qlogging.h"

/**
 * @brief ServerConnectorのソケット操作を直列化する内部ミューテックス
 * @internal 翻訳単位内の実装詳細
 *           通常のRPCとセッション操作が共有する
 */
static std::mutex transact_mutex;

ServerConnector::ServerConnector() : session_socket_(-1) {}

ServerConnector::~ServerConnector() { endSession(); }

namespace {

/**
 * @brief ディレクトリが現在のユーザ専有 (所有者一致かつgroup/other権限なし) かを判定する
 * @param path 検査するパス
 * @param followSymlink trueならstat (リンクを辿る)、falseならlstat (リンク自体を検査して拒否する)
 */
bool isPrivateOwnDirectory(const std::string& path, bool followSymlink) {
    struct stat st{};
    const int rc = followSymlink ? stat(path.c_str(), &st)
                                 : lstat(path.c_str(), &st);
    return rc == 0 && S_ISDIR(st.st_mode) && st.st_uid == getuid() &&
           (st.st_mode & 0077) == 0;
}

/**
 * @brief 接続済みソケットの相手プロセスが同一ユーザであることを確認する
 */
bool peerIsCurrentUser(int sock) {
    struct ucred cred{};
    socklen_t len = sizeof(cred);
    if (getsockopt(sock, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0 ||
        len != sizeof(cred)) {
        return false;
    }
    return cred.uid == getuid();
}

using Deadline = std::chrono::steady_clock::time_point;

Deadline deadlineAfter(int timeoutMs) {
    return std::chrono::steady_clock::now() +
           std::chrono::milliseconds(timeoutMs);
}

/**
 * @brief pollでfdのイベントを期限まで待つ (EINTRでは残り時間で再開する)
 * @return 正ならイベントあり、0ならタイムアウト、負ならエラー
 */
int pollFd(int fd, short events, Deadline deadline) {
    for (;;) {
        struct pollfd pfd{};
        pfd.fd = fd;
        pfd.events = events;
        const auto remaining =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now())
                .count();
        const int r = poll(&pfd, 1, remaining > 0 ? static_cast<int>(remaining) : 0);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        return r;
    }
}

/**
 * @brief 非ブロッキングで接続し、相手が同一ユーザであることを確認する
 * @param socketPath sun_pathに収まることを呼び出し側が保証したソケットパス
 * @return 認証済みの接続ソケット、失敗時は-1 (ソケットは閉じ済み)
 */
int connectAndAuthenticate(const std::string& socketPath) {
    const int sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (sock < 0) {
        return -1;
    }

    const int flags = fcntl(sock, F_GETFL, 0);
    if (flags < 0 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(sock);
        return -1;
    }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, socketPath.c_str(), socketPath.size() + 1);

    bool connected = false;
    if (connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
        connected = true;
    } else if (errno == EINPROGRESS &&
               pollFd(sock, POLLOUT, deadlineAfter(2000)) > 0) {
        int so_error = 0;
        socklen_t len = sizeof(so_error);
        connected = getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len) ==
                        0 &&
                    so_error == 0;
    }

    if (!connected || !peerIsCurrentUser(sock)) {
        close(sock);
        return -1;
    }
    return sock;
}

}  // namespace

std::string ServerConnector::getSocketPath() {
    const uid_t uid = getuid();
    const std::string sockname =
        "hazkey-community-server." + std::to_string(uid) + ".sock";

    std::string runtimeDir;
    const char* xdg_runtime_dir = std::getenv("XDG_RUNTIME_DIR");
    if (xdg_runtime_dir && xdg_runtime_dir[0] != '\0' &&
        isPrivateOwnDirectory(xdg_runtime_dir, true)) {
        runtimeDir = xdg_runtime_dir;
    } else {
        // GUIはこのディレクトリを作らない (サーバが作成する)。未作成や不信頼なら接続失敗にする
        runtimeDir = "/tmp/hazkey-community-runtime-" + std::to_string(uid);
        if (!isPrivateOwnDirectory(runtimeDir, false)) {
            return std::string();
        }
    }
    return runtimeDir + "/" + sockname;
}

/**
 * @brief 指定バイト数をソケットへ書き切る内部ヘルパー
 *
 * 部分書き込みを繰り返し、EAGAIN/EWOULDBLOCKでは書き込み可能になるまで期限まで待つ
 * その他の書き込みエラーまたは期限切れでは失敗する
 * send(MSG_NOSIGNAL)を使うため、相手がソケットを閉じていてもSIGPIPEでプロセスは終了せず、falseを返す
 * この関数はソケットを閉じず、呼び出し元が所有権を保持する
 *
 * @param fd 書き込み対象のソケットディスクリプター
 * @param data 送信バッファ
 * @param len 送信するバイト数
 * @param deadline フレーム全体の絶対期限 (少しずつ受け取る相手でも延長しない)
 * @return lenバイトを書き終えた場合はtrue、それ以外はfalse
 * @internal ServerConnectorのフレーム搬送専用
 */
bool writeAll(int fd, const void* data, size_t len, Deadline deadline) {
    size_t sent = 0;
    while (sent < len) {
        // MSG_NOSIGNAL: 相手が閉じたソケットへの書き込みでSIGPIPEを受け取らず、EPIPEで失敗として扱う
        ssize_t n = send(fd, (const char*)data + sent, len - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (pollFd(fd, POLLOUT, deadline) <= 0) {
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

/**
 * @brief 指定バイト数をソケットから読み切る内部ヘルパー
 *
 * 部分読み込みを繰り返し、EAGAIN/EWOULDBLOCKでは読み込み可能になるまで期限まで待つ
 * その他の読み込みエラー、期限切れ、またはEOFでは失敗する
 * この関数はソケットを閉じず、呼び出し元が所有権を保持する
 *
 * @param fd 読み込み元のソケットディスクリプター
 * @param data 受信バッファ
 * @param len 受信するバイト数
 * @param deadline フレーム全体の絶対期限 (少しずつ送る相手でも延長しない)
 * @return lenバイトを読み終えた場合はtrue、それ以外はfalse
 * @internal ServerConnectorのフレーム搬送専用
 */
bool readAll(int fd, void* data, size_t len, Deadline deadline) {
    size_t recved = 0;
    while (recved < len) {
        ssize_t n = read(fd, (char*)data + recved, len - recved);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (pollFd(fd, POLLIN, deadline) <= 0) {
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

int ServerConnector::createConnection() {
    // try restarting server only 1 time
    // on 1st attempt (minus 1)
    constexpr int ATTEMPT_TRY_START = 0;
    // on 4th attempt (minus 1)
    constexpr int ATTEMPT_TRY_START_FORCE = 3;

    constexpr int MAX_RETRIES = 8;
    constexpr int RETRY_INTERVAL_MS = 250;

    for (int attempt = 0; attempt < MAX_RETRIES; ++attempt) {
        // サーバが起動後にランタイムディレクトリを作るため、毎回パスを解決し直す
        const std::string socket_path = getSocketPath();
        if (socket_path.size() >= sizeof(sockaddr_un::sun_path)) {
            return -1;
        }

        const int sock = socket_path.empty()
                             ? -1
                             : connectAndAuthenticate(socket_path);
        if (sock >= 0) {
            return sock;
        }
        if (attempt == ATTEMPT_TRY_START) {
            QProcess::startDetached(QString::fromUtf8(HAZKEY_SERVER_EXECUTABLE_PATH), {}, "/");
        } else if (attempt == ATTEMPT_TRY_START_FORCE) {
            QProcess::startDetached(QString::fromUtf8(HAZKEY_SERVER_EXECUTABLE_PATH), {"-r"}, "/");
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(RETRY_INTERVAL_MS));
    }
    return -1;
}

std::optional<hazkey::ResponseEnvelope> ServerConnector::transactOnSocket(
    int sock, const hazkey::RequestEnvelope& send_data, int readTimeoutSeconds) {
    std::string msg;
    if (!send_data.SerializeToString(&msg)) {
        return std::nullopt;
    }

    // 要求フレーム (長さ+本体) は2秒、応答フレームはreadTimeoutSeconds秒の期限で送受信する
    const Deadline writeDeadline = deadlineAfter(2000);

    // write length
    uint32_t writeLen = htonl(msg.size());
    if (!writeAll(sock, &writeLen, 4, writeDeadline)) {
        return std::nullopt;
    }

    // write data
    if (!writeAll(sock, msg.c_str(), msg.size(), writeDeadline)) {
        return std::nullopt;
    }

    const Deadline readDeadline = deadlineAfter(readTimeoutSeconds * 1000);

    // read response length
    uint32_t readLenBuf;
    if (!readAll(sock, &readLenBuf, 4, readDeadline)) {
        return std::nullopt;
    }

    uint32_t readLen = ntohl(readLenBuf);

    if (readLen > 2 * 1024 * 1024) {  // 2MB limit
        return std::nullopt;
    }

    // read response
    std::vector<char> buf(readLen);
    if (!readAll(sock, buf.data(), readLen, readDeadline)) {
        return std::nullopt;
    }

    hazkey::ResponseEnvelope resp;
    if (!resp.ParseFromArray(buf.data(), readLen)) {
        return std::nullopt;
    }

    return resp;
}

std::optional<hazkey::ResponseEnvelope> ServerConnector::transact(
    const hazkey::RequestEnvelope& send_data, int readTimeoutSeconds) {
    std::lock_guard<std::mutex> lock(transact_mutex);

    // Create new connection for each transaction
    int sock = createConnection();
    if (sock == -1) {
        return std::nullopt;
    }

    auto resp = transactOnSocket(sock, send_data, readTimeoutSeconds);

    // Close connection after transaction
    close(sock);
    return resp;
}

bool ServerConnector::beginSession() {
    std::lock_guard<std::mutex> lock(transact_mutex);

    // Close existing session if any
    if (session_socket_ != -1) {
        close(session_socket_);
        session_socket_ = -1;
    }

    session_socket_ = createConnection();
    return session_socket_ != -1;
}

void ServerConnector::endSession() {
    std::lock_guard<std::mutex> lock(transact_mutex);

    if (session_socket_ != -1) {
        close(session_socket_);
        session_socket_ = -1;
    }
}

std::optional<hazkey::config::CurrentConfig>
ServerConnector::getConfigInSession() {
    std::lock_guard<std::mutex> lock(transact_mutex);

    if (session_socket_ == -1) {
        return std::nullopt;
    }

    hazkey::RequestEnvelope request;
    auto _ = request.mutable_get_config();
    auto response = transactOnSocket(session_socket_, request);
    if (response == std::nullopt) {
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        return std::nullopt;
    }
    if (!responseVal.has_current_config()) {
        return std::nullopt;
    }
    return responseVal.current_config();
}

std::optional<hazkey::config::CurrentConfig>
ServerConnector::getDefaultProfileInSession() {
    std::lock_guard<std::mutex> lock(transact_mutex);

    if (session_socket_ == -1) {
        return std::nullopt;
    }

    hazkey::RequestEnvelope request;
    auto _ = request.mutable_get_default_profile();
    auto response = transactOnSocket(session_socket_, request);
    if (response == std::nullopt) {
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        return std::nullopt;
    }
    if (!responseVal.has_current_config()) {
        return std::nullopt;
    }
    return responseVal.current_config();
}

bool ServerConnector::reloadZenzaiModelInSession() {
    std::lock_guard<std::mutex> lock(transact_mutex);

    if (session_socket_ == -1) {
        return false;
    }

    hazkey::RequestEnvelope request;
    auto _ = request.mutable_reload_zenzai_model();
    auto response = transactOnSocket(session_socket_, request);
    if (response == std::nullopt) {
        return false;
    }
    auto responseVal = response.value();
    return responseVal.status() == hazkey::SUCCESS;
}

std::optional<hazkey::config::CurrentConfig> ServerConnector::getConfig() {
    hazkey::RequestEnvelope request;
    auto _ = request.mutable_get_config();
    auto response = transact(request, kZenzaiReloadReadTimeoutSeconds);
    if (response == std::nullopt) {
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        return std::nullopt;
    }
    if (!responseVal.has_current_config()) {
        return std::nullopt;
    }
    return responseVal.current_config();
}

std::optional<hazkey::config::CurrentConfig>
ServerConnector::getDefaultProfile() {
    hazkey::RequestEnvelope request;
    auto _ = request.mutable_get_default_profile();
    auto response = transact(request);
    if (response == std::nullopt) {
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        return std::nullopt;
    }
    if (!responseVal.has_current_config()) {
        return std::nullopt;
    }
    return responseVal.current_config();
}

void ServerConnector::setCurrentConfig(
    hazkey::config::CurrentConfig currentConfig) {
    hazkey::RequestEnvelope request;
    auto props = request.mutable_set_config();
    *props->mutable_profiles() = currentConfig.profiles();
    auto response = transact(request);
    if (response == std::nullopt) {
        throw std::runtime_error(
            "Failed to communicate with the hazkey-community-server while saving configuration.");
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        const std::string errorMessage = responseVal.error_message();
        throw std::runtime_error(
            errorMessage.empty() ? "The hazkey-community-server rejected the configuration."
                                 : errorMessage);
    }
}

bool ServerConnector::clearAllHistory(const std::string& profileId) {
    hazkey::RequestEnvelope request;
    auto clearRequest = request.mutable_clear_all_history();
    clearRequest->set_profile_id(profileId);
    auto response = transact(request);
    if (response == std::nullopt) {
        return false;
    }
    auto responseVal = response.value();
    return responseVal.status() == hazkey::SUCCESS;
}

std::optional<hazkey::config::GetLearningHistoryResult>
ServerConnector::getLearningHistory(const std::string& profileId,
                                    const std::string& query, uint32_t offset,
                                    uint32_t limit) {
    hazkey::RequestEnvelope request;
    auto* historyRequest = request.mutable_get_learning_history();
    historyRequest->set_profile_id(profileId);
    historyRequest->set_query(query);
    historyRequest->set_offset(offset);
    historyRequest->set_limit(std::clamp(limit, uint32_t{1}, uint32_t{200}));
    auto response = transact(request);
    if (response == std::nullopt) {
        return std::nullopt;
    }
    const auto& responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS ||
        !responseVal.has_get_learning_history_result()) {
        return std::nullopt;
    }
    return responseVal.get_learning_history_result();
}

std::optional<uint32_t> ServerConnector::deleteLearningEntries(
    const std::string& profileId,
    const std::vector<hazkey::config::LearningEntryKey>& entries) {
    hazkey::RequestEnvelope request;
    auto* deleteRequest = request.mutable_delete_learning_entries();
    deleteRequest->set_profile_id(profileId);
    for (const auto& entry : entries) {
        *deleteRequest->add_entries() = entry;
    }
    auto response = transact(request);
    if (response == std::nullopt) {
        return std::nullopt;
    }
    const auto& responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS ||
        !responseVal.has_delete_learning_entries_result()) {
        return std::nullopt;
    }
    return responseVal.delete_learning_entries_result().deleted_count();
}

bool ServerConnector::reloadZenzaiModel() {
    hazkey::RequestEnvelope request;
    auto _ = request.mutable_reload_zenzai_model();
    auto response = transact(request, kZenzaiReloadReadTimeoutSeconds);
    if (response == std::nullopt) {
        return false;
    }
    auto responseVal = response.value();
    return responseVal.status() == hazkey::SUCCESS;
}

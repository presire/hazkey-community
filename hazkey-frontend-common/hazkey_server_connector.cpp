/**
 * @file hazkey_server_connector.cpp
 * @brief 共有サーバ接続クラスの実装をまとめる
 *
 * 宣言側の仕様はhazkey_server_connector.hに置き、このファイルでは無名名前空間補助と送受信補助だけに文書を付ける
 * 定義済み方式の再掲は行わない
 */

#include "hazkey_server_connector.h"
#include <arpa/inet.h>
#include <dirent.h>
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
#include <vector>
#include "base.pb.h"
#include "commands.pb.h"
#include "config.pb.h"

// 通信層のログは注入されたフロントエンドのログ出力先へ送る
// 既定の出力先は何も行わず、ストリーム形式は従来のFCITXマクロと同じ
#define HAZKEY_LOG_DEBUG() \
    ::hazkey::frontend::LogStream(::hazkey::frontend::LogLevel::Debug)
#define HAZKEY_LOG_INFO() \
    ::hazkey::frontend::LogStream(::hazkey::frontend::LogLevel::Info)
#define HAZKEY_LOG_ERROR() \
    ::hazkey::frontend::LogStream(::hazkey::frontend::LogLevel::Error)

/**
 * @brief transact呼出しを全インスタンスで直列化する静的ミューテックス
 *
 * サーバ単一スレッドとの対応を保つため、送受信全体を直列化する
 */
static std::mutex transact_mutex;

/** @brief この実装ファイルだけで使用する補助要素を隠す無名名前空間 */
namespace {

/**
 * @brief 要求封筒から計測用種別名を返す
 *
 * @param request 種別判定対象の要求封筒
 * @return payloadに対応する種別名で未設定時はnone
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
 * @class ClientPerfMeasurement
 * @brief transact1回分の処理時間を計測する無名名前空間補助
 *
 * 環境変数HAZKEY_PERF_EVIDENCEが空なら何も記録しない
 * 設定済みなら種別名と処理時間をJSON1行で追記する
 */
class ClientPerfMeasurement {
   public:
    /**
     * @brief 計測対象の要求種別と開始時刻を記録する
     *
     * @param request 計測対象の要求封筒
     */
    explicit ClientPerfMeasurement(const hazkey::RequestEnvelope& request) {
        const char* path = std::getenv("HAZKEY_PERF_EVIDENCE");
        if (path == nullptr || path[0] == '\0') {
            return;
        }
        path_ = path;
        type_ = requestType(request);
        startedAt_ = std::chrono::steady_clock::now();
    }

    /**
     * @brief 経過時間を証跡ファイルへ1行追記して計測を終える
     *
     * 未設定時は追記しない
     */
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
    // 計測時刻
    std::chrono::steady_clock::time_point startedAt_;  ///< 計測開始時刻

    // 証跡の出力先
    std::string path_;                                 ///< 証跡ファイルパスで未設定時は空
    std::string type_;                                 ///< 要求種別名
};

}  // namespace

/**
 * @brief 必要に応じてサーバへ接続するコネクターを構築する
 * @param autoConnect trueなら構築時に接続する
 */
HazkeyServerConnector::HazkeyServerConnector(bool autoConnect) {
    if (autoConnect) {
        connectServer();
    }
    HAZKEY_LOG_DEBUG() << "Connector initialized";
}

/** @brief 所有するソケット記述子を閉じる */
HazkeyServerConnector::~HazkeyServerConnector() {
    // sock_を所有し、破棄時に閉じて記述子のリークを防ぐ
    // 失敗経路は、クローズ後にsock_を-1へ戻すため、有効な記述子は1度だけ閉じる
    if (sock_ >= 0) {
        close(sock_);
        sock_ = -1;
    }
}

/**
 * @brief サーバのUNIXドメインソケットパスを返す
 * @return XDG_RUNTIME_DIR または /tmp配下のソケットパス
 */
std::string HazkeyServerConnector::getSocketPath() {
    const char* xdg_runtime_dir = std::getenv("XDG_RUNTIME_DIR");
    uid_t uid = getuid();
    std::string sockname =
        "hazkey-community-server." + std::to_string(uid) + ".sock";
    if (xdg_runtime_dir && xdg_runtime_dir[0] != '\0') {
        return std::string(xdg_runtime_dir) + "/" + sockname;
    } else {
        return "/tmp/" + sockname;
    }
}

/**
 * @brief 注入済みの処理でhazkey-community-serverの起動を要求する
 * @param force_restart trueなら強制再起動を要求する
 */
void HazkeyServerConnector::startHazkeyServer(bool force_restart) {
    // 試験用フックがあれば実プロセスを起動せず、起動判断だけを観測する
    // 未設定時は注入済みフロントエンドの起動処理を使う
    if (testStartServerHook_) {
        testStartServerHook_(force_restart);
        return;
    }
    hazkey::frontend::spawnServer(force_restart);
}

/**
 * @brief 指定記述子へ全バイトを書き込む
 *
 * @param fd 書き込み先の接続記述子
 * @param data 送信する先頭位置
 * @param len 送信するバイト数
 * @return 全バイト送信できた場合はtrue
 * @details 書込待ちは2秒で切り上げる
 *          失敗時は呼び出し側が再接続を担う
 */
bool writeAll(int fd, const void* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, (const char*)data + sent, len - sent);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(fd, &wfds);
                timeval tv = {2, 0};  // 書き込み待機の上限は2秒
                int r = select(fd + 1, NULL, &wfds, NULL, &tv);
                if (r <= 0) {
                    HAZKEY_LOG_ERROR() << "write timeout";
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
 * @brief 指定記述子から指定バイト数を読み込む
 *
 * @param fd 読み込み元の接続記述子
 * @param data 受信内容の格納先
 * @param len 読み込むバイト数
 * @param timeoutSeconds 読取待ち上限の秒数で製品経路は常に10秒
 * @return 指定数を読み切った場合はtrue
 * @details 試験用フック設定時だけ短縮値で待機路を検証する
 *          応答遅延上限を超えた到着は停止と区別しない
 */
bool readAll(int fd, void* data, size_t len, int timeoutSeconds) {
    size_t recved = 0;
    while (recved < len) {
        ssize_t n = read(fd, (char*)data + recved, len - recved);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fd_set rfds;
                FD_ZERO(&rfds);
                FD_SET(fd, &rfds);
                timeval tv = {timeoutSeconds, 0};  // 読み取り待機の上限
                int r = select(fd + 1, &rfds, NULL, NULL, &tv);
                if (r <= 0) {
                    HAZKEY_LOG_ERROR() << "read timeout";
                    return false;
                }
                continue;
            }
            return false;
        }
        if (n == 0) return false;  // 接続先が閉じた
        recved += n;
    }
    return true;
}

/**
 * @brief サーバへの非ブロッキング接続を確立する
 * @details 接続失敗時は、通常起動または必要に応じた強制再起動を試みる
 */
void HazkeyServerConnector::connectServer() {
    std::string socket_path = getSocketPath();

    // 通常起動は最初の失敗後に1回だけ試す
    constexpr int ATTEMPT_TRY_START = 0;

    // 強制再起動は4回目の失敗後に検討する
    constexpr int ATTEMPT_TRY_START_FORCE = 3;

    constexpr int MAX_RETRIES = 8;
    constexpr int RETRY_INTERVAL_MS = 250;

    int attempt;
    for (attempt = 0; attempt < MAX_RETRIES; ++attempt) {
        sock_ = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock_ < 0) {
            HAZKEY_LOG_ERROR() << "Failed to create socket";
            std::this_thread::sleep_for(
                std::chrono::milliseconds(RETRY_INTERVAL_MS));
            continue;
        }
        int fcntlRes =
            fcntl(sock_, F_SETFL, fcntl(sock_, F_GETFL, 0) | O_NONBLOCK);
        if (fcntlRes != 0) {
            HAZKEY_LOG_ERROR() << "fcntl() failed";
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
            // 接続成功
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
                    // 接続成功
                    return;
                }
            }
        }
        HAZKEY_LOG_INFO() << "Failed to connect hazkey-server, retry "
                     << (attempt + 1);
        close(sock_);
        sock_ = -1;
        if (attempt == ATTEMPT_TRY_START) {
            // 停止したサーバには通常起動を1回だけ要求する
            startHazkeyServer(false);
        } else if (attempt == ATTEMPT_TRY_START_FORCE) {
            // 直近に応答したサーバはCPU負荷で受理が遅いだけの可能性がある
            // 1度も応答していないか、しばらく応答がなければ強制再起動する
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
                HAZKEY_LOG_INFO()
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
    HAZKEY_LOG_INFO() << "Failed to connect hazkey-server after " << MAX_RETRIES
                 << " attempts";
}

/** @brief 全ての読み取りキャッシュを無効化する */
void HazkeyServerConnector::invalidateCache() {
    cachedHiraganaWithCursor_.reset();
    cachedComposingText_.clear();
    cachedCandidatesSuggest_.reset();
    cachedCandidatesFull_.reset();
    cachedInputModeDirect_.reset();
}

/**
 * @brief 1回のRPCを送受信する
 * @param send_data 送信するリクエスト
 * @param tryConnect falseなら接続とサーバ起動を試みない
 * @return パース済みの応答、通信またはパース失敗時はstd::nullopt
 */
std::optional<hazkey::ResponseEnvelope> HazkeyServerConnector::transact(
    const hazkey::RequestEnvelope& send_data, bool tryConnect) {
    ClientPerfMeasurement perfMeasurement(send_data);
    std::lock_guard<std::mutex> lock(transact_mutex);

    if (sock_ == -1) {
        if (!tryConnect) {
            HAZKEY_LOG_INFO() << "Socket not connected. Aborting transact without reconnecting.";
            return std::nullopt;
        }
        HAZKEY_LOG_INFO() << "Socket not connected, attempting to connect...";
        connectServer();
        if (sock_ == -1) {
            HAZKEY_LOG_ERROR() << "Failed to establish connection to hazkey-server";
            return std::nullopt;
        }
        // 未接続中にサーバが再起動した可能性があるためキャッシュを破棄する
        invalidateCache();
    }

    std::string msg;
    if (!send_data.SerializeToString(&msg)) {
        HAZKEY_LOG_ERROR() << "Failed to serialize protobuf message.";
        return std::nullopt;
    }

    HAZKEY_LOG_DEBUG() << "Sending message of size: " << msg.size();

    // フレーム長を書き込む
    uint32_t writeLen = htonl(msg.size());
    if (!writeAll(sock_, &writeLen, 4)) {
        close(sock_);
        sock_ = -1;
        if (tryConnect) {
            HAZKEY_LOG_INFO()
                << "Failed to communicate with server while writing data length. "
                   "reconnecting to hazkey-community-server...";
            connectServer();
            // 再接続後は、サーバ再起動の可能性があるためキャッシュを破棄する
            invalidateCache();
        }
        return std::nullopt;
    }

    // protobuf本体を書き込む
    if (!writeAll(sock_, msg.c_str(), msg.size())) {
        close(sock_);
        sock_ = -1;
        if (tryConnect) {
            HAZKEY_LOG_INFO() << "Failed to communicate with server while writing data. "
                            "reconnecting to hazkey-community-server...";
            connectServer();
            // 再接続後は、サーバ再起動の可能性があるためキャッシュを破棄する
            invalidateCache();
        }
        return std::nullopt;
    }

    HAZKEY_LOG_DEBUG() << "Successfully wrote data to server";

    // 製品の読み取りタイムアウトは10秒
    // 試験時だけsetTestReadTimeoutSecondsで短縮する
    constexpr int kProductionReadTimeoutSeconds = 10;
    const int readTimeoutSeconds = testReadTimeoutSeconds_ > 0
                                        ? testReadTimeoutSeconds_
                                        : kProductionReadTimeoutSeconds;

    // 応答フレーム長を読み込む
    uint32_t readLenBuf;
    if (!readAll(sock_, &readLenBuf, 4, readTimeoutSeconds)) {
        HAZKEY_LOG_ERROR() << "Failed to read buffer length.";
        close(sock_);
        sock_ = -1;
        return std::nullopt;
    }

    uint32_t readLen = ntohl(readLenBuf);
    HAZKEY_LOG_DEBUG() << "Server response size: " << readLen;

    if (readLen > 2 * 1024 * 1024) {  // 応答本体は2MBまで
        HAZKEY_LOG_ERROR() << "Response size too large: " << readLen;
        close(sock_);
        sock_ = -1;
        return std::nullopt;
    }

    std::vector<char> buf(readLen);
    if (!readAll(sock_, buf.data(), readLen, readTimeoutSeconds)) {
        HAZKEY_LOG_ERROR() << "Failed to read response body.";
        close(sock_);
        sock_ = -1;
        return std::nullopt;
    }

    hazkey::ResponseEnvelope resp;
    if (!resp.ParseFromArray(buf.data(), readLen)) {
        HAZKEY_LOG_ERROR() << "Failed to parse received data\n";
        return std::nullopt;
    }

    // リクエストと応答の送受信が完了した時刻を記録する
    // サーバ処理の成否にかかわらず通信経路は正常と判断する
    lastSuccessfulTransaction_ = std::chrono::steady_clock::now();

    HAZKEY_LOG_DEBUG() << "Successfully received and parsed response";
    recordConfigRevision(resp.config_revision());
    return resp;
}

/**
 * @brief 受信した設定リビジョンを記録する
 * @param revision 応答に含まれる設定リビジョン
 */
void HazkeyServerConnector::recordConfigRevision(uint64_t revision) {
    const uint64_t previous = lastConfigRevision_.load(std::memory_order_relaxed);
    if (configRevisionKnown_.exchange(true, std::memory_order_relaxed)) {
        if (revision != previous) {
            lastConfigRevision_.store(revision, std::memory_order_relaxed);
            configChanged_.store(true, std::memory_order_relaxed);
        }
    } else {
        lastConfigRevision_.store(revision, std::memory_order_relaxed);
    }
}

/**
 * @brief 未消費の設定変更通知を取り出す
 * @return 設定変更通知があればtrue
 */
bool HazkeyServerConnector::consumeConfigChanged() {
    return configChanged_.exchange(false, std::memory_order_relaxed);
}

/**
 * @brief 指定種別の編集中文字列を取得する
 * @param type 取得する文字種
 * @param currentPreedit 現在のpreedit文字列
 * @return 編集中文字列、失敗時は空文字列
 */
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
        HAZKEY_LOG_ERROR() << "Error while transacting getComposingText().";
        return "";
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "getComposingText: " << "Server returned an error: "
                      << responseVal.error_message();
        return "";
    }

    // 古いprotobufにはhas_textメソッドがない
    // if (!responseVal.has_text()) {
    //     HAZKEY_LOG_ERROR() << "getComposingText: "
    //                        << "Server returned unexpected response";
    //     return "";
    // }

    cachedComposingText_[cacheKey] = responseVal.text();
    return responseVal.text();
}

/**
 * @brief カーソル位置を含む生かな文字列を取得する
 * @return カーソル位置を含む文字列、失敗時は空の構造体
 */
hazkey::frontend::ComposingTextWithCursor
HazkeyServerConnector::getComposingHiraganaWithCursor() {
    if (cachedHiraganaWithCursor_.has_value()) {
        return cachedHiraganaWithCursor_.value();
    }
    hazkey::RequestEnvelope request;
    request.mutable_get_hiragana_with_cursor();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR()
            << "Error while transacting getComposingHiraganaWithCursor().";
        return hazkey::frontend::ComposingTextWithCursor{};
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "getHiraganaWithCursor: "
                           << "Server returned an error: "
                           << responseVal.error_message();
        return hazkey::frontend::ComposingTextWithCursor{};
    }
    if (!responseVal.has_text_with_cursor()) {
        HAZKEY_LOG_ERROR() << "getHiraganaWithCursor: "
                           << "Server returned unexpected response";
        return hazkey::frontend::ComposingTextWithCursor{};
    }
    cachedHiraganaWithCursor_ = hazkey::frontend::ComposingTextWithCursor{
        responseVal.text_with_cursor().beforecursosr(),
        responseVal.text_with_cursor().oncursor(),
        responseVal.text_with_cursor().aftercursor()};
    return cachedHiraganaWithCursor_.value();
}

/**
 * @brief 文字列を入力として送信する
 * @param text 入力する文字列
 */
void HazkeyServerConnector::inputChar(std::string text) {
    // 状態を変更するRPCなので既存の読み取りキャッシュは無効になる
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_input_char();
    props->set_text(text);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting inputChar().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "inputChar: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief [Shift]キーの押下または解放を送信する
 * @param isRelease trueなら解放イベント
 * @param alone 解放が単独打鍵ならtrue
 */
void HazkeyServerConnector::shiftKeyEvent(bool isRelease, bool alone) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_modifier_event();
    props->set_event_type(!isRelease
                              ? hazkey::commands::ModifierEvent_EventType_PRESS
                              : alone
                                    ? hazkey::commands::ModifierEvent_EventType_RELEASE
                                    : hazkey::commands::ModifierEvent_EventType_CANCEL);
    props->set_mod_type(hazkey::commands::ModifierEvent_ModifierType_SHIFT);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting shiftKeyEvent().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "shiftKeyEvent: " << "Server returned an error: "
                           << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief 現在の入力モードが直接入力か調べる
 * @return 直接入力ならtrue
 */
bool HazkeyServerConnector::currentInputModeIsDirect() {
    if (cachedInputModeDirect_.has_value()) {
        return cachedInputModeDirect_.value();
    }
    hazkey::RequestEnvelope request;
    auto _ = request.mutable_get_current_input_mode();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting currentInputModeIsDirect().";
        return false;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "currentInputModeIsDirect: "
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

/** @brief カーソル左の1文字を削除する */
void HazkeyServerConnector::deleteLeft() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_delete_left();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting deleteLeft().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "deleteLeft: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

/** @brief カーソル右の1文字を削除する */
void HazkeyServerConnector::deleteRight() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_delete_right();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting deleteRight().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "deleteRight: " << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief 組成中のカーソルを移動する
 * @param offset 正値なら右へ移動する量
 */
void HazkeyServerConnector::moveCursor(int offset) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_move_cursor();
    props->set_offset(offset);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting moveCursor().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "moveCursor:" << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief 文節境界を調整し候補を取得する
 * @param offset 正値なら右へ移動する量
 * @return 更新後の候補と読み、失敗時はstd::nullopt
 */
std::optional<HazkeyServerConnector::ClauseBoundaryResult>
HazkeyServerConnector::adjustClauseBoundary(int offset) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_adjust_clause_boundary();
    props->set_offset(offset);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting adjustClauseBoundary().";
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "adjustClauseBoundary: "
                      << "Server returned an error: "
                      << responseVal.error_message();
        return std::nullopt;
    }
    if (!responseVal.has_clause_boundary_result()) {
        HAZKEY_LOG_ERROR() << "adjustClauseBoundary: "
                      << "Server returned unexpected response";
        return std::nullopt;
    }

    ClauseBoundaryResult result;
    result.candidates = responseVal.clause_boundary_result().candidates();
    result.hiragana = responseVal.clause_boundary_result().hiragana();
    return result;
}

/**
 * @brief 候補の学習データを削除して、候補を取得する
 * @param index 削除対象の候補位置
 * @return 削除結果と更新後の候補、失敗時はstd::nullopt
 */
std::optional<HazkeyServerConnector::DeleteCandidateLearningDataResult>
HazkeyServerConnector::deleteCandidateLearningData(int index) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_delete_candidate_learning_data();
    props->set_index(index);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR()
            << "Error while transacting deleteCandidateLearningData().";
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "deleteCandidateLearningData: "
                           << "Server returned an error: "
                           << responseVal.error_message();
        return std::nullopt;
    }
    if (!responseVal.has_delete_candidate_learning_data_result()) {
        HAZKEY_LOG_ERROR() << "deleteCandidateLearningData: "
                           << "Server returned unexpected response";
        return std::nullopt;
    }

    DeleteCandidateLearningDataResult result;
    result.deleted_count = responseVal.delete_candidate_learning_data_result().deleted_count();
    result.candidates = responseVal.delete_candidate_learning_data_result().candidates();
    result.hiragana = responseVal.delete_candidate_learning_data_result().hiragana();
    return result;
}

/**
 * @brief 周辺文脈をサーバへ設定する
 * @param context 周辺文脈の文字列
 * @param anchor 文脈内の基準位置
 */
void HazkeyServerConnector::setContext(std::string context, int anchor) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_set_context();
    props->set_context(context);
    props->set_anchor(anchor);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting setContext().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "setContext:" << "Server returned an error: "
                           << responseVal.error_message();
        return;
    }
    return;
}

/** @brief 現在の組成を破棄して新しい組成を始める */
void HazkeyServerConnector::newComposingText() {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_new_composing_text();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR()
            << "Error while transacting createComposingTextInstance().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "createComposingTextInstance:"
                           << "Server returned an error: "
                           << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief 指定した候補で接頭辞を確定する
 * @param index 確定する候補位置
 */
void HazkeyServerConnector::completePrefix(int index) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_prefix_complete();
    props->set_index(index);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting completePrefix().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "completePrefix: " << "Server returned an error: "
                           << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief 予測候補を先頭表記として受理する
 * @param index 受理する候補位置
 * @return 受理できた場合はtrue
 */
bool HazkeyServerConnector::acceptPrediction(int index) {
    // completePrefixと異なり組成を維持するため、呼び出し側は表示を更新する
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto props = request.mutable_accept_prediction();
    props->set_index(index);
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting acceptPrediction().";
        return false;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_DEBUG() << "acceptPrediction: Server returned an error: "
                      << responseVal.error_message();
        return false;
    }
    return true;
}

/**
 * @brief Zenzaiの有効状態を切り替える
 * @return 切替後の有効状態、失敗時はstd::nullopt
 */
std::optional<bool> HazkeyServerConnector::toggleZenzai() {
    hazkey::RequestEnvelope request;
    request.mutable_toggle_zenzai();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting toggleZenzai().";
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "toggleZenzai: Server returned an error: "
                      << responseVal.error_message();
        return std::nullopt;
    }
    if (!responseVal.has_toggle_zenzai_result()) {
        HAZKEY_LOG_ERROR() << "toggleZenzai: Server returned unexpected response";
        return std::nullopt;
    }
    return responseVal.toggle_zenzai_result().enabled();
}

/**
 * @brief 保留中の学習データを保存する
 * @param tryConnect falseなら未接続時にサーバを起動しない
 */
void HazkeyServerConnector::saveLearningData(bool tryConnect) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    request.mutable_save_learning_data();
    auto response = transact(request, tryConnect);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting saveLearningData().";
        return;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "saveLearningData:"
                      << "Server returned an error: "
                      << responseVal.error_message();
        return;
    }
    return;
}

/**
 * @brief サーバの現在設定を取得する
 * @return 現在設定、失敗時はstd::nullopt
 */
std::optional<hazkey::config::CurrentConfig> HazkeyServerConnector::getServerConfig() {
    hazkey::RequestEnvelope request;
    request.mutable_get_config();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting getServerConfig().";
        return std::nullopt;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "getServerConfig: " << "Server returned an error: "
                      << responseVal.error_message();
        return std::nullopt;
    }
    return responseVal.current_config();
}

/**
 * @brief サーバの現在設定を保存する
 * @param config 保存する設定
 * @return 保存に成功した場合はtrue
 */
bool HazkeyServerConnector::setServerConfig(
    const hazkey::config::CurrentConfig& config) {
    invalidateCache();
    hazkey::RequestEnvelope request;
    auto* sc = request.mutable_set_config();
    *sc->mutable_profiles() = config.profiles();
    *sc->mutable_file_hashes() = config.file_hashes();
    auto response = transact(request);
    if (response == std::nullopt) {
        HAZKEY_LOG_ERROR() << "Error while transacting setServerConfig().";
        return false;
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "setServerConfig: " << "Server returned an error: "
                          << responseVal.error_message();
        return false;
    }
    return true;
}

/**
 * @brief 候補一覧を取得する
 * @param isSuggestMode サジェスト候補ならtrue
 * @return 候補一覧、失敗時は空の候補一覧
 */
hazkey::commands::CandidatesResult HazkeyServerConnector::getCandidates(
    bool isSuggestMode) {
    // 通常候補の要求は、組成区切りを挿入して、状態を変更するため事前にキャッシュを破棄する
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
        HAZKEY_LOG_ERROR() << "Error while transacting getCandidates().";
        std::vector<CandidateData> empty_vec;
        return hazkey::commands::CandidatesResult();
    }
    auto responseVal = response.value();
    if (responseVal.status() != hazkey::SUCCESS) {
        HAZKEY_LOG_ERROR() << "getCandidates: " << "Server returned an error: "
                      << responseVal.error_message();
        std::vector<CandidateData> empty_vec;
        return hazkey::commands::CandidatesResult();
    }

    // 応答に候補がない場合の検査はprotobufのhasメソッドに依存する
    // if (responseVal..has_candidates()) {
    //     HAZKEY_LOG_ERROR() << "getCandidates: "
    //                        << "Server returned unexpected response";
    //     std::vector<CandidateData> empty_vec;
    //     return hazkey::commands::CandidatesResult();
    // }

    cacheSlot = responseVal.candidates();
    return responseVal.candidates();
}

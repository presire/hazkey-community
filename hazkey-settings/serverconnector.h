#ifndef SERVERCONNECTOR_H
#define SERVERCONNECTOR_H

/**
 * @file serverconnector.h
 * @brief hazkey-settingsからhazkey-serverへ接続するRPCラッパー
 *
 * UNIXドメインソケット上で長さプレフィックス付きprotobufフレームを送受信し、
 * 設定GUIが使用するRPCと永続セッションを提供する
 */

#include <chrono>
#include <cstddef>
#include <atomic>
#include <mutex>
#include <optional>
#include <string>
#include <vector>
#include "base.pb.h"

/**
 * @class ServerConnector
 * @brief hazkey-serverとの設定系RPCとソケットセッションを管理する
 *
 * 通常のRPCは呼び出しごとに接続を作成し、応答の受信後にそのソケットを閉じる
 * @ref beginSession で開始したセッションでは、対応するInSessionメソッドが同じソケットを共有し、@ref endSession まで保持する
 * いずれの方式でもソケットはこのクラスが所有する
 */
class ServerConnector {
   public:
    /**
     * @brief セッションを持たないコネクターを構築する
     *
     * ソケット接続は構築時には行わない
     * 必要な接続は各RPC または @ref beginSession が遅延して作成する
     */
    ServerConnector();

    /**
     * @brief 開いている永続セッションを閉じて破棄する
     *
     * セッションが開始されていない場合も安全に何もしない
     */
    ~ServerConnector();

    /**
     * @brief 現在の設定を取得する
     *
     * このメソッドは呼び出しごとの一時接続を使用し、セッションソケットは使用しない
     *
     * @return 成功してCurrentConfigを含む応答なら設定、
     *         それ以外はstd::nullopt, std::nulloptは接続・送受信・protobufの失敗、
     *         サーバの失敗ステータス、または設定ペイロード欠落を表す
     */
    std::optional<hazkey::config::CurrentConfig> getConfig();

    /**
     * @brief サーバが返す既定プロファイルを取得する
     *
     * このメソッドは呼び出しごとの一時接続を使用し、セッションソケットは使用しない
     * 取得した値はプレビュー用であり、このRPC自体は設定を保存しない
     *
     * @return 成功してCurrentConfigを含む応答なら既定設定、それ以外はstd::nullopt
     *         std::nulloptは通信失敗、サーバの失敗ステータス、または設定ペイロード欠落を表す
     */
    std::optional<hazkey::config::CurrentConfig> getDefaultProfile();

    /**
     * @brief 現在の設定をサーバへ保存する
     *
     * currentConfigのプロファイルをSetConfig RPCとして送信する
     * このメソッドは呼び出しごとの一時接続を使用し、セッションソケットは使用しない
     *
     * @param currentConfig 保存する設定
     * @throws std::runtime_error 通信に失敗した場合、またはサーバが成功以外のステータスを返した場合
     *                            サーバのエラーメッセージが空でなければそれを、空なら汎用メッセージを例外メッセージに使用する
     */
    void setCurrentConfig(hazkey::config::CurrentConfig);

    /**
     * @brief 指定プロファイルの学習履歴をすべて削除する
     *
     * @param profileId 対象プロファイルの識別子
     * @return RPC の通信とサーバ処理が成功した場合はtrue、通信失敗またはサーバの失敗ステータスの場合はfalse
     */
    bool clearAllHistory(const std::string& profileId);

    /**
     * @brief 学習履歴をページングして取得する
     *
     * @param profileId 対象プロファイルの識別子
     * @param query 履歴の検索文字列
     * @param offset 取得開始位置
     * @param limit 最大取得件数
     *              送信時に1〜200以下へクランプされる
     * @return 成功して履歴結果を含む応答なら結果、それ以外はstd::nullopt
     *         std::nulloptは通信失敗、サーバの失敗ステータス、または履歴結果ペイロード欠落を表す
     */
    std::optional<hazkey::config::GetLearningHistoryResult> getLearningHistory(
        const std::string& profileId, const std::string& query, uint32_t offset,
        uint32_t limit);

    /**
     * @brief 指定した学習履歴エントリを削除する
     *
     * @param profileId 対象プロファイルの識別子
     * @param entries 削除対象の履歴エントリキー
     * @return 成功時はサーバが削除した件数、それ以外はstd::nullopt
     *         std::nulloptは通信失敗、サーバの失敗ステータス、または削除結果ペイロード欠落を表す
     */
    std::optional<uint32_t> deleteLearningEntries(
        const std::string& profileId,
        const std::vector<hazkey::config::LearningEntryKey>& entries);

    /**
     * @brief Zenzaiモデルの再読み込みを要求する
     *
     * このメソッドは呼び出しごとの一時接続を使用し、セッションソケットは使用しない
     *
     * @return 通信とサーバ処理が成功した場合はtrue、通信失敗またはサーバの失敗ステータスの場合はfalse
     */
    bool reloadZenzaiModel();

    /**
     * @brief RPC間で共有する永続UNIXソケットセッションを開始する
     *
     * 既存セッションがあれば先に閉じて置き換える
     * 接続の確立に成功した場合のみ、対応するInSessionメソッドを呼び出せる
     *
     * @return セッションソケットを確保できた場合はtrue、接続に失敗した場合はfalse
     */
    bool beginSession();

    /**
     * @brief 永続セッションを終了し、そのソケットを閉じる
     *
     * セッションがない場合も安全に何もしない
     * 以後、InSessionメソッドを使用するには、再度 @ref beginSession を成功させる必要がある
     */
    void endSession();

    /**
     * @brief 永続セッション上で現在の設定を取得する
     *
     * @pre @ref beginSession が成功し、セッションが終了していないこと
     * @return 成功して設定を含む応答なら設定、それ以外はstd::nullopt
     *         セッション未開始、通信失敗、サーバの失敗ステータス、または設定ペイロード欠落を表す
     */
    std::optional<hazkey::config::CurrentConfig> getConfigInSession();

    /**
     * @brief 永続セッション上でサーバの既定プロファイルを取得する
     *
     * @pre @ref beginSession が成功し、セッションが終了していないこと
     * @return 成功して設定を含む応答なら既定設定、それ以外はstd::nullopt
     *         セッション未開始、通信失敗、サーバの失敗ステータス、または設定ペイロード欠落を表す
     */
    std::optional<hazkey::config::CurrentConfig> getDefaultProfileInSession();

    /**
     * @brief 永続セッション上でZenzaiモデルの再読み込みを要求する
     *
     * @pre @ref beginSession が成功し、セッションが終了していないこと
     * @return 通信とサーバ処理が成功した場合はtrue、
     *         セッション未開始、通信失敗、またはサーバの失敗ステータスの場合はfalse
     */
    bool reloadZenzaiModelInSession();

    /**
     * @brief このコネクターを終了状態にし、実行中のRPCを別スレッドから中断する (アプリケーション終了時用)
     *
     * 終了状態は永続的で、呼び出し後の全RPC (一時接続・セッションとも) は接続も送受信も始めず、
     * 通信失敗 (std::nullopt / false / [setCurrentConfig]では例外) として直ちに戻る
     * そのため、作業スレッドの開始前や、[beginSession]とその後のRPCの間で呼ばれても中断は失われない
     * 作業スレッドが応答を待っている最中なら、その接続ソケットに対して shutdown(SHUT_RDWR) を呼び、
     * 読み書きを直ちにEOFまたはエラーで失敗させる
     * 接続の確立待ち・再試行の最中なら、次の試行の前に打ち切る
     * 何度呼んでもよく、RPCが実行中でなくても副作用は終了状態の設定だけである
     *
     * GUIスレッドと作業スレッドから同時に呼べる
     * ソケットのクローズは作業スレッドだけが行い、
     * 追跡するディスクリプターはクローズ前に (例外経路でもRAIIで) 取り除くため、
     * 再利用された別のfdに対してshutdownを呼ぶことはない
     */
    void cancelPendingTransaction();

   private:
    /**
     * @brief 応答待ちに入るソケットを中断可能として登録し、スコープを抜けると必ず登録を外すRAII
     *
     * 登録の解除はデストラクターで行うので、RPC中に例外が伝播しても追跡が残らない
     * 呼び出し側はこのスコープの終了後にソケットをcloseすること (再利用されたfdへのshutdownを防ぐ)
     *
     * owner_ : 登録先のコネクターで、本オブジェクトより長く生存している必要がある
     * active_ : 登録できたかどうか
     * @internal 実装専用
     */
    class SocketTracking {
       public:
        /**
         * @brief ソケットを [trackSocket] で登録する
         * @param owner 登録先のコネクター
         * @param sock 登録する接続済みソケット
         *             所有権は呼び出し元にある
         */
        SocketTracking(ServerConnector& owner, int sock)
            : owner_(owner), active_(owner.trackSocket(sock)) {}
        SocketTracking(const SocketTracking&) = delete;
        SocketTracking& operator=(const SocketTracking&) = delete;
        /** @brief 登録済みなら [untrackSocket] で登録を外す */
        ~SocketTracking() {
            if (active_) owner_.untrackSocket();
        }
        /**
         * @brief 登録できたかを返す
         * @return 登録できた場合はtrue
         *         終了状態だった場合はfalseで、呼び出し側は送受信せずに失敗させる
         */
        bool active() const { return active_; }

       private:
        ServerConnector& owner_;
        bool active_;
    };

    /**
     * @brief 応答待ちに入るソケットを中断可能として登録する
     * @param sock 登録する接続済みソケット
     * @return 既に終了状態ならfalse (登録しない)
     * @internal 実装専用 SocketTrackingから呼ぶ
     */
    bool trackSocket(int sock);

    /**
     * @brief 追跡中のソケットを取り除く
     * @internal 実装専用 SocketTrackingから呼ぶ ソケットをcloseする前に完了していること
     */
    void untrackSocket();

    /**
     * @brief 終了状態かを返す
     * @internal 実装専用
     */
    bool isShuttingDown() const;

    /**
     * @brief 追跡付きで @ref transactOnSocket を実行する
     *
     * 実行中のソケットを [cancelPendingTransaction] から中断できるようにする
     * 戻る時点 (例外時も) で追跡は解除済みなので、呼び出し側がソケットをcloseしてよい
     *
     * @param sock 接続済みのソケット
     *             所有権は呼び出し元にある
     * @param send_data 送信するリクエスト
     * @param readTimeoutSeconds 応答フレームの読み込み期限[秒]
     * @return パース済みの応答
     *         終了状態、または通信失敗ならstd::nullopt
     * @internal 実装専用
     */
    std::optional<hazkey::ResponseEnvelope> transactTracked(
        int sock, const hazkey::RequestEnvelope& send_data,
        int readTimeoutSeconds = 10);

    /**
     * @brief サーバのUNIXドメインソケットパスを組み立てる
     *
     * 環境変数[XDG_RUNTIME_DIR]が空でなく、現在のユーザ専有 (所有者一致かつgroup/other権限なし) のディレクトリを指す場合はその配下を使う
     * そうでなければ /tmp/hazkey-community-runtime-<uid> を使う
     * このディレクトリはGUIからは作成せず、存在しないか安全でない場合は接続しない
     *
     * @return hazkey-community-server.<uid>.sock の絶対パス
     *         使用できるランタイムディレクトリがなければ空文字列
     * @internal 通信実装専用で、接続やソケットの所有権は変更しない
     */
    std::string getSocketPath();

    /**
     * @brief サーバへの非ブロッキングUNIXソケット接続を作成する
     *
     * 最大8回試行し、試行の間に250[ms]待機する
     * 試行ごとにソケットパスを解決し直し、接続待ちのpollは2秒でタイムアウトする
     * 接続後は SO_PEERCRED で相手が同一ユーザであることを確認し、一致しなければ失敗として扱う
     * 初回の失敗後にサーバの通常起動を、4回目の失敗後に[-r]付きの強制再起動を試みる
     * 試行の前に終了状態 ([cancelPendingTransaction]) を確認し、終了状態なら打ち切る
     *
     * @return 接続済みソケットディスクリプタ
     *         確立できなければ-1
     *         返したディスクリプタの所有権は呼び出し元へ移る
     * @internal 実装専用 呼び出し元は成功時のディスクリプタを必ず閉じる
     */
    int createConnection();

    /** @brief 応答フレームを待つ通常の読み込み期限[秒] */
    static constexpr int kDefaultReadTimeoutSeconds = 10;
    /** @brief サーバがZenzaiの読み込みや初期化で応答を遅らせ得るRPC用の読み込み期限[秒] */
    static constexpr int kZenzaiReloadReadTimeoutSeconds = 120;

    /**
     * @brief 1回のRPCを専用接続で実行する
     *
     * 呼び出しごとに @ref createConnection で接続し、完了後にソケットを閉じる
     * すべての通常RPCはこの経路を使い、同時実行をtransact_mutexで直列化する
     * リクエストと応答は @ref transactOnSocket の長さプレフィックス付きprotobufフレームで送受信する
     * 実行中は @ref transactTracked により [cancelPendingTransaction] から中断できる
     * 終了状態の場合は接続も再試行も始めない
     *
     * @param send_data 送信するリクエスト
     * @param readTimeoutSeconds 応答フレームの読み込み期限[秒]
     * @return protobuf応答
     *         終了状態、接続、シリアライズ、送受信、サイズ制限、またはパースに失敗した場合はstd::nullopt
     *         サーバのRPC失敗ステータスは応答として返される
     * @internal 実装専用
     */
    std::optional<hazkey::ResponseEnvelope> transact(
        const hazkey::RequestEnvelope& send_data,
        int readTimeoutSeconds = kDefaultReadTimeoutSeconds);

    /**
     * @brief 指定済みソケットで1回のprotobuf RPCを送受信する
     *
     * フレームは「ネットワークバイトオーダーの4バイト長 + protobuf本体」で、
     * 要求と応答の双方に同じ形式を使う
     * 応答本体は、2[MiB]を超えると拒否する
     * 要求フレームの書き込みは2秒、応答フレームの読み込みはreadTimeoutSeconds秒の期限で打ち切る
     * このメソッドはソケットを閉じず、ロックも取得しない
     *
     * @param sock 接続済みの非ブロッキングUNIXソケット
     *             所有権は呼び出し元にある
     * @param send_data 送信するリクエスト
     * @param readTimeoutSeconds 応答フレームの読み込み期限[秒]
     * @return パース済みの応答
     *         シリアライズ、送受信、応答サイズ制限、またはprotobufパースに失敗した場合はstd::nullopt
     * @internal 実装専用 呼び出し元が必要なロックとcloseを管理する
     */
    std::optional<hazkey::ResponseEnvelope> transactOnSocket(
        int sock, const hazkey::RequestEnvelope& send_data,
        int readTimeoutSeconds = kDefaultReadTimeoutSeconds);

    /**
     * @brief 現在の永続セッションが所有するソケット
     *
     * -1はセッション未開始を表す
     * beginSessionが成功すると有効なディスクリプターを保持し、
     * @ref endSession、別の @ref beginSession、またはデストラクターが閉じる
     * @internal 実装専用
     *           外部から借用・解放してはならない
     */
    int session_socket_;

    /**
     * @brief 追跡状態 ([tracked_socket_] と [shutting_down_] の書込み) を守るミューテックス
     * @internal [transact_mutex] (RPC全体の直列化) とは別物にする
     *           作業スレッドはRPC中ずっと [transact_mutex] を保持するため、中断側が同じ鍵を待つと中断できない
     *           「終了状態の確認とソケット登録」と「終了状態の設定とshutdown」を不可分にして、取りこぼしを防ぐ
     */
    std::mutex cancel_mutex_;
    /** @brief 応答待ち中のソケットで、なければ-1 ([cancel_mutex_] で保護) */
    int tracked_socket_ = -1;
    /**
     * @brief [cancelPendingTransaction] が呼ばれた後はtrueで、二度とfalseに戻らない
     * @internal 書込みは [cancel_mutex_] の下で行い、読取りはロックなしで行える
     */
    std::atomic<bool> shutting_down_{false};
};

/**
 * @brief 指定バイト数をソケットへ書き切るフレーム搬送ヘルパー
 *
 * send(MSG_NOSIGNAL)で書くため、相手がソケットを閉じていてもSIGPIPEでプロセスは終了せず、falseを返す
 * EINTRは再試行し、EAGAIN/EWOULDBLOCKでは期限まで書き込み可能になるのを待つ
 * ソケットは閉じない (所有権は呼び出し元にある)
 * ServerConnectorの実装のために公開しており、単体テストからも呼び出す
 *
 * @param fd 書き込み対象のソケットディスクリプター
 * @param data 送信バッファ
 * @param len 送信するバイト数
 * @param deadline フレーム全体の絶対期限
 * @return lenバイトを書き終えた場合はtrue、書込エラー (EPIPEを含む) または期限切れならfalse
 */
bool writeAll(int fd, const void* data, size_t len,
              std::chrono::steady_clock::time_point deadline);

#endif  // SERVERCONNECTOR_H

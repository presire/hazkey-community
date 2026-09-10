#ifndef SERVERCONNECTOR_H
#define SERVERCONNECTOR_H

/**
 * @file serverconnector.h
 * @brief hazkey-settingsからhazkey-serverへ接続するRPCラッパー
 *
 * UNIXドメインソケット上で長さプレフィックス付きprotobufフレームを送受信し、
 * 設定GUIが使用するRPCと永続セッションを提供する
 */

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
     * @return 成功時はサーバが削除した件数、それ以外は `std::nullopt`
     *         `std::nullopt` は通信失敗、サーバの失敗ステータス、または
     *         削除結果ペイロード欠落を表す
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

   private:
    /**
     * @brief サーバのUNIXドメインソケットパスを組み立てる
     *
     * @return 環境変数XDG_RUNTIME_DIRが設定されていればその配下、
     *         そうでなければ、/tmp配下のhazkey-server.<uid>.sock
     * @internal 通信実装専用で、接続やソケットの所有権は変更しない
     */
    std::string getSocketPath();

    /**
     * @brief サーバへの非ブロッキングUNIXソケット接続を作成する
     *
     * 最大8回試行し、試行間に150[ms]待機する
     * 接続待ちのselectは、2秒でタイムアウトする
     * 接続試行が接続失敗として処理された場合、初回の失敗後に通常起動を、4回目の失敗後に-r付き強制再起動を試みる
     *
     * @return 接続済みソケットディスクリプタ
     *         確立できなければ-1
     *         返したディスクリプタの所有権は呼び出し元へ移る
     * @internal 実装専用 呼び出し元は成功時のディスクリプタを必ず閉じる
     */
    int createConnection();

    /**
     * @brief 1回のRPCを専用接続で実行する
     *
     * 呼び出しごとに @ref createConnection で接続し、完了後にソケットを閉じる
     * すべての通常RPCはこの経路を使い、同時実行をtransact_mutexで直列化する
     * リクエストと応答は @ref transactOnSocket の長さプレフィックス付きprotobufフレームで送受信する
     *
     * @param send_data 送信するリクエスト
     * @return protobuf応答
     *         接続、シリアライズ、送受信、サイズ制限、またはパースに失敗した場合はstd::nullopt
     *         サーバのRPC失敗
     *         ステータスは応答として返される
     * @internal 実装専用
     */
    std::optional<hazkey::ResponseEnvelope> transact(
        const hazkey::RequestEnvelope& send_data);

    /**
     * @brief 指定済みソケットで1回のprotobuf RPCを送受信する
     *
     * フレームは「ネットワークバイトオーダーの4バイト長 + protobuf本体」で、
     * 要求と応答の双方に同じ形式を使う
     * 応答本体は、2[MiB]を超えると拒否する
     * 書き込み待ちは2秒、読み込み待ちは10秒でタイムアウトする
     * このメソッドはソケットを閉じず、ロックも取得しない
     *
     * @param sock 接続済みの非ブロッキングUNIXソケット
     *             所有権は呼び出し元にある
     * @param send_data 送信するリクエスト
     * @return パース済みの応答
     *         シリアライズ、送受信、応答サイズ制限、またはprotobufパースに失敗した場合はstd::nullopt
     * @internal 実装専用 呼び出し元が必要なロックとcloseを管理する
     */
    std::optional<hazkey::ResponseEnvelope> transactOnSocket(
        int sock, const hazkey::RequestEnvelope& send_data);

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
};

#endif  // SERVERCONNECTOR_H

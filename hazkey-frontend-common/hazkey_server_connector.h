#ifndef HAZKEY_SERVER_CONNECTOR_H
#define HAZKEY_SERVER_CONNECTOR_H

#include <sys/socket.h>
#include <sys/un.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include "base.pb.h"
#include "commands.pb.h"
#include "config.pb.h"
#include "hazkey_frontend_hooks.h"
#include "hazkey_socket_path.h"

/**
 * @file hazkey_server_connector.h
 * @brief fcitx5とIBusが共有するサーバ接続クラスを宣言する
 *
 * UNIXドメインソケット上で長さプレフィックス付きprotobufフレームを送受信して、永続接続、読み取りキャッシュ、設定リビジョン通知を提供する
 * 実際の送受信はtransactに集約する
 */

/**
 * @class HazkeyServerConnector
 * @brief hazkey-serverとの永続接続とRPC呼び出しを管理する
 *
 * ソケット記述子を所有しデストラクタで閉じる
 *
 * 浅い複写では2重クローズになるため複写を禁止し参照で利用する
 * 全インスタンスのtransactを静的ミューテックスで直列化する
 *
 * 要求と応答は4バイト長とprotobuf本体の形式で送受信する
 *
 * @note 読み取り結果はSUCCESS応答だけをキャッシュする
 *       状態変更RPCと再接続で無効化する
 */
class HazkeyServerConnector {
    public:
    /**
     * @brief コネクターを構築する
     *
     * 構築時の接続方式だけを切り替える
     * @param autoConnect true:  構築時にconnectServerで即時接続する
     *                    false: 初回RPCまで接続を遅延させる
     * @details IBus側はGLibメインループを停止させないためfalseで構築して、ワーカー上の初回RPCで接続する
     *          Fcitx 5と試験は、既定のtrueで即時接続する
     */
    explicit HazkeyServerConnector(bool autoConnect = true);
    /**
     * @brief 所有する接続記述子を閉じて破棄する
     *
     * 有効な記述子だけを1度だけ閉じる
     * 失敗経路は、既に無効値へ戻しているため2重クローズにならない
     */
    ~HazkeyServerConnector();

    /**
     * @brief 複写構築を禁止する
     *
     * ソケット記述子を所有するため、浅い複写では2重クローズになる
     * 利用側は、参照で共有し複写しない
     */
    HazkeyServerConnector(const HazkeyServerConnector&) = delete;
    /**
     * @brief 複写代入を禁止する
     *
     * ソケット記述子を所有するため浅い複写では2重クローズになる
     * 利用側は、参照で共有し複写しない
     */
    HazkeyServerConnector& operator=(const HazkeyServerConnector&) = delete;

    /**
     * @brief サーバのUNIXドメインソケットパスを組み立てる
     *
     * @return 信頼性とsun_path長を含む接続先候補
     *         接続に使う前にruntimeDirectoryTrustedとpathFitsを確認する
     */
    hazkey::frontend::ServerSocketPath getSocketPath();

    /**
     * @brief サーバへ接続し必要なら起動を試みる
     *
     * @details 最大8回試行し試行間に150[ms]待機する
     *          接続待ちの選択は2秒で切り上げる
     *
     *          初回失敗後に通常起動を試み、4回目失敗後に強制再起動を検討する
     *          直近5秒以内に形式正常な応答があれば、強制再起動を抑止し混雑とみなす
     *
     *          試験用フックで抑止期間だけを変更できる
     */
    void connectServer();

    /**
     * @brief サーバ起動を注入済み手段へ委譲する
     *
     * @param force_restart trueなら強制再起動を要求する
     * @details 試験用フック設定時は、実起動せずフックへ転送する
     *          そうでなければ、フロントエンドの起動手段を使う
     */
    void startHazkeyServer(bool force_restart);

    /**
     * @brief 1回のRPCを単一接続上で送受信する
     *
     * @param send_data 送信する要求封筒
     * @param tryConnect falseなら未接続時も書き込み失敗時も接続とサーバ起動を試みない
     * @return 送受信とパースに成功した場合は、パース済みの応答
     *         接続、送信、受信、またはパースに失敗した場合は、std::nullopt
     *         サーバ処理の失敗応答はそのまま返す
     * @details 静的ミューテックスで全インスタンスを直列化する
     *          記述子無効時は遅延接続し再接続時は読み取りキャッシュを捨てる
     *
     *          要求は4バイト長とprotobuf本体で送信する
     *          応答は2[MiB]上限と10秒読取上限で受信する
     *
     *          書き込み失敗は即時再接続し読み取り失敗は次回RPCまで遅延させる
     *
     *          パース成功時に最終成功時刻と設定リビジョンを更新する
     *
     *          サーバ処理が失敗していても通信は成功とみなす
     */
    std::optional<hazkey::ResponseEnvelope> transact(
        const hazkey::RequestEnvelope& send_data, bool tryConnect = true);

    /**
     * @brief 指定種別の編集中文字列を取得する
     *
     * @param type 取得する文字種
     * @param currentPreedit 英字変換の循環に使うクライアント側preedit
     * @return サーバの編集中文字列で失敗時は空文字列
     * @details 種別とpreeditの組をキーにSUCCESS応答だけをキャッシュする
     *          状態変更RPCと再接続で無効化する
     */
    std::string getComposingText(
        hazkey::commands::GetComposingString::CharType type,
        std::string currentPreedit);

    /**
     * @brief カーソル付き生かな全文を取得する
     *
     * @return カーソル前とカーソル上とカーソル後の構造体
     *         失敗時は空の構造体
     * @details SUCCESS応答だけをキャッシュする
     *          状態変更RPCと再接続で無効化する
     */
    hazkey::frontend::ComposingTextWithCursor getComposingHiraganaWithCursor();

    /**
     * @brief 1文字を入力として送信する
     *
     * @param text 挿入する文字列
     * @details 送信前に読み取りキャッシュを無効化する
     *          応答失敗時は記録だけ残し、状態を変更しない
     */
    void inputChar(std::string text);

    /**
     * @brief [Shift]キー押下と解放を報告する
     *
     * @param isRelease trueなら解放、falseなら押下
     * @param alone 解放が単独打鍵ならtrue、併用ならfalse
     * @details 押下は常にPRESSを送る
     *          単独解放はRELEASEで副入力方式を切り替える
     *          併用解放はCANCELで切り替えない
     *
     *          送信前に読み取りキャッシュを無効化する
     */
    void shiftKeyEvent(bool isRelease, bool alone = true);

    /**
     * @brief 直接入力方式かどうかを返す
     *
     * @return 直接入力ならtrue
     *         失敗時と非直接時はfalse
     * @details SUCCESS応答だけをキャッシュする
     *          状態変更RPCと再接続で無効化する
     */
    bool currentInputModeIsDirect();

    /**
     * @brief カーソル左を1文字削除する
     *
     * @details 送信前に読み取りキャッシュを無効化する
     */
    void deleteLeft();

    /**
     * @brief カーソル右を1文字削除する
     *
     * @details 送信前に読み取りキャッシュを無効化する
     */
    void deleteRight();

    /**
     * @brief 組成内カーソルを移動する
     *
     * @param offset 移動量で正値は右方向
     * @details 送信前に読み取りキャッシュを無効化する
     */
    void moveCursor(int offset);

    /**
     * @brief 文節境界移動の結果をまとめる構造体
     *
     * 境界調整RPCの応答から再構築した候補と読みを保持する
     */
    struct ClauseBoundaryResult {
        hazkey::commands::CandidatesResult candidates; ///< 再構築された候補一覧
        std::string hiragana;                          ///< 対応する読み
    };

    /**
     * @brief 文節境界を移動し候補を再構築する
     *
     * @param offset 移動量で正値は右方向
     * @return 候補と読みを含む結果で失敗時はstd::nullopt
     * @details 送信前に読み取りキャッシュを無効化する
     */
    std::optional<ClauseBoundaryResult> adjustClauseBoundary(int offset);

    /**
     * @brief 候補の学習項目削除結果をまとめる構造体
     *
     * 削除数と再構築した候補と読みを保持する
     * 削除数が0の場合は、保持継続の合図になる
     */
    struct DeleteCandidateLearningDataResult {
        uint32_t deleted_count;                         ///< 削除した学習項目数で、0は保持継続の合図
        hazkey::commands::CandidatesResult candidates;  ///< 再構築された候補一覧
        std::string hiragana;                           ///< 対応する読み
    };

    /**
     * @brief 指定候補の学習項目を削除して、候補を再構築する
     *
     * @param index 削除対象の候補位置
     * @return 削除数と候補と読みを含む結果
     *         送受信またはサーバ処理に失敗した場合はstd::nullopt
     * @details 送信前に読み取りキャッシュを無効化する
     *          削除数が0の場合は、学習項目なしを表し呼び出し側は表示を維持する
     */
    std::optional<DeleteCandidateLearningDataResult> deleteCandidateLearningData(
        int index);

    /**
     * @brief 文脈情報を設定する
     *
     * @param context 文脈文字列
     * @param anchor 文脈内の基準位置
     * @details 送信前に読み取りキャッシュを無効化する
     *          この接続で最後に送信に成功した内容と同じで、接続が生きている場合は送信を省く
     */
    void setContext(std::string context, int anchor);

    /**
     * @brief 現在の設定を取得する
     *
     * @return 成功時は現在設定、失敗時はstd::nullopt
     * @note 読み取りキャッシュを無効化しない
     */
    std::optional<hazkey::config::CurrentConfig> getServerConfig();
    /**
     * @brief 現在の設定を保存する
     *
     * @param config 保存する現在設定
     * @return 保存に成功した場合はtrue
     * @details プロファイルとファイルハッシュだけを送信する
     *          送信前に読み取りキャッシュを無効化する
     */
    bool setServerConfig(const hazkey::config::CurrentConfig& config);

    /**
     * @brief 設定変更通知を1回だけ消費する
     *
     * @return 前回消費後にリビジョンが変わっていればtrue
     * @details transact受信の設定リビジョンを起点とする
     *          初回観測では通知せず保持だけする
     *
     *          変化時は1度だけtrueを返して、以後はfalseに戻る
     *          フロントエンドは入力処理前に呼び出し、プロファイルの再読込に使用する
     */
    bool consumeConfigChanged();

    /**
     * @brief 未消費の設定変更通知があるかを、消費せずに返す
     *
     * @return 前回消費後にリビジョンが変わっていればtrue
     * @details 通知は残るため、次のconsumeConfigChanged()がtrueを返す
     *          入力処理の外で、プロファイルが古くなったかを判断する場合に使用する
     */
    bool configChangePending() const {
        return configChanged_.load();
    }

    /**
     * @brief 最終観測リビジョンを返す
     *
     * @return 最後に受信した設定リビジョン
     */
    uint64_t configRevision() const {
        return lastConfigRevision_.load(std::memory_order_relaxed);
    }

    /**
     * @brief 組成を破棄し新しい組成を開始する
     *
     * @details 送信前に読み取りキャッシュを無効化する
     */
    void newComposingText();

    /**
     * @brief 指定候補で接頭辞を確定する
     *
     * @param index 確定する候補位置
     * @details 送信前に読み取りキャッシュを無効化する
     */
    void completePrefix(int index);

    /**
     * @brief 予測候補を先頭表記として受理し組成を継続する
     *
     * @param index 受理する候補位置
     * @return 受理に成功した場合はtrue
     *         送受信またはサーバ処理に失敗した場合はfalse
     * @details completePrefixと異なり組成を開いたままにする
     *          受理後はpreeditと候補一覧の更新が必要になる
     *
     *          予測候補以外を指定するとサーバ処理は失敗して、falseを返す
     *          送信前に読み取りキャッシュを無効化する
     */
    bool acceptPrediction(int index);

    /**
     * @brief Zenzai有効状態を切り替えサーバ組成を維持する
     *
     * @return 切替後の永続有効状態で欠落と失敗時はstd::nullopt
     * @note 読み取りキャッシュを無効化しない
     */
    std::optional<bool> toggleZenzai();

    /**
     * @brief 学習データを保存する
     *
     * @param tryConnect falseなら未接続時にサーバを起動せず保存を諦める
     * @details 送信前に読み取りキャッシュを無効化する
     */
    void saveLearningData(bool tryConnect = true);

    /**
     * @brief 予約された候補要素の宣言
     *
     * @note 現在のソースでは利用がなく、宣言だけを保持する
     *       取得失敗路の未使用局所変数の型名に現れるだけである
     */
    struct CandidateData {
        std::string candidateText;  ///< 予約された候補表記で現在は利用なし
        std::string subHiragana;    ///< 予約された補助読みで現在は利用なし
    };

    /**
     * @brief 候補一覧を取得する
     *
     * @param isSuggest サジェスト候補ならtrue、全文候補ならfalse
     * @return 候補結果で失敗時は空の結果
     * @details サジェスト以外は組成区切りの挿入で読み取り状態が変わるため、実行前に読み取りキャッシュを無効化する
     *          サジェスト用と全文用で保持領域を分ける
     *          SUCCESS応答だけをキャッシュする
     */
    hazkey::commands::CandidatesResult getCandidates(bool isSuggest);

    /**
     * @brief 最後に有効だった自動変換方式の記憶を返す
     *
     * @return 共有される自動変換方式への参照
     * @details 全入力コンテキストで共有し無効以外のモードを記憶する
     *          切替キー押下時の復帰に使う
     */
    hazkey::config::Profile_AutoConvertMode& rememberedOnMode() {
        return rememberedOnMode_;
    }

     // 試験用フック
     // 試験バイナリ以外では設定しない
     // 読み取りタイムアウト、強制再起動の抑止期間、起動処理を差し替える
     // 既定値では製品と同じ動作になる
    /**
     * @brief 応答読取の上限秒を上書きする
     *
     * @param seconds 上書きする秒数で0以下は製品既定10秒に戻す
     * @details 製品経路は常に10秒を使用する
     *          試験だけが短縮値で待機路を検証する
     */
    static void setTestReadTimeoutSeconds(int seconds) {
        testReadTimeoutSeconds_ = seconds;
    }

    /**
     * @brief 強制再起動抑止期間を上書きする
     *
     * @param milliseconds 上書きする抑止期間のミリ秒で負値は製品既定に戻す
     * @details connectServerが直近成功からの経過で強制再起動可否を決める
     *          試験だけが期間幅を操作する
     */
    static void setTestForceRestartWindowMs(long milliseconds) {
        testForceRestartWindowMs_ = milliseconds;
    }

    /**
     * @brief 起動手段を試験用観測処理へ置き換える
     *
     * @param hook 起動要求を受け取る試験用処理で空なら、注入済み手段に戻す
     * @details 製品既定ではfrontendの起動手段を使用する
     *          試験だけが実起動なしに起動判断を観測する
     */
    static void setTestStartServerHook(std::function<void(bool)> hook) {
        testStartServerHook_ = std::move(hook);
    }

    /**
     * @brief 試験中の接続記述子をdup2で指定先へ移す
     *
     * @param targetFd 所有権を移したい未使用記述子
     * @return 複製と所有権移動に成功した場合はtrue
     */
    bool duplicateSocketToForTest(int targetFd);

    /**
     * @brief 全試験用フックを製品動作の既定へ戻す
     *
     * @details 読取上限と抑止期間と起動フックを一括で初期化する
     */
    static void clearTestHooks() {
        testReadTimeoutSeconds_ = 0;
        testForceRestartWindowMs_ = -1;
        testStartServerHook_ = nullptr;
    }

    private:
    /**
     * @brief 予約された再接続判定の宣言
     *
     * @return 規定なし
     * @note 現在のソースには定義と呼び出しがなく、宣言だけを保持する
     *       実接続はconnectServerが担う
     */
    bool retryConnect();

    /**
     * @brief 予約された起動確認の宣言
     *
     * @return 規定なし
     * @note 現在のソースには定義と呼び出しがなく、宣言だけを保持する
     */
    bool isHazkeyServerRunning();

    /**
     * @brief 予約された応答判定の宣言
     *
     * @param 応答 判定対象の応答
     * @return 規定なし
     * @note 現在のソースには定義と呼び出しがなく、宣言だけを保持する
     *       成功判定は各RPC内で状態比較により行う
     */
     bool requestSuccess(hazkey::ResponseEnvelope);

    /**
     * @brief 読み取りキャッシュを全て破棄する
     *
     * @details 状態変更RPCとサジェスト以外の候補要求で呼び出す
     *          接続の確立と再確立でも呼び出す
     *          再起動ではサーバ組成が失われるため保持を読ませない
     *          SUCCESS応答だけを保持対象とする
     * @note 設定GUI接続による既存接続の追い出しは、通常の送受信失敗として同じ再接続路へ流れる
     *       再接続路で正しく回復するため許容された相互作用である
     */
    void invalidateCache();

    /**
     * @brief 受信リビジョンを記録し変化を通知待ちにする
     *
     * @param revision 受信した設定リビジョン
     * @details 初回観測は通知せず保持だけする
     *          2回目以降の差異で変更印を立てる
     *          transactの応答受信ごとに呼び出す
     */
    void recordConfigRevision(uint64_t revision);

     // 接続状態
     int sock_ = -1;                                                                      ///< 所有するソケット記述子で未接続時は-1
     std::string socket_path_;                                                            ///< 予約済みのソケットパス保持領域で現在は未使用
     std::chrono::steady_clock::time_point lastSuccessfulTransaction_ =
         std::chrono::steady_clock::time_point::min();                                    ///< 正常な応答を受信した最終時刻で未受信時は最小値

     // 設定リビジョン
     std::atomic<uint64_t> lastConfigRevision_{0};                                        ///< 最終観測した設定リビジョン
     std::atomic<bool> configRevisionKnown_{false};                                       ///< 設定リビジョンを一度でも観測した場合はtrue
     std::atomic<bool> configChanged_{false};                                             ///< 未消費の設定変更通知がある場合はtrue

     // ライブ変換
     hazkey::config::Profile_AutoConvertMode rememberedOnMode_ =
         hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;                     ///< 最後に有効だった自動変換モード

     // 読み取りキャッシュ
     std::optional<hazkey::frontend::ComposingTextWithCursor> cachedHiraganaWithCursor_;  ///< カーソル付き生かなのキャッシュ
     std::map<std::pair<int, std::string>, std::string> cachedComposingText_;             ///< 種別とpreeditをキーにする編集中文字列のキャッシュ
     std::optional<hazkey::commands::CandidatesResult> cachedCandidatesSuggest_;          ///< サジェスト候補のキャッシュ
     std::optional<hazkey::commands::CandidatesResult> cachedCandidatesFull_;             ///< 全文候補のキャッシュ
     std::optional<bool> cachedInputModeDirect_;                                          ///< 直接入力かどうかのキャッシュ

     // 周辺文脈
     std::optional<std::pair<std::string, int>> lastSentContext_;                         ///< この接続で最後に送信に成功した文脈と基準位置 (組成開始・設定保存・再接続で破棄)

     // 試験用フック
     static inline int testReadTimeoutSeconds_ = 0;                                       ///< 読み取りタイムアウトで0以下は製品既定の10秒を使う
     static inline long testForceRestartWindowMs_ = -1;                                   ///< 強制再起動抑止期間で負値は製品既定を使う
     static inline std::function<void(bool)> testStartServerHook_;                        ///< 起動フックで空なら注入済みの起動処理を使う
};

#endif  // HAZKEY_SERVER_CONNECTOR_H

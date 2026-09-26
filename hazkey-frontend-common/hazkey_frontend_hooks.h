/**
 * @file hazkey_frontend_hooks.h
 * @brief 共通通信層にフロントエンド依存の処理を登録する
 *
 * 通信層はフレームワークに依存しない
 * ログ、サーバ起動、メインループへの配送をここから登録する
 *
 * 既定は無処理である
 *
 * 転送単体では外部過程や記録APIに依存しない
 * 各フロントエンドは最初の接続生成より前に導入すること
 */

#ifndef HAZKEY_FRONTEND_HOOKS_H
#define HAZKEY_FRONTEND_HOOKS_H

#include <functional>
#include <sstream>
#include <string>

namespace hazkey::frontend {

/**
 * @enum LogLevel
 * @brief 通信層が出力するログレベルを示す
 */
enum class LogLevel {
     Debug,    ///< 詳細なデバッグログ
     Info,     ///< 通常の情報ログ
     Warning,  ///< 縮退動作や再試行の警告ログ
     Error     ///< 失敗を示すエラーログ
};

/**
 * @brief ログレベルとメッセージを受け取る関数型
 *
 * 登録先はログレベルとログメッセージを受け取る
 */
using LogSink = std::function<void(LogLevel level, const std::string& message)>;

/**
 * @brief ログ出力先を登録する
 *
 * @param sink ログ出力関数、空なら出力先を解除する
 *
 * @note 上書き登録であり複数保持しない
 */
void setLogSink(LogSink sink);

/**
 * @brief ログレベル付きのメッセージを出力先へ送る
 *
 * @param level ログレベル
 * @param message ログメッセージ
 *
 * @note 未登録時は無処理である
 */
void logMessage(LogLevel level, const std::string& message);

/**
 * @brief ログレベルの有効可否を判定する関数型
 *
 * フロントエンドで出力しないログを整形前に除外する
 * 未登録時は全水準を有効とみなす
 * 判定対象の水準を受け取り記録すべき場合に真を返す
 */
using LogLevelPredicate = std::function<bool(LogLevel level)>;

/**
 * @brief ログレベルの有効判定を登録する
 *
 * @param predicate 判定関数 (空でもよい)
 *
 * @note 上書き登録であり複数保持しない
 */
void setLogLevelEnabled(LogLevelPredicate predicate);

/**
 * @brief 指定したログレベルを出力するか判定する
 *
 * @param level 判定するログレベル
 * @return 出力する場合はtrue
 *
 * @note 未登録時は常に真を返す
 */
bool isLogLevelEnabled(LogLevel level);

/**
 * @class LogStream
 * @brief ストリーム演算子でログを組み立て、破棄時に出力する補助クラス
 *
 * @details 生成時に有効判定を固定する
 *          無効時は挿入も送出も省く
 *          オブジェクト破棄時に蓄積した行を送る
 *
 * @note 複写はできない
 */
class LogStream {
   public:
    /**
     * @brief 指定したログレベルで、メッセージの組み立てを開始する
     *
     * @param level ログレベル
     */
    explicit LogStream(LogLevel level) : level_(level), enabled_(isLogLevelEnabled(level)) {}

    /**
     * @brief 蓄積したメッセージを送って破棄する
     *
     * 有効時のみ送る
     * 無効時は何もしない
     */
    ~LogStream() {
        if (enabled_) {
            logMessage(level_, stream_.str());
        }
    }

    LogStream(const LogStream&) = delete;
    LogStream& operator=(const LogStream&) = delete;

    /**
     * @brief 値を1件追加する
     *
     * 有効時のみ蓄積する
     * 無効時は捨てる
     *
     * @tparam T 挿入できる値の型
     * @param value 追加する値
     * @return 自身への参照
     */
    template <typename T>
    LogStream& operator<<(const T& value) {
        if (enabled_) {
            stream_ << value;
        }
        return *this;
    }

   private:
     // 出力するログ
     LogLevel level_;            ///< 出力時のログレベル
    bool enabled_;               ///< 生成時に固定した有効可否
    std::ostringstream stream_;  ///< 蓄積中の行内容
};

/**
 * @brief サーバ起動要求を受け取る関数型
 *
 * 強制再起動の有無を受け取る
 */
using ServerSpawner = std::function<void(bool forceRestart)>;

/**
 * @brief サーバ起動処理を登録する
 *
 * @param spawner サーバ起動関数、空なら起動処理を解除する
 *
 * @note 上書き登録であり複数保持しない
 */
void setServerSpawner(ServerSpawner spawner);

/**
 * @brief 登録済みの処理でサーバを起動する
 *
 * 通常起動と強制再起動を使い分ける
 *
 * @param forceRestart 強制再起動の場合は真
 *
 * @note 未登録時は無処理である
 */
void spawnServer(bool forceRestart);

/**
 * @brief メインループへタスクを配送する関数型
 *
 * 登録した関数は任意のスレッドから安全に呼び出せる必要がある
 * 受け取ったタスクはメインループで投入順に実行する
 *
 * 未登録時は呼び出し元のスレッドで直接実行する
 *
 * 最初に登録した空でない関数だけを使う
 * 空の関数を登録すると解除し、直接実行へ戻す
 *
 * @note 最初の接続、または、状態生成より前に登録すること
 * @note タスク配送との同時登録は同期しない
 */
using MainLoopPoster = std::function<void(std::function<void()>)>;

/**
 * @brief メインループへの配送先を登録する
 *
 * 最初の実登録だけを受け付ける
 * 以後は捨てる
 *
 * 空関数は解除として受け付ける
 *
 * @param poster 配送関数、空なら登録を解除する
 */
void setMainLoopPoster(MainLoopPoster poster);

/**
 * @brief タスクをメインループへ配送する
 *
 * 登録済みなら配送先へ渡して、未登録なら呼び出し元のスレッドで実行する
 *
 * @param task 実行するタスク
 */
void postToMainLoop(std::function<void()> task);

/**
 * @struct ComposingTextWithCursor
 * @brief カーソル位置で3分割した組成テキストを表す
 *
 * 各フレームワークが独自の表示を組み立てられるよう、カーソル前、カーソル位置、カーソル後に分けて保持する
 */
struct ComposingTextWithCursor {
     std::string before;    ///< カーソルより前のテキスト
     std::string onCursor;  ///< カーソル位置のテキスト
     std::string after;     ///< カーソルより後のテキスト

    /**
     * @brief 3つの部分を結合して全文を返す
     *
     * 前側とカーソル上と後側を順に結合するだけである
     *
     * @return 合成全文
     */
    std::string toString() const { return before + onCursor + after; }
};

}  // namespace hazkey::frontend

#endif  // HAZKEY_FRONTEND_HOOKS_H

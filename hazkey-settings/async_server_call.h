/**
 * @file async_server_call.h
 * @brief サーバRPCをGUIスレッド外で実行する共通ヘルパーの宣言
 *
 * ServerConnectorのRPCは接続再試行 (サーバ起動を含め最大約2秒)、読込タイムアウト (10秒)、
 * モデル再読込 (120秒) の間、呼び出しスレッドをブロックする
 * そのためGUIスレッドから直接呼ぶと、サーバが応答しない間は画面が再描画されなくなる
 *
 * runServerCallAsync() は呼び出しを作業スレッドへ移し、GUIスレッドでは単一のQEventLoopを
 * 回して再描画を保ったまま完了を待つ。呼び出し側からは従来どおり同期的な関数に見える
 */

#ifndef ASYNC_SERVER_CALL_H
#define ASYNC_SERVER_CALL_H

#include <QString>
#include <exception>
#include <functional>
#include <optional>
#include <type_traits>
#include <utility>

class QWidget;

/**
 * @brief runServerCallAsync() の実行結果の種別
 */
enum class ServerCallStatus {
    /** @brief 作業スレッドが終了し、結果 (または例外) が有効である */
    Completed,
    /** @brief 別のサーバ呼び出しが実行中のため、何も実行しなかった */
    Busy,
    /** @brief アプリケーション終了中のため中断した。結果は無効で、呼び出し側は破棄済みの状態に触れてはならない */
    Aborted,
};

/**
 * @brief runServerCallAsync() の戻り値
 *
 * @tparam T 呼び出しの戻り値型
 *
 * status が Completed のときだけ value を持つ
 */
template <typename T>
struct ServerCallResult {
    /** @brief 実行結果の種別 */
    ServerCallStatus status = ServerCallStatus::Aborted;
    /** @brief status が Completed のときの呼び出しの戻り値 */
    std::optional<T> value;

    /** @brief 呼び出しが完了し value が有効であるか */
    bool completed() const { return status == ServerCallStatus::Completed; }
    /** @brief アプリケーション終了中に中断されたか */
    bool aborted() const { return status == ServerCallStatus::Aborted; }
};

/** @brief 待機ダイアログを表示するまでの既定の猶予 (ミリ秒)。短いRPCでダイアログがちらつくのを避ける */
constexpr int kServerCallDialogDelayMs = 400;

/**
 * @brief 作業スレッドで work を実行し、完了までGUIスレッドのイベントループを回して待つ
 *
 * @details 型に依存しない実体。通常は直接ではなく runServerCallAsync() から呼ぶ
 *
 *          保証:
 *          - イベントループの exec() は1回だけ。QCoreApplication::exit() 後の exec() は
 *            キュー済みの完了通知を配送せず即座に戻るため、再実行するとビジーループになる
 *          - 戻る前に必ず作業スレッドを wait() する。work がキャプチャしたGUI側の状態
 *            (this、スタック上の結果領域など) は、作業スレッドの終了後にだけ破棄される
 *          - 実行中に別の呼び出しが来た場合は Busy を返し、何も実行しない (再入防止)
 *          - アプリケーション終了中は Aborted を返す
 *
 *          待機ダイアログ (ウィンドウモーダル、キャンセル不可) は dialogDelayMs 経過後にだけ表示する
 *
 * @param parent 待機ダイアログの親。nullptr 可
 * @param label 待機ダイアログに表示する (翻訳済みの) 文言
 * @param work 作業スレッドで実行する関数。例外を投げてはならない (runServerCallAsync() が捕捉する)
 * @param dialogDelayMs 待機ダイアログを表示するまでの猶予 (ミリ秒)
 * @return 実行結果の種別
 */
ServerCallStatus runBlockingOnWorker(QWidget* parent, const QString& label,
                                     const std::function<void()>& work,
                                     int dialogDelayMs);

/**
 * @brief サーバ呼び出し fn を作業スレッドで実行し、結果を同期的に返す
 *
 * @details fn が例外を投げた場合は作業スレッドで捕捉してGUIスレッドへ運び、status が Completed のとき
 *          呼び出し元で再送出する。従来GUIスレッドで直接呼んでいたときと同じ try/catch がそのまま使える
 *          Aborted / Busy のときは例外を再送出しない
 *
 *          fn は作業スレッドで実行されるため、GUIウィジェットに触れてはならない
 *          共有状態 (currentConfig_ など) は、必要ならコピーをキャプチャすること
 *
 * @tparam Fn 引数なしで呼べる呼び出し可能オブジェクト。戻り値は void 以外
 * @param parent 待機ダイアログの親。nullptr 可
 * @param label 待機ダイアログに表示する (翻訳済みの) 文言
 * @param fn 作業スレッドで実行する呼び出し
 * @param dialogDelayMs 待機ダイアログを表示するまでの猶予 (ミリ秒)
 * @return 実行結果。Completed のときだけ value を持つ
 */
template <typename Fn>
auto runServerCallAsync(QWidget* parent, const QString& label, Fn&& fn,
                        int dialogDelayMs = kServerCallDialogDelayMs)
    -> ServerCallResult<std::invoke_result_t<Fn&>> {
    using T = std::invoke_result_t<Fn&>;
    static_assert(!std::is_void_v<T>,
                  "runServerCallAsync: fn must return a value (return true for void calls)");

    ServerCallResult<T> result;
    std::exception_ptr error;
    // 作業スレッドが書き込み、runBlockingOnWorker() が wait() で終了を確認した後にだけ読む
    const std::function<void()> work = [&fn, &result, &error]() {
        try {
            result.value.emplace(fn());
        } catch (...) {
            error = std::current_exception();
        }
    };

    result.status = runBlockingOnWorker(parent, label, work, dialogDelayMs);
    if (result.status != ServerCallStatus::Completed) {
        result.value.reset();
        return result;
    }
    if (error) {
        std::rethrow_exception(error);
    }
    return result;
}

#endif  // ASYNC_SERVER_CALL_H

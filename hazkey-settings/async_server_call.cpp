/**
 * @file async_server_call.cpp
 * @brief サーバRPCをGUIスレッド外で実行する共通ヘルパーの実装
 */

#include "async_server_call.h"
#include <QApplication>
#include <QCoreApplication>
#include <QEventLoop>
#include <QProgressDialog>
#include <QScopedValueRollback>
#include <QThread>
#include <QTimer>
#include <QWidget>

namespace {

/**
 * @brief 待機中の砂時計カーソルを、設定した場合に限り確実に元へ戻すRAII
 * @internal 待機ダイアログと同じ猶予の後で設定するため、設定済みかどうかを保持する
 */
class DeferredWaitCursor {
   public:
    DeferredWaitCursor() = default;
    DeferredWaitCursor(const DeferredWaitCursor&) = delete;
    DeferredWaitCursor& operator=(const DeferredWaitCursor&) = delete;
    ~DeferredWaitCursor() { release(); }

    /** @brief 未設定なら砂時計カーソルを設定する */
    void acquire() {
        if (acquired_) return;
        QApplication::setOverrideCursor(Qt::WaitCursor);
        acquired_ = true;
    }

    /** @brief 設定済みなら砂時計カーソルを元へ戻す */
    void release() {
        if (!acquired_) return;
        QApplication::restoreOverrideCursor();
        acquired_ = false;
    }

   private:
    /** @brief 砂時計カーソルを設定済みか */
    bool acquired_ = false;
};

}  // namespace

ServerCallStatus runBlockingOnWorker(QWidget* parent, const QString& label,
                                     const std::function<void()>& work,
                                     int dialogDelayMs) {
    // GUIスレッドからだけ呼ばれるため、排他は不要である
    static bool inFlight = false;
    if (inFlight) {
        return ServerCallStatus::Busy;
    }
    if (QCoreApplication::closingDown()) {
        return ServerCallStatus::Aborted;
    }
    QScopedValueRollback<bool> inFlightGuard(inFlight, true);

    // QProgressDialog の自動表示は setValue() の呼び出しに依存するため、表示は下のタイマーで明示的に行う
    QProgressDialog waitDialog(label, QString(), 0, 0, parent);
    waitDialog.setWindowModality(Qt::WindowModal);
    waitDialog.setMinimumDuration(0);
    waitDialog.setCancelButton(nullptr);
    waitDialog.setAutoReset(false);
    waitDialog.setAutoClose(false);

    DeferredWaitCursor waitCursor;
    QTimer showTimer;
    showTimer.setSingleShot(true);
    QObject::connect(&showTimer, &QTimer::timeout, &showTimer,
                     [&waitCursor, &waitDialog]() {
                         waitDialog.show();
                         waitCursor.acquire();
                     });
    if (dialogDelayMs > 0) {
        showTimer.start(dialogDelayMs);
    } else {
        waitDialog.show();
        waitCursor.acquire();
    }

    bool workerFinished = false;
    QEventLoop loop;
    QThread* worker = QThread::create(work);
    // finishedはワーカースレッドから発行されるが、受信側のloopはGUIスレッドにあるためキュー接続になる
    QObject::connect(worker, &QThread::finished, &loop, [&workerFinished, &loop]() {
        workerFinished = true;
        loop.quit();
    });
    worker->start();
    // QCoreApplication::exit() 後の QEventLoop::exec() は、キュー済みのfinishedを配送せずに
    // 即座に戻る。再実行のループはビジーループになるため、実行は1回だけにする
    loop.exec();
    // ワーカーが参照するGUI側の状態を破棄する前に、必ず終了を待つ。
    // 結果はワーカーが終了前に書き、wait() の後にだけ読まれる
    worker->wait();
    delete worker;
    showTimer.stop();
    waitCursor.release();
    waitDialog.close();
    // 完了通知を受け取れずに戻った場合は、終了処理中として中断を返す。
    // 未配送のキュー済みスロットは、loop の破棄で取り除かれる
    if (!workerFinished || QCoreApplication::closingDown()) {
        return ServerCallStatus::Aborted;
    }
    return ServerCallStatus::Completed;
}

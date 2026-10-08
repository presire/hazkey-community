/**
 * @file async_server_call_test.cpp
 * @brief runServerCallAsync() の単体テスト
 *
 * 作業スレッドでの実行、結果と例外の搬送、待機中の画面更新の継続、再入防止、
 * 待機ダイアログの表示猶予、アプリケーション終了時の中断を検証する
 */

#include <QtTest/QtTest>
#include <QApplication>
#include <QProgressDialog>
#include <QThread>
#include <QTimer>
#include <QWidget>
#include <atomic>
#include <chrono>
#include <stdexcept>
#include <thread>
#include "async_server_call.h"

/**
 * @class AsyncServerCallTest
 * @brief 作業スレッド実行ヘルパーの挙動を検証するテスト
 *
 * Aborted の検証は QCoreApplication::exit() を呼ぶため、後続のイベントループに影響し得る。
 * そのため最後のテストスロットとして宣言している
 */
class AsyncServerCallTest : public QObject {
    Q_OBJECT

   private slots:
    /** @brief 作業スレッドの戻り値が呼び出し元へ届き、GUIとは別スレッドで実行される */
    void deliversResultFromWorkerThread();
    /** @brief 作業スレッドの例外がGUIスレッドへ運ばれ、呼び出し元で再送出される */
    void rethrowsWorkerException();
    /** @brief 待機中もGUIスレッドのイベントループが回り、タイマーが発火し続ける */
    void keepsEventLoopRunningWhileWaiting();
    /** @brief 実行中の再入は Busy を返し、何も実行しない。完了後は再び実行できる */
    void rejectsReentrantCallWhileInFlight();
    /** @brief 猶予内に終わる短い呼び出しでは、待機ダイアログを表示しない */
    void fastCallDoesNotShowDialog();
    /** @brief 猶予を超える呼び出しでは、待機ダイアログを表示し、完了後に閉じる */
    void slowCallShowsDialogUntilDone();
    /** @brief アプリケーション終了要求でループが戻っても、作業スレッドの終了を待って Aborted を返す */
    void abortsWhenApplicationExits();
};

void AsyncServerCallTest::deliversResultFromWorkerThread() {
    QThread* const guiThread = QThread::currentThread();
    QThread* workerThread = nullptr;
    const auto result = runServerCallAsync(nullptr, QStringLiteral("test"), [&workerThread]() {
        workerThread = QThread::currentThread();
        return 42;
    });
    QVERIFY(result.completed());
    QVERIFY(!result.aborted());
    QCOMPARE(result.value.value_or(-1), 42);
    QVERIFY(workerThread != nullptr);
    QVERIFY(workerThread != guiThread);
}

void AsyncServerCallTest::rethrowsWorkerException() {
    bool caught = false;
    try {
        runServerCallAsync(nullptr, QStringLiteral("test"), []() -> int {
            throw std::runtime_error("worker failed");
        });
    } catch (const std::runtime_error& e) {
        caught = true;
        QCOMPARE(QString::fromUtf8(e.what()), QStringLiteral("worker failed"));
    }
    QVERIFY(caught);
}

void AsyncServerCallTest::keepsEventLoopRunningWhileWaiting() {
    int ticks = 0;
    QTimer ticker;
    ticker.setInterval(10);
    connect(&ticker, &QTimer::timeout, &ticker, [&ticks]() { ++ticks; });
    ticker.start();

    const auto result = runServerCallAsync(nullptr, QStringLiteral("test"), []() {
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        return true;
    });
    ticker.stop();
    QVERIFY(result.completed());
    // 400ms の間に10ms周期のタイマーが十分な回数発火していれば、ループは止まっていない
    QVERIFY2(ticks >= 10, qPrintable(QStringLiteral("ticks=%1").arg(ticks)));
}

void AsyncServerCallTest::rejectsReentrantCallWhileInFlight() {
    std::atomic<int> nestedRuns{0};
    ServerCallStatus nestedStatus = ServerCallStatus::Completed;
    QTimer::singleShot(50, this, [&nestedRuns, &nestedStatus]() {
        const auto nested = runServerCallAsync(nullptr, QStringLiteral("nested"), [&nestedRuns]() {
            ++nestedRuns;
            return 1;
        });
        nestedStatus = nested.status;
    });

    const auto outer = runServerCallAsync(nullptr, QStringLiteral("outer"), []() {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        return 7;
    });
    QVERIFY(outer.completed());
    QCOMPARE(outer.value.value_or(-1), 7);
    QCOMPARE(nestedStatus, ServerCallStatus::Busy);
    QCOMPARE(nestedRuns.load(), 0);

    const auto after = runServerCallAsync(nullptr, QStringLiteral("after"), []() { return 9; });
    QVERIFY(after.completed());
    QCOMPARE(after.value.value_or(-1), 9);
}

void AsyncServerCallTest::fastCallDoesNotShowDialog() {
    QWidget parent;
    parent.show();
    bool dialogSeenVisible = false;
    QTimer probe;
    probe.setInterval(10);
    connect(&probe, &QTimer::timeout, &probe, [&parent, &dialogSeenVisible]() {
        for (auto* dialog : parent.findChildren<QProgressDialog*>()) {
            dialogSeenVisible = dialogSeenVisible || dialog->isVisible();
        }
    });
    probe.start();

    const auto result = runServerCallAsync(
        &parent, QStringLiteral("fast"),
        []() {
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            return true;
        },
        1000);
    probe.stop();
    QVERIFY(result.completed());
    QVERIFY(!dialogSeenVisible);
}

void AsyncServerCallTest::slowCallShowsDialogUntilDone() {
    QWidget parent;
    parent.show();
    bool dialogSeenVisible = false;
    QTimer probe;
    probe.setInterval(10);
    connect(&probe, &QTimer::timeout, &probe, [&parent, &dialogSeenVisible]() {
        for (auto* dialog : parent.findChildren<QProgressDialog*>()) {
            dialogSeenVisible = dialogSeenVisible || dialog->isVisible();
        }
    });
    probe.start();

    const auto result = runServerCallAsync(
        &parent, QStringLiteral("slow"),
        []() {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            return true;
        },
        50);
    probe.stop();
    QVERIFY(result.completed());
    QVERIFY(dialogSeenVisible);
    for (auto* dialog : parent.findChildren<QProgressDialog*>()) {
        QVERIFY(!dialog->isVisible());
    }
}

void AsyncServerCallTest::abortsWhenApplicationExits() {
    std::atomic<bool> workerReturned{false};
    QTimer::singleShot(50, this, []() { QCoreApplication::exit(0); });

    const auto result = runServerCallAsync(nullptr, QStringLiteral("quit"), [&workerReturned]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        workerReturned = true;
        return true;
    });
    QVERIFY(result.aborted());
    QVERIFY(!result.value.has_value());
    // 作業スレッドの終了を待ってから戻るため、キャプチャした状態への書込みは戻る前に済んでいる
    QVERIFY(workerReturned.load());
}

QTEST_MAIN(AsyncServerCallTest)
#include "async_server_call_test.moc"

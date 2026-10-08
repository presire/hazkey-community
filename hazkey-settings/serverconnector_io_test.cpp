/**
 * @file serverconnector_io_test.cpp
 * @brief ServerConnectorのソケット書込とサーバ起動パスの単体テスト
 *
 * 相手が閉じたソケットへの書込がSIGPIPEでプロセスを終了させず失敗として返ること、
 * 書込期限が守られること、サーバ起動パスが絶対パスであることを検証する
 * SIGPIPEを無視する設定 (SIG_IGN) には依存しない
 */

#include <QtTest/QtTest>
#include <QDir>
#include <array>
#include <chrono>
#include <csignal>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>
#include "constants.h"
#include "serverconnector.h"

namespace {

/** @brief SIGPIPEの配送回数 (テスト専用ハンドラが数える) */
volatile std::sig_atomic_t sigpipeCount = 0;

/** @brief SIGPIPEを数えるだけのハンドラ。プロセスは終了させない */
void countSigpipe(int) { ++sigpipeCount; }

/**
 * @class SigpipeHandlerScope
 * @brief スコープの間だけSIGPIPEのハンドラを差し替え、終了時に元の設定へ戻すRAII
 * @internal SIG_IGNは設定しない。writeAllがMSG_NOSIGNALで守られていることを確かめる目的のため
 */
class SigpipeHandlerScope {
   public:
    SigpipeHandlerScope() {
        struct sigaction action{};
        action.sa_handler = countSigpipe;
        sigemptyset(&action.sa_mask);
        installed_ = sigaction(SIGPIPE, &action, &previous_) == 0;
        sigpipeCount = 0;
    }
    SigpipeHandlerScope(const SigpipeHandlerScope&) = delete;
    SigpipeHandlerScope& operator=(const SigpipeHandlerScope&) = delete;
    ~SigpipeHandlerScope() {
        if (installed_) {
            sigaction(SIGPIPE, &previous_, nullptr);
        }
    }
    /** @brief ハンドラを差し替えられたか */
    bool installed() const { return installed_; }

   private:
    struct sigaction previous_{};
    bool installed_ = false;
};

/** @brief 現在から ms ミリ秒後の期限を返す */
std::chrono::steady_clock::time_point deadlineAfter(int ms) {
    return std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
}

}  // namespace

/**
 * @class ServerConnectorIoTest
 * @brief writeAll() とサーバ起動パス定数のテスト
 */
class ServerConnectorIoTest : public QObject {
    Q_OBJECT

   private slots:
    /** @brief 生きている相手へ全バイトを書き込める */
    void writeAllDeliversBytesToLivePeer();
    /** @brief 相手が閉じたソケットへの書込は、SIGPIPEでプロセスを終了させずfalseを返す */
    void writeAllFailsWithoutSigpipeWhenPeerClosed();
    /** @brief 相手が読まず送信バッファが満杯の非ブロッキングソケットでは、期限でfalseを返す */
    void writeAllHonoursDeadlineOnFullBuffer();
    /** @brief サーバ起動パスは configure 時に確定した絶対パスで、PATH検索に依存しない */
    void serverExecutablePathIsAbsolute();
};

void ServerConnectorIoTest::writeAllDeliversBytesToLivePeer() {
    int fds[2];
    QCOMPARE(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
    const char payload[] = "hazkey";
    QVERIFY(writeAll(fds[0], payload, sizeof(payload), deadlineAfter(1000)));
    std::array<char, sizeof(payload)> received{};
    QCOMPARE(read(fds[1], received.data(), received.size()),
             static_cast<ssize_t>(sizeof(payload)));
    QCOMPARE(QByteArray(received.data(), sizeof(payload) - 1), QByteArray("hazkey"));
    close(fds[0]);
    close(fds[1]);
}

void ServerConnectorIoTest::writeAllFailsWithoutSigpipeWhenPeerClosed() {
    // SIG_IGNではなく数えるだけのハンドラを使い、SIGPIPEが配送されたかどうかを観測する
    SigpipeHandlerScope scope;
    QVERIFY(scope.installed());

    int fds[2];
    QCOMPARE(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
    close(fds[1]);

    const char payload[] = "payload";
    QVERIFY(!writeAll(fds[0], payload, sizeof(payload), deadlineAfter(1000)));
    QCOMPARE(static_cast<int>(sigpipeCount), 0);

    // 対照: 通常のwrite()は同じ状況でSIGPIPEを配送する。テストが検出力を持つことの確認
    const ssize_t plain = write(fds[0], payload, sizeof(payload));
    QCOMPARE(plain, static_cast<ssize_t>(-1));
    QCOMPARE(errno, EPIPE);
    QCOMPARE(static_cast<int>(sigpipeCount), 1);
    close(fds[0]);
}

void ServerConnectorIoTest::writeAllHonoursDeadlineOnFullBuffer() {
    int fds[2];
    QCOMPARE(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
    const int flags = fcntl(fds[0], F_GETFL, 0);
    QVERIFY(flags >= 0);
    QVERIFY(fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) == 0);

    // ソケットの送信バッファを確実に超える大きさ。相手は読まない
    const std::vector<char> big(16 * 1024 * 1024, 'x');
    const auto start = std::chrono::steady_clock::now();
    QVERIFY(!writeAll(fds[0], big.data(), big.size(), deadlineAfter(200)));
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    QVERIFY2(elapsed.count() >= 150 && elapsed.count() < 3000,
             qPrintable(QStringLiteral("elapsed=%1ms").arg(elapsed.count())));
    close(fds[0]);
    close(fds[1]);
}

void ServerConnectorIoTest::serverExecutablePathIsAbsolute() {
    const QString path = QString::fromUtf8(HAZKEY_SERVER_EXECUTABLE_PATH);
    QVERIFY2(QDir::isAbsolutePath(path), qPrintable(path));
    QVERIFY2(path.endsWith(QStringLiteral("/hazkey-community-server")), qPrintable(path));
}

QTEST_GUILESS_MAIN(ServerConnectorIoTest)
#include "serverconnector_io_test.moc"

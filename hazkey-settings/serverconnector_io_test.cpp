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
#include <QFile>
#include <QTemporaryDir>
#include <array>
#include <chrono>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <future>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
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
    /** @brief 差し替え前のSIGPIPEの設定 */
    struct sigaction previous_{};
    /** @brief ハンドラを差し替えられたか */
    bool installed_ = false;
};

/**
 * @brief 現在からmsミリ秒後の期限を返す
 * @param ms 期限までの時間[ms]
 * @return 単調時計上の期限
 */
std::chrono::steady_clock::time_point deadlineAfter(int ms) {
    return std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
}

/**
 * @class SilentServer
 * @brief 接続を受け付けるが要求を一切読まず、応答も返さない偽サーバ
 *
 * [XDG_RUNTIME_DIR] を一時ディレクトリ (0700) へ差し替え、[ServerConnector::getSocketPath] が指す位置に待ち受ける
 * デストラクタで環境変数を元へ戻し、受け付けた接続とソケットを閉じる
 */
class SilentServer {
   public:
    SilentServer() {
        if (!dir_.isValid()) return;
        previousRuntimeDir_ = qgetenv("XDG_RUNTIME_DIR");
        hadRuntimeDir_ = qEnvironmentVariableIsSet("XDG_RUNTIME_DIR");
        qputenv("XDG_RUNTIME_DIR", QFile::encodeName(dir_.path()));

        const QByteArray path =
            QFile::encodeName(dir_.path() + "/hazkey-community-server." +
                              QString::number(getuid()) + ".sock");
        listenFd_ = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (listenFd_ < 0) return;
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        if (static_cast<size_t>(path.size()) >= sizeof(addr.sun_path)) return;
        std::memcpy(addr.sun_path, path.constData(), path.size() + 1);
        ready_ = ::bind(listenFd_, reinterpret_cast<sockaddr*>(&addr),
                        sizeof(addr)) == 0 &&
                 ::listen(listenFd_, 4) == 0;
    }
    SilentServer(const SilentServer&) = delete;
    SilentServer& operator=(const SilentServer&) = delete;
    ~SilentServer() {
        if (peerFd_ >= 0) ::close(peerFd_);
        if (listenFd_ >= 0) ::close(listenFd_);
        if (hadRuntimeDir_) {
            qputenv("XDG_RUNTIME_DIR", previousRuntimeDir_);
        } else {
            qunsetenv("XDG_RUNTIME_DIR");
        }
    }

    /** @brief 待ち受けの準備ができたか */
    bool ready() const { return ready_; }

    /**
 * @brief クライアントの接続をtimeoutMsまで待って受け付ける
 * @param timeoutMs 待機時間の上限[ms]
 * @return 接続を受け付けた場合はtrue
 */
    bool acceptClient(int timeoutMs) {
        struct pollfd pfd{};
        pfd.fd = listenFd_;
        pfd.events = POLLIN;
        if (::poll(&pfd, 1, timeoutMs) <= 0) return false;
        peerFd_ = ::accept(listenFd_, nullptr, nullptr);
        return peerFd_ >= 0;
    }

    /** @brief 受け付けた接続を閉じる (ハングしたクライアントを解放するための後始末) */
    void dropClient() {
        if (peerFd_ >= 0) {
            ::close(peerFd_);
            peerFd_ = -1;
        }
    }

   private:
    /** @brief 偽サーバのソケットを置く一時ディレクトリ */
    QTemporaryDir dir_;
    /** @brief 差し替え前の [XDG_RUNTIME_DIR] の値 */
    QByteArray previousRuntimeDir_;
    /** @brief 差し替え前に [XDG_RUNTIME_DIR] が設定されていたか */
    bool hadRuntimeDir_ = false;
    /** @brief 待ち受けソケットの記述子 (未使用は-1) */
    int listenFd_ = -1;
    /** @brief 受け付けた接続の記述子 (未使用は-1) */
    int peerFd_ = -1;
    /** @brief 待ち受けの準備ができたか */
    bool ready_ = false;
};

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
    /** @brief 実行中のRPCがなくても [cancelPendingTransaction] は安全に呼べ、何度呼んでも同じ (冪等) である */
    void cancelWithoutTransactionIsSafeAndIdempotent();
    /** @brief [cancelPendingTransaction] の後に開始する全RPCは、接続試行をせず直ちに失敗する (作業スレッド開始前の中断が失われない) */
    void cancelBeforeRpcFailsWithoutConnecting();
    /** @brief [beginSession] の後で [cancelPendingTransaction] を呼ぶと、続くセッションRPCと再接続が直ちに失敗する */
    void cancelBetweenSessionRpcsFailsFollowUpCalls();
    /** @brief RPC終了後はソケットの追跡が外れており、再利用されたfdに対して [cancelPendingTransaction] が shutdown を呼ばない */
    void cancelDoesNotTouchReusedDescriptorAfterRpc();
    /** @brief 応答しない相手への一時接続RPC ([getConfig]) を [cancelPendingTransaction] が直ちに打ち切る */
    void cancelInterruptsUnresponsiveTransact();
    /** @brief 応答しない相手へのセッションRPC ([getConfigInSession]) も同様に打ち切る */
    void cancelInterruptsUnresponsiveSessionCall();

   private:
    /**
 * @brief 応答しない偽サーバへ接続した状態でRPCを作業スレッドで実行し、[cancelPendingTransaction] 後の復帰時間を検証する
 * @param useSession trueなら [beginSession] のセッションRPC、falseなら一時接続RPCを実行する
 */
    void verifyCancelReturnsQuickly(bool useSession);
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

void ServerConnectorIoTest::cancelWithoutTransactionIsSafeAndIdempotent() {
    ServerConnector connector;
    connector.cancelPendingTransaction();
    connector.cancelPendingTransaction();
    connector.cancelPendingTransaction();
}

void ServerConnectorIoTest::cancelBeforeRpcFailsWithoutConnecting() {
    SilentServer server;
    QVERIFY(server.ready());

    ServerConnector connector;
    // 作業スレッドが開始する前 (RPC未実行) の中断
    connector.cancelPendingTransaction();

    const auto start = std::chrono::steady_clock::now();
    QVERIFY(!connector.getConfig().has_value());
    QVERIFY(!connector.getDefaultProfile().has_value());
    QVERIFY(!connector.reloadZenzaiModel());
    QVERIFY(!connector.clearAllHistory("default"));
    QVERIFY(!connector.beginSession());
    QVERIFY_EXCEPTION_THROWN(
        connector.setCurrentConfig(hazkey::config::CurrentConfig()),
        std::runtime_error);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    // 接続リトライ (8回x250ms) やサーバ起動の待ちに入らず、直ちに戻る
    QVERIFY2(elapsed.count() < 500,
             qPrintable(QStringLiteral("elapsed=%1ms").arg(elapsed.count())));
    // 待ち受けソケットには接続が一度も来ていない
    QVERIFY(!server.acceptClient(200));
}

void ServerConnectorIoTest::cancelBetweenSessionRpcsFailsFollowUpCalls() {
    SilentServer server;
    QVERIFY(server.ready());

    ServerConnector connector;
    QVERIFY(connector.beginSession());
    QVERIFY(server.acceptClient(2000));

    // [MainWindow::onResetConfiguration] の [beginSession] の直後に閉じられた状況
    connector.cancelPendingTransaction();

    const auto start = std::chrono::steady_clock::now();
    QVERIFY(!connector.getDefaultProfileInSession().has_value());
    QVERIFY(!connector.getConfigInSession().has_value());
    QVERIFY(!connector.reloadZenzaiModelInSession());
    QVERIFY(!connector.beginSession());
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    QVERIFY2(elapsed.count() < 500,
             qPrintable(QStringLiteral("elapsed=%1ms").arg(elapsed.count())));
    // 再接続も試みていない
    QVERIFY(!server.acceptClient(200));
    connector.endSession();
}

void ServerConnectorIoTest::cancelDoesNotTouchReusedDescriptorAfterRpc() {
    SilentServer server;
    QVERIFY(server.ready());

    ServerConnector connector;
    // 相手が接続直後に閉じるため、RPCは通信失敗で終わりソケットはconnector側でcloseされる
    std::thread worker([&connector]() { connector.getConfig(); });
    QVERIFY(server.acceptClient(5000));
    server.dropClient();
    worker.join();

    // 閉じられたfdの番号は再利用されやすい。追跡が残っていれば [cancelPendingTransaction] がこの新しいfdに対して shutdown を呼んでしまう
    int fds[2];
    QCOMPARE(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
    connector.cancelPendingTransaction();
    const char payload[] = "alive";
    const bool writable = ::send(fds[0], payload, sizeof(payload), MSG_NOSIGNAL) ==
                          static_cast<ssize_t>(sizeof(payload));
    char buf[sizeof(payload)] = {};
    const bool readable = writable && ::recv(fds[1], buf, sizeof(buf), 0) ==
                                          static_cast<ssize_t>(sizeof(buf));
    ::close(fds[0]);
    ::close(fds[1]);
    QVERIFY2(writable && readable, "cancel shut down a descriptor it no longer owns");
}

void ServerConnectorIoTest::verifyCancelReturnsQuickly(bool useSession) {
    SilentServer server;
    QVERIFY(server.ready());

    ServerConnector connector;
    if (useSession) {
        std::thread opener([&connector]() { connector.beginSession(); });
        QVERIFY(server.acceptClient(5000));
        opener.join();
    }

    std::promise<bool> done;
    std::future<bool> doneFuture = done.get_future();
    // 応答しない相手を最長120秒待つRPCを作業スレッドで開始する
    std::thread worker([&connector, &done, useSession]() {
        const bool gotConfig = useSession
                                   ? connector.getConfigInSession().has_value()
                                   : connector.getConfig().has_value();
        done.set_value(gotConfig);
    });
    if (!useSession) {
        QVERIFY2(server.acceptClient(5000), "client did not connect");
    }
    // ワーカーが送信を終えて応答待ちに入る時間を与える
    QTest::qWait(150);
    QCOMPARE(doneFuture.wait_for(std::chrono::milliseconds(0)),
             std::future_status::timeout);

    const auto start = std::chrono::steady_clock::now();
    connector.cancelPendingTransaction();
    const bool returned =
        doneFuture.wait_for(std::chrono::milliseconds(1000)) ==
        std::future_status::ready;
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    if (!returned) {
        // 失敗時もテストが120秒ハングしないよう、相手側を閉じてワーカーを解放する
        server.dropClient();
    }
    worker.join();
    QVERIFY2(returned, "cancelPendingTransaction did not interrupt the RPC");
    QVERIFY2(elapsed.count() < 1000,
             qPrintable(QStringLiteral("elapsed=%1ms").arg(elapsed.count())));
    QVERIFY2(!doneFuture.get(), "interrupted RPC must report failure");

    // 終了状態はコネクターごとで、別のコネクターには影響しない
    if (useSession) connector.endSession();
    ServerConnector fresh;
    QVERIFY(fresh.beginSession());
    fresh.endSession();
}

void ServerConnectorIoTest::cancelInterruptsUnresponsiveTransact() {
    verifyCancelReturnsQuickly(false);
}

void ServerConnectorIoTest::cancelInterruptsUnresponsiveSessionCall() {
    verifyCancelReturnsQuickly(true);
}

QTEST_GUILESS_MAIN(ServerConnectorIoTest)
#include "serverconnector_io_test.moc"

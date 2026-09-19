import Foundation

protocol SocketManagerDelegate: AnyObject {
    func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32)
        -> Data
    func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32)
    func socketManager(_ manager: SocketManager, clientDidDisconnect clientFd: Int32)
}

/// 同時接続クライアントの受入ポリシー
///
/// acceptされた各接続は独立したcomposition sessionを持つが、
/// それでも各接続は単一のサーバスレッド上でpoll対象のfdとリクエストごとの処理コストを消費するため、接続数には上限を設けている
enum ClientSessionLimit {
    static func accepts(currentCount: Int) -> Bool {
        currentCount < SocketManager.maxClientCount
    }
}

class SocketManager {
    weak var delegate: SocketManagerDelegate?

    /// 同時接続クライアントの最大数
    /// フル構成では、Fcitx5 + IBus + hazkey-settings = 3接続だが、
    /// 余裕分は一時的な再接続 (古いfdが回収される前にクライアントが再接続してくるケース) を吸収するためのもの
    /// テストが上限値を正確に操作できるようinternalにしている
    static let maxClientCount = 8

    /// 現在接続中のクライアント数
    var connectedClientCount: Int { clientFds.count }

    private var signalSources: [DispatchSourceSignal] = []
    private var continueServing = true

    private var serverFd: Int32 = -1
    private var clientFds: [Int32] = []
    private let socketPath: String
    private var pipeFds: [Int32] = [-1, -1]

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        closeSocket()
    }

    func setupSocket() throws {
        unlink(socketPath)

        serverFd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard serverFd != -1 else {
            throw SocketError.readFailed("Failed to create socket", errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path.0, socketPath, MemoryLayout.size(ofValue: addr.sun_path))

        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, addrSize)
            }
        }

        guard bindResult != -1 else {
            throw SocketError.readFailed("Failed to bind socket", errno)
        }

        guard chmod(socketPath, 0o600) != -1 else {
            throw SocketError.readFailed("Failed to set socket permissions", errno)
        }

        guard listen(serverFd, 10) != -1 else {
            throw SocketError.readFailed("Failed to listen", errno)
        }

        // 非ブロッキングに設定
        let flags = fcntl(serverFd, F_GETFL, 0)
        let fcntlRes = fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)
        if fcntlRes != 0 {
            NSLog("fcntl() failed")
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) != -1 else {
            throw SocketError.readFailed("Failed to bind pipe socket", errno)
        }
        pipeFds = fds
    }

    private func setupSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)

        let signalQueue = DispatchQueue(label: "dev.hiira.hazkey.server.socketmanager.signals")
        let signals = [SIGINT, SIGTERM, SIGHUP]

        for sig in signals {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { [weak self] in
                NSLog("Signal \(sig) received, shutting down...")
                self?.continueServing = false
                // poll を止める
                if let pipeFd = self?.pipeFds[1] {
                    close(pipeFd)
                    self?.pipeFds[1] = -1
                }
            }
            source.resume()
            self.signalSources.append(source)
        }
    }

    func startListening() {
        setupSignalHandlers()
        while continueServing {
            var pollFds: [pollfd] = []

            // 新規接続を検知するため、サーバソケットは常にpoll対象に含める
            pollFds.append(pollfd(fd: serverFd, events: Int16(POLLIN), revents: 0))

            // poll停止用のパイプ
            pollFds.append(pollfd(fd: pipeFds[0], events: Int16(POLLIN), revents: 0))

            // 接続中の全クライアントをpollする
            // polledClientFdsはfd集合のスナップショットで、このイテレーションではindex 2 + iが具体的なfdに対応する
            for clientFd in clientFds {
                pollFds.append(pollfd(fd: clientFd, events: Int16(POLLIN), revents: 0))
            }
            let polledClientFds = clientFds

            let pollRes = poll(&pollFds, nfds_t(pollFds.count), 1000)

            if pollRes < 0 {
                if errno == EINTR {
                    // シグナルを受信した
                    continue
                }
                NSLog("Poll failed: \(errno)")
                break
            }

            if pollRes == 0 {
                // タイムアウト
                continue
            }

            // シグナルハンドラによってパイプが閉じられた
            if pollFds[1].revents & Int16(POLLIN|POLLHUP) != 0 {
                break
            }

            // 新規接続をacceptするより先に、既存クライアントを処理する
            // acceptを最後に行うことで、accept()がこのイテレーション内でcloseClient()によって直前に解放されたfd番号を、
            // そのreventsが処理される前に再利用してしまう事態を防げる
            // これは旧来のpolledClientFd == currentClientFdという古いイベントに対するガードを、複数fdに対応させたものに相当する
            // さらに下のclientFds.containsチェックは、同一イテレーション内で既にクローズされたfdをスキップする
            for (index, polledFd) in polledClientFds.enumerated() {
                guard clientFds.contains(polledFd) else { continue }
                let clientEvents = Int32(pollFds[2 + index].revents)

                if clientEvents & POLLHUP != 0 || clientEvents & POLLERR != 0 {
                    NSLog("Client disconnected or error: \(polledFd)")
                    closeClient(polledFd)
                    continue
                }

                if clientEvents & POLLIN != 0 {
                    handleClientData(polledFd)
                }
            }

            // サーバソケットに新規接続があるか確認
            if pollFds[0].revents & Int16(POLLIN) != 0 {
                handleNewConnection()
            }
        }
    }

    /// 保留中の接続を1件acceptする
    /// pollループを介さずテストが実際のaccept経路を直接実行できるよう、privateではなくinternalにしている
    func handleNewConnection() {
        var clientAddr = sockaddr()
        var clientLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let newClientFd = accept(serverFd, &clientAddr, &clientLen)

        if newClientFd != -1 {
            // マルチクライアントの契約:
            // 各接続は自分自身のセッションを保持し、新規接続が既存クライアントを追い出すことはない
            // 上限を超える場合は、代わりに新規接続を拒否する (即座にクローズする)
            if !ClientSessionLimit.accepts(currentCount: clientFds.count) {
                NSLog(
                    "Client limit reached (\(Self.maxClientCount)); rejecting connection \(newClientFd)"
                )
                close(newClientFd)
                return
            }

            // 新規クライアントをセットアップする
            NSLog("Client connected: \(newClientFd)")

            // クライアントを非ブロッキングにする
            let clientFlags = fcntl(newClientFd, F_GETFL, 0)
            let fcntlRes = fcntl(newClientFd, F_SETFL, clientFlags | O_NONBLOCK)
            if fcntlRes != 0 {
                NSLog("fcntl() failed for client")
                close(newClientFd)
            } else {
                clientFds.append(newClientFd)
                delegate?.socketManager(self, clientDidConnect: newClientFd)
            }
        }
    }

    private func handleClientData(_ clientFd: Int32) {
        do {
            // クライアントのリクエストを処理する
            let maxMessageSize: UInt32 = 1024 * 1024  // 1[MB]の上限

            // メッセージ長ヘッダを読み込む
            debugLog("Reading data from client \(clientFd)...")
            let lengthData = try readData(from: clientFd, count: 4)
            let readLen = lengthData.withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            debugLog("Message length: \(readLen)")

            // 妥当性チェック
            guard readLen <= maxMessageSize else {
                throw SocketError.messageTooLarge(readLen)
            }

            // メッセージボディを読み込む
            let query = try readData(from: clientFd, count: Int(readLen))
            debugLog("Successfully read \(query.count) bytes")

            // 処理してレスポンスを返す
            let response =
                delegate?.socketManager(self, didReceiveData: query, from: clientFd) ?? Data()
            debugLog("Processed request, response size: \(response.count)")

            // レスポンス長を書き込む
            var writeLen = UInt32(response.count).bigEndian
            let lengthHeader = withUnsafeBytes(of: &writeLen) { Data($0) }
            try writeData(to: clientFd, data: lengthHeader)

            // レスポンスボディを書き込む
            try writeData(to: clientFd, data: response)

            fsync(clientFd)
            debugLog("Successfully wrote response")

        } catch let error as SocketError {
            handleSocketError(error, clientFd: clientFd)
        } catch {
            NSLog("An unexpected error occurred: \(error)")
            closeClient(clientFd)
        }
    }

    private func handleSocketError(_ error: SocketError, clientFd: Int32) {
        switch error {
        case .clientDisconnected(let msg):
            NSLog(msg)
        case .readFailed(let msg, let err):
            NSLog("Read failed: \(msg), errno: \(err)")
        case .incompleteRead(let msg), .incompleteWrite(let msg):
            NSLog(msg)
        case .messageTooLarge(let len):
            NSLog("Message too large: \(len)")
        case .writeFailed(let msg, let err):
            NSLog("Write failed: \(msg), errno: \(err)")
        case .ioTimeout(let msg):
            NSLog("Socket I/O timeout: \(msg)")
        default:
            NSLog("Socket error: \(error)")
        }
        closeClient(clientFd)
    }

    private func closeClient(_ clientFd: Int32) {
        // 既に削除済みの場合はNOP (同一イテレーション内で先に閉じられたfdに対する古いpollイベント、または、重複したHUP / ERRの場合等)
        guard clientFds.contains(clientFd) else { return }
        NSLog("Closing client connection: \(clientFd)")
        close(clientFd)
        clientFds.removeAll { $0 == clientFd }
        delegate?.socketManager(self, clientDidDisconnect: clientFd)
    }

    func closeSocket() {
        for clientFd in clientFds {
            close(clientFd)
        }
        clientFds.removeAll()

        if serverFd != -1 {
            close(serverFd)
            serverFd = -1
        }

        unlink(socketPath)
    }
}

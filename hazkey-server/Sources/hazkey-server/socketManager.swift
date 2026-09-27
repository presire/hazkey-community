import Foundation

/// サーバが実装するソケットイベントの委譲先
///
/// 接続の確立と切断の通知と受信データの処理を受け持つ
protocol SocketManagerDelegate: AnyObject {
    /// 受信データを処理して応答バイト列を返す
    ///
    /// - Parameters:
    ///   - manager: イベント元のSocketManager
    ///   - data: 受信した要求バイト列
    ///   - clientFd: 送信元のクライアントfd
    /// - Returns: 返送する応答バイト列
    func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32)
        -> Data
    /// クライアント接続の確立を通知する
    ///
    /// - Parameters:
    ///   - manager: イベント元のSocketManager
    ///   - clientFd: 接続したクライアントfd
    func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32)
    /// クライアント接続の切断を通知する
    ///
    /// - Parameters:
    ///   - manager: イベント元のSocketManager
    ///   - clientFd: 切断したクライアントfd
    func socketManager(_ manager: SocketManager, clientDidDisconnect clientFd: Int32)
}

/// 同時接続クライアントの受入ポリシー
///
/// acceptされた各接続は、独立したcomposition sessionを持つ
///
/// それでも各接続は、単一サーバスレッド上でpoll対象のfdと処理コストを消費するため接続数に上限を設ける
enum ClientSessionLimit {
    /// 現在数で新規接続を受け入れ可能か判定する
    ///
    /// - Parameter currentCount: 現在の接続数
    /// - Returns: 現在数が[maxClientCount]未満の場合にtrueを返す
    static func accepts(currentCount: Int) -> Bool {
        currentCount < SocketManager.maxClientCount
    }
}

/// クライアントを受け入れて全fdを単一スレッドでpollする管理者
///
/// サーバソケットと自己パイプと全クライアントfdを1つのループで監視する
class SocketManager {
    /// イベントの委譲先であるサーバ
    ///
    /// 循環参照を避けるためweak参照で保持する
    weak var delegate: SocketManagerDelegate?

    /// 同時接続クライアントの最大数
    ///
    /// フル構成では、Fcitx5とIBusとhazkey-community-settingsの3接続になる
    ///
    /// 余裕分は、一時的な再接続を吸収するためのものである
    ///
    /// 古いfdが回収される前に、クライアントが再接続する呼び出しを想定している
    ///
    /// - Note: テストが上限値を正確に操作できるようinternalにしている
    static let maxClientCount = 8

    /// 現在接続中のクライアント数
    var connectedClientCount: Int { clientFds.count }

    /// シグナル待受用のDispatchSource群
    ///
    /// ループ終了まで登録を保持するために所有する
    private var signalSources: [DispatchSourceSignal] = []
    /// trueの間ループを継続する停止フラグ
    ///
    /// シグナル受信時にfalseへ変わる
    private var continueServing = true

    /// サーバソケットのfd
    ///
    /// 初期値は-1であり設定前は無効である
    private var serverFd: Int32 = -1
    /// 接続中クライアントのfd一覧
    ///
    /// poll集合と接続数の根拠になる
    private var clientFds: [Int32] = []
    /// 待ち受けるUNIXドメインソケットのパス
    ///
    /// 初期化時に受け取り以後は変わらない
    private let socketPath: String
    /// pollを起こす自己パイプのfd対
    ///
    /// 初期値は無効値の対であり書込端のクローズがループ停止の合図になる
    private var pipeFds: [Int32] = [-1, -1]

    /// ソケットパスを保持して初期化する
    ///
    /// - Parameter socketPath: 待ち受けるソケットのパス
    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// ソケットを閉じて終了する
    ///
    /// closeSocketを呼び出して資源を解放する
    deinit {
        closeSocket()
    }

    /// 待ち受けソケットと自己パイプを準備する
    ///
    /// 古いパスをunlinkしてAF_UNIXストリームソケットを作りbindして、権限0600でlisten(10)する
    ///
    /// サーバソケットは[O_NONBLOCK]で非ブロッキング化して、自己パイプを作る
    ///
    /// - Throws: 作成とbindと権限設定とlistenとパイプ作成の失敗時に、SocketError.readFailedを送出する
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

    /// シグナルハンドラを登録する
    ///
    /// [SIGPIPE]を無視し[SIGINT]と[SIGTERM]と[SIGHUP]でcontinueServingをfalseにする
    ///
    /// パイプ書込端を閉じてpollを起こし、ループを停止させる
    private func setupSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)

        let signalQueue = DispatchQueue(label: "dev.hiira.hazkey.server.socketmanager.signals")
        let signals = [SIGINT, SIGTERM, SIGHUP]

        for sig in signals {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { [weak self] in
                NSLog("Signal \(sig) received, shutting down...")
                self?.continueServing = false
                // pollを止める
                if let pipeFd = self?.pipeFds[1] {
                    close(pipeFd)
                    self?.pipeFds[1] = -1
                }
            }
            source.resume()
            self.signalSources.append(source)
        }
    }

    /// 全fdをpollする単一スレッドの主ループを実行する
    ///
    /// poll集合はサーバソケットとパイプ読取端と全クライアントfdであり待機は1000[ms]である
    ///
    /// [EINTR]とタイムアウトはループを継続する
    ///
    /// [POLLIN]または[POLLHUP]のあるパイプはループを抜ける
    ///
    /// - Note: 既存クライアントをacceptより先に処理するため、同一反復で解放したfd番号の再利用がrevents処理より先に起きない
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

            // 新規接続をacceptするより先に既存クライアントを処理する
            //
            // acceptを最後に行うことで同一反復内のcloseClientによるfd番号解放の再利用をrevents処理より前に防ぐ
            //
            // 旧来の単一fdガードを複数fdに対応させたものである
            //
            // さらに下のcontains確認は同一反復で既に閉じたfdをスキップする
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
    ///
    /// 上限超過時は即時クローズで拒否して、それ以外は非ブロッキング化して追加し委譲先へ通知する
    ///
    /// 各接続は独自セッションを保ち、新規接続が既存クライアントを追い出すことはない
    ///
    /// - Note: pollループを介さずテストが実際のaccept経路を実行できるよう、internalにしている
    func handleNewConnection() {
        var clientAddr = sockaddr()
        var clientLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let newClientFd = accept(serverFd, &clientAddr, &clientLen)

        if newClientFd != -1 {
            // マルチクライアントの契約である
            //
            // 各接続は独自セッションを保ち新規接続が既存クライアントを追い出すことはない
            //
            // 上限超過時は新規接続を即時クローズで拒否する
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

    /// 1要求を読み処理し応答を書き戻す
    ///
    /// 4バイトのビッグエンディアン長を読み本体が1[MB]以下であることを検証する
    ///
    /// 委譲先の処理結果に4バイト長を付けて書き込みfsyncする
    ///
    /// - Parameter clientFd: 処理対象のクライアントfd
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

    /// SocketErrorの種類を記録してクライアントを閉じる
    ///
    /// - Parameters:
    ///   - error: 発生したSocketError
    ///   - clientFd: 閉じる対象のクライアントfd
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

    /// クライアントfdを閉じて一覧から外し切断を通知する
    ///
    /// 既に外されたfdでは何もせずに返す
    ///
    /// - Parameter clientFd: 閉じる対象のクライアントfd
    private func closeClient(_ clientFd: Int32) {
        // 既に外されたfdでは何もせずに返す
        //
        // 同一反復内の古いpollイベントまたは[POLLHUP]と[POLLERR]の重複を想定している
        guard clientFds.contains(clientFd) else { return }
        NSLog("Closing client connection: \(clientFd)")
        close(clientFd)
        clientFds.removeAll { $0 == clientFd }
        delegate?.socketManager(self, clientDidDisconnect: clientFd)
    }

    /// 全クライアントとサーバソケットを閉じてパスをunlinkする
    ///
    /// deinitからも呼び出される終了処理である
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

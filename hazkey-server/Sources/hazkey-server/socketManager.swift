import Foundation
import Glibc
import CHazkeyLinux

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
    /// 接続上限時に、非活動の接続を閉じて枠を回収してよいかを返す
    ///
    /// 未確定の組成を持つ接続を閉じると入力が失われるため、委譲先が判断する
    ///
    /// - Parameters:
    ///   - manager: 問い合わせ元のSocketManager
    ///   - clientFd: 回収候補のクライアントfd
    /// - Returns: 閉じてよい場合はtrue
    func socketManager(_ manager: SocketManager, canReclaimIdleClient clientFd: Int32) -> Bool
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
    private let signalQueue = DispatchQueue(label: "dev.hiira.hazkey.server.socketmanager.signals")
    /// trueの間ループを継続する停止フラグ
    ///
    /// 自己パイプを観測した主ループだけがfalseへ変える
    private var continueServing = true

    /// サーバソケットのfd
    ///
    /// 初期値は-1であり設定前は無効である
    private var serverFd: Int32 = -1
    /// 接続中クライアントのfd一覧
    ///
    /// poll集合と接続数の根拠になる
    private var clientFds: [Int32] = []
    /// 接続ごとの未処理の受信バイト列
    ///
    /// 部分フレームと1回の処理上限を超えた完成済みフレームを保持し、切断時に破棄する
    private var receiveBuffers: [Int32: Data] = [:]
    /// 未完成の要求フレームの開始位置と絶対期限
    ///
    /// 追加受信では期限を延長せず、先行するフレームを処理した場合は開始位置だけを補正する
    private struct PartialFrame {
        /// 受信バッファ内で部分フレームが始まるバイト位置
        var offset: Int
        /// 部分フレームの最初の受信時点から数える絶対期限
        let deadline: ContinuousClock.Instant
    }
    /// 接続ごとに保持する部分フレームの期限情報
    private var partialFrames: [Int32: PartialFrame] = [:]
    private var lastActivity: [Int32: ContinuousClock.Instant] = [:]
    var activityClock: () -> ContinuousClock.Instant = { .now }
    static let idleClientTimeout: Duration = .seconds(60)
    static let responseTimeout: Duration = .milliseconds(2000)
    /// 部分フレームの最初の受信から完成までに許容する時間
    ///
    /// 追加受信では延長しない2秒の絶対期限を使う
    static let partialFrameTimeout: Duration = .milliseconds(2000)
    /// [handleClientData]を1回呼び出したときに処理する完成済みフレーム数の上限
    ///
    /// 16件で他の接続へ処理を譲り、残件は次の呼び出しへ持ち越す
    static let maxFramesPerTurn = 16
    /// 長さヘッダを含まない要求本体の最大バイト数
    static let maxMessageSize = 1024 * 1024
    /// 接続ごとの受信バッファに保持できる最大バイト数
    ///
    /// [maxMessageSize]の要求本体と4バイトの長さヘッダを保持できる大きさに制限する
    static let maxReceiveBufferSize = maxMessageSize + 4
    /// 待ち受けるUNIXドメインソケットのパス
    ///
    /// 初期化時に受け取り以後は変わらない
    private let socketPath: String
    /// pollを起こす自己パイプのfd対
    ///
    /// 初期値は無効値の対であり書込端への1バイトの書込みがループ停止の合図になる
    private var pipeFds: [Int32] = [-1, -1]
    private var ownsSocketPath = false

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
        var addr = sockaddr_un()
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path),
            !socketPath.utf8.contains(0) else {
            throw SocketError.readFailed("Socket path is too long or contains NUL", ENAMETOOLONG)
        }
        unlink(socketPath)

        serverFd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard serverFd != -1 else {
            throw SocketError.readFailed("Failed to create socket", errno)
        }

        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { source in
            withUnsafeMutableBytes(of: &addr.sun_path) { destination in
                destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: socketPath.utf8.count + 1))
            }
        }

        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, addrSize)
            }
        }

        guard bindResult != -1 else {
            throw SocketError.readFailed("Failed to bind socket", errno)
        }
        ownsSocketPath = true

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
        guard hazkey_pipe_cloexec(&fds) != -1 else {
            throw SocketError.readFailed("Failed to bind pipe socket", errno)
        }
        pipeFds = fds
    }

    /// シグナルハンドラを登録する
    ///
    /// [SIGPIPE]を無視し[SIGINT]と[SIGTERM]と[SIGHUP]を主ループへ通知する
    ///
    /// ハンドラは不変の書込fdだけを捕捉し、共有状態を変更しない
    private func setupSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)

        let signals = [SIGINT, SIGTERM, SIGHUP]
        let writeFD = pipeFds[1]

        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler {
                var byte: UInt8 = 1
                while Glibc.write(writeFD, &byte, 1) < 0, errno == EINTR {}
            }
            source.resume()
            self.signalSources.append(source)
        }
    }

    /// 全fdをpollする単一スレッドの主ループを実行する
    ///
    /// [poll]集合はサーバソケットとパイプ読取端と全クライアントfdであり、完成済みの残件があれば待機0、なければ1000[ms]である
    ///
    /// [EINTR]とタイムアウトはループを継続する
    ///
    /// [POLLIN]または[POLLHUP]のあるパイプはループを抜ける
    ///
    /// - Note: 既存クライアントをacceptより先に処理するため、同一反復で解放したfd番号の再利用がrevents処理より先に起きない
    func startListening() {
        setupSignalHandlers()
        defer { closeSocket() }
        while continueServing {
            drainBufferedClientData()
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

            let pollRes = poll(&pollFds, nfds_t(pollFds.count), pollTimeoutMs)

            if pollRes < 0 {
                if errno == EINTR {
                    // シグナルを受信した
                    continue
                }
                hazkeyLog("Poll failed: \(errno)")
                break
            }

            if pollRes == 0 {
                // タイムアウト
                continue
            }

            // 停止フラグとfdの所有権は主ループだけが変更する
            if pollFds[1].revents & Int16(POLLIN|POLLHUP) != 0 {
                continueServing = false
                NSLog("Shutdown signal received, shutting down...")
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
                    hazkeyLog("Client disconnected or error: \(polledFd)")
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
    /// 上限時は60秒以上非活動で、委譲先が回収を許可した接続のうち最古の1件だけを回収する
    ///
    /// - Note: pollループを介さずテストが実際のaccept経路を実行できるよう、internalにしている
    func handleNewConnection() {
        let newClientFd = hazkey_accept_cloexec(serverFd)

        if newClientFd != -1 {
            var peerUID: uid_t = 0
            guard hazkey_peer_uid(newClientFd, &peerUID) == 0, peerUID == getuid() else {
                hazkeyLog("Rejecting unauthenticated peer on fd \(newClientFd)")
                close(newClientFd)
                return
            }
            let now = activityClock()
            if clientFds.count == Self.maxClientCount,
                let oldest = clientFds.filter({ fd in
                    guard let activeAt = lastActivity[fd], now - activeAt >= Self.idleClientTimeout
                    else { return false }
                    return delegate?.socketManager(self, canReclaimIdleClient: fd) ?? true
                }).min(by: { (lastActivity[$0] ?? now) < (lastActivity[$1] ?? now) })
            {
                closeClient(oldest)
            }
            if !ClientSessionLimit.accepts(currentCount: clientFds.count) {
                hazkeyLog(
                    "Client limit reached (\(Self.maxClientCount)); rejecting connection \(newClientFd)"
                )
                close(newClientFd)
                return
            }

            // 新規クライアントをセットアップする
            hazkeyLog("Client connected: \(newClientFd)")

            // クライアントを非ブロッキングにする
            let clientFlags = fcntl(newClientFd, F_GETFL, 0)
            let fcntlRes = fcntl(newClientFd, F_SETFL, clientFlags | O_NONBLOCK)
            if fcntlRes != 0 {
                NSLog("fcntl() failed for client")
                close(newClientFd)
            } else {
                clientFds.append(newClientFd)
                receiveBuffers[newClientFd] = Data()
                lastActivity[newClientFd] = now
                delegate?.socketManager(self, clientDidConnect: newClientFd)
            }
        }
    }

    /// 現在読めるバイトを蓄積し、完成した要求だけを処理して応答を書き戻す
    ///
    /// 4バイトのビッグエンディアン長を読み、要求本体が[maxMessageSize]以下であることを検証する
    ///
    /// 委譲先の処理結果に4バイトの長さヘッダを付けて書き込み、[fsync]を呼ぶ
    ///
    /// 1回の呼び出しで受信する量は64KiB、処理する完成済みフレームは[maxFramesPerTurn]件までに制限する
    ///
    /// - Parameter clientFd: 処理対象のクライアントfd
    func handleClientData(_ clientFd: Int32) {
        guard var buffer = receiveBuffers[clientFd] else { return }
        do {
            // 接続の受け入れ時に[O_NONBLOCK]を設定済みのため、[read]は現在読める分だけを扱う
            // 受信量64KiBまたは完成済みフレーム16件で処理を譲り、単一接続による他の[poll]対象の占有を抑える
            // 部分フレームの追加受信は次の[POLLIN]へ委ね、追加受信では2秒の絶対期限を延長しない
            var readBudget = 64 * 1024
            var framesRemaining = Self.maxFramesPerTurn
            var chunk = [UInt8](repeating: 0, count: readBudget)
            if let partial = partialFrames[clientFd], activityClock() >= partial.deadline {
                throw SocketError.ioTimeout("Incomplete request frame exceeded its absolute deadline")
            }
            while true {
                var consumed = 0
                while framesRemaining > 0, buffer.count - consumed >= 4 {
                    let length = buffer.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: consumed, as: UInt32.self).bigEndian
                    }
                    guard length <= UInt32(Self.maxMessageSize) else {
                        throw SocketError.messageTooLarge(length)
                    }
                    let frameSize = 4 + Int(length)
                    guard buffer.count - consumed >= frameSize else { break }
                    let start = buffer.startIndex + consumed + 4
                    let query = buffer.subdata(in: start..<(start + Int(length)))
                    try respond(to: query, clientFd: clientFd)
                    consumed += frameSize
                    framesRemaining -= 1
                }
                if consumed > 0 {
                    buffer = Data(buffer.dropFirst(consumed))
                    if var partial = partialFrames[clientFd] {
                        partial.offset -= consumed
                        partialFrames[clientFd] = partial
                    }
                }
                guard framesRemaining > 0, readBudget > 0 else { break }
                if let partial = partialFrames[clientFd], activityClock() >= partial.deadline {
                    throw SocketError.ioTimeout("Incomplete request frame exceeded its absolute deadline")
                }
                let capacity = min(readBudget, Self.maxReceiveBufferSize - buffer.count)
                guard capacity > 0 else {
                    throw SocketError.readFailed("Receive buffer limit exceeded", EMSGSIZE)
                }
                let count = Glibc.read(clientFd, &chunk, capacity)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    throw SocketError.readFailed("Failed to read available client data", errno)
                }
                guard count > 0 else {
                    throw SocketError.clientDisconnected("Client closed the receive stream")
                }
                guard buffer.count + count <= Self.maxReceiveBufferSize else {
                    throw SocketError.readFailed("Receive buffer limit exceeded", EMSGSIZE)
                }
                buffer.append(contentsOf: chunk.prefix(count))
                readBudget -= count
                lastActivity[clientFd] = activityClock()
                try updatePartialFrameDeadline(buffer: buffer, clientFd: clientFd)
            }
            receiveBuffers[clientFd] = buffer
        } catch let error as SocketError {
            handleSocketError(error, clientFd: clientFd)
        } catch {
            hazkeyLog("An unexpected error occurred: \(error)")
            closeClient(clientFd)
        }
    }

    /// 部分フレームの期限を検査し、受信済みの完成した要求を処理する
    ///
    /// 主ループの各反復で期限切れの接続を閉じ、新たな[POLLIN]がなくても完成済みの残件を処理する
    ///
    /// - Note: 接続ごとの残件処理は[handleClientData]へ委譲し、1回あたり[maxFramesPerTurn]件に制限する
    func drainBufferedClientData() {
        let now = activityClock()
        for clientFd in clientFds {
            guard clientFds.contains(clientFd) else { continue }
            if let partial = partialFrames[clientFd], now >= partial.deadline {
                handleSocketError(.ioTimeout("Incomplete request frame exceeded its absolute deadline"), clientFd: clientFd)
            }
        }
        for clientFd in clientFds {
            guard clientFds.contains(clientFd), let buffer = receiveBuffers[clientFd], buffer.count >= 4 else { continue }
            let length = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            if length > UInt32(Self.maxMessageSize) || buffer.count >= 4 + Int(length) {
                handleClientData(clientFd)
            }
        }
    }

    /// 受信バッファの状態に応じた[poll]の待機時間
    ///
    /// 完成済みの残件があれば待機を省略し、部分フレームだけの場合は追加受信を待ってビジーループを避ける
    ///
    /// - Returns: 完成済みの残件がある場合は0、それ以外は1000[ms]
    var pollTimeoutMs: Int32 {
        for clientFd in clientFds {
            guard let buffer = receiveBuffers[clientFd], buffer.count >= 4 else { continue }
            let length = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            if length <= UInt32(Self.maxMessageSize), buffer.count >= 4 + Int(length) {
                return 0
            }
        }
        return 1000
    }

    /// 受信バッファ内の部分フレームを特定し、絶対期限を更新する
    ///
    /// 同じ部分フレームへの追加受信では期限を維持し、後続の新しい部分フレームを受信した場合だけ期限を設定する
    ///
    /// - Parameters:
    ///   - buffer: 現在の未処理の受信バイト列
    ///   - clientFd: 期限情報を更新する接続のfd
    /// - Throws: 要求本体の長さが[maxMessageSize]を超える場合は[SocketError.messageTooLarge]
    /// - Note: バッファが空の場合や完成済みフレームだけの場合は、期限情報を破棄する
    private func updatePartialFrameDeadline(buffer: Data, clientFd: Int32) throws {
        var offset = 0
        while buffer.count - offset >= 4 {
            let length = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
            guard length <= UInt32(Self.maxMessageSize) else { throw SocketError.messageTooLarge(length) }
            let size = 4 + Int(length)
            guard buffer.count - offset >= size else { break }
            offset += size
        }
        if offset == buffer.count {
            partialFrames.removeValue(forKey: clientFd)
        } else if partialFrames[clientFd]?.offset != offset {
            // 完成済みフレームの後ろにある部分フレームも、要求の処理を待たず受信時点から期限を数える
            partialFrames[clientFd] = PartialFrame(
                offset: offset, deadline: activityClock().advanced(by: Self.partialFrameTimeout))
        }
    }

    /// 完成した要求を委譲先へ渡し、長さヘッダ付きの応答を返す
    ///
    /// ヘッダと本体の書き込みには、[responseTimeout]から求めた共通の絶対期限を使う
    ///
    /// - Parameters:
    ///   - query: 長さヘッダを除いた要求本体
    ///   - clientFd: 応答先の接続のfd
    /// - Throws: 応答の書き込みに失敗した場合や期限を超えた場合は[SocketError]
    private func respond(to query: Data, clientFd: Int32) throws {
        let response = delegate?.socketManager(self, didReceiveData: query, from: clientFd) ?? Data()
        var writeLen = UInt32(response.count).bigEndian
        let lengthHeader = withUnsafeBytes(of: &writeLen) { Data($0) }
        let writeDeadline = ContinuousClock.now.advanced(by: Self.responseTimeout)
        try writeData(to: clientFd, data: lengthHeader, deadline: writeDeadline)
        try writeData(to: clientFd, data: response, deadline: writeDeadline)
        fsync(clientFd)
        lastActivity[clientFd] = activityClock()
    }

    /// SocketErrorの種類を記録してクライアントを閉じる
    ///
    /// - Parameters:
    ///   - error: 発生したSocketError
    ///   - clientFd: 閉じる対象のクライアントfd
    private func handleSocketError(_ error: SocketError, clientFd: Int32) {
        switch error {
        case .clientDisconnected(let msg):
            hazkeyLog(msg)
        case .readFailed(let msg, let err):
            hazkeyLog("Read failed: \(msg), errno: \(err)")
        case .incompleteRead(let msg), .incompleteWrite(let msg):
            hazkeyLog(msg)
        case .messageTooLarge(let len):
            hazkeyLog("Message too large: \(len)")
        case .writeFailed(let msg, let err):
            hazkeyLog("Write failed: \(msg), errno: \(err)")
        case .ioTimeout(let msg):
            hazkeyLog("Socket I/O timeout: \(msg)")
        default:
            hazkeyLog("Socket error: \(error)")
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
        hazkeyLog("Closing client connection: \(clientFd)")
        close(clientFd)
        clientFds.removeAll { $0 == clientFd }
        receiveBuffers.removeValue(forKey: clientFd)
        partialFrames.removeValue(forKey: clientFd)
        lastActivity.removeValue(forKey: clientFd)
        delegate?.socketManager(self, clientDidDisconnect: clientFd)
    }

    /// 全クライアントとサーバソケットを閉じてパスをunlinkする
    ///
    /// deinitからも呼び出される終了処理である
    func closeSocket() {
        for source in signalSources { source.cancel() }
        signalQueue.sync {}
        signalSources.removeAll()
        for clientFd in clientFds {
            close(clientFd)
        }
        clientFds.removeAll()
        receiveBuffers.removeAll()
        partialFrames.removeAll()
        lastActivity.removeAll()
        for fd in pipeFds where fd != -1 { close(fd) }
        pipeFds = [-1, -1]

        if serverFd != -1 {
            close(serverFd)
            serverFd = -1
        }

        if ownsSocketPath {
            unlink(socketPath)
            ownsSocketPath = false
        }
    }
}

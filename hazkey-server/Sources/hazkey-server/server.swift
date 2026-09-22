import Foundation

class HazkeyServer: SocketManagerDelegate {
    private let processManager: ProcessManager
    private var socketManager: SocketManager
    /// 全接続で共有されるサーバ全体の変換エンジン・設定・学習状態
    /// ロック取得後に1度だけ生成される
    private var shared: HazkeySharedResources?
    /// クライアントfdをキーとした、接続単位の入力セッション
    /// サーバループはシングルスレッドなので、通常のDictionaryアクセスで十分
    private var sessions: [Int32: HazkeyServerState] = [:]

    private let runtimeDir: URL
    private let socketPath: String
    private let lockFilePath: String

    init() {
        let uid = getuid()
        self.runtimeDir = URL(
            fileURLWithPath:
                ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
                ?? "/tmp/hazkey-runtime-\(uid)", isDirectory: true)

        self.socketPath = "\(runtimeDir.path)/hazkey-server.\(uid).sock"
        self.lockFilePath = "\(runtimeDir.path)/hazkey-server.\(uid).lock"

        self.processManager = ProcessManager(lockFilePath: lockFilePath)
        self.socketManager = SocketManager(socketPath: socketPath)
        socketManager.delegate = self
    }

    func parseCommandLineArguments() -> Bool {
        let arguments = CommandLine.arguments
        for arg in arguments {
            if arg == "-r" || arg == "--replace" {
                return true
            }
        }
        return false
    }

    func start() throws {
        let forceRestart = parseCommandLineArguments()
        if !FileManager.default.fileExists(atPath: runtimeDir.path) {
            try FileManager.default.createDirectory(
                at: runtimeDir, withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700])
        }
        do {
            try processManager.tryLock(force: forceRestart)
        } catch ProcessManagerError.anotherInstanceRunning {
            // tryLock()がNSLog済み
            // 想定内の終了
            return
        } catch {
            NSLog("Failed to start hazkey-server: \(error)")
            exit(1)
        }
        self.shared = HazkeySharedResources(emojiDictionaryURL: nil)
        try socketManager.setupSocket()
        // [community] サーバ起動時にニューラル変換モデルをウォームアップする。
        // 初回推論はモデルロードとバックエンド (Vulkan) のデバイス・パイプライン初期化を
        // 支払うため、これをポーリング開始前に済ませて最初の打鍵から費用を外す。
        // この時点でソケットはlisten済みのため、ウォームアップ中に接続したクライアントは
        // バックログに滞留し、拒否されない。
        if let shared {
            NSLog("Warming up the neural conversion model...")
            let warmup = shared.reloadZenzaiModel()
            if warmup.status == .failed {
                NSLog("[hazkey] \(warmup.errorMessage)")
            } else {
                NSLog("Neural conversion model warmup finished.")
            }
        }
        // メインループ開始
        NSLog("start listening...")
        socketManager.startListening()
        // プロセス終了処理
        let _ = shared?.saveLearningData()
    }

    func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32)
        -> Data
    {
        guard let session = sessions[clientFd] else {
            NSLog("No session for client fd \(clientFd); dropping request.")
            return Data()
        }
        // ProtocolHandlerは薄いラッパーでリクエストごとに生成され、自身は状態を持たない
        return ProtocolHandler(state: session).processProto(data: data)
    }

    func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32) {
        guard let shared else { return }
        // fd再利用への対策:
        // OSは閉じたばかりの接続と同じfd番号を新しい接続に割り当てることがある
        // 新規セッションを作る前に、このfdに紐づく古いセッションを破棄しておく
        sessions.removeValue(forKey: clientFd)?.close()
        sessions[clientFd] = HazkeyServerState(shared: shared)
        NSLog("Session created for client fd \(clientFd) (\(sessions.count) active)")
    }

    func socketManager(_ manager: SocketManager, clientDidDisconnect clientFd: Int32) {
        guard let session = sessions.removeValue(forKey: clientFd) else { return }
        session.close()
        let _ = shared?.saveLearningData()
        NSLog("Session closed for client fd \(clientFd) (\(sessions.count) active)")
    }
}

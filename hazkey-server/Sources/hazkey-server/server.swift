import Foundation

/// SocketManagerDelegateに準拠したサーバ本体
///
/// 起動時の排他ロックとソケット待受と全接続のセッション管理を担う
///
/// 変換エンジン自体はHazkeySharedResourcesに置き、全接続で共有する
class HazkeyServer: SocketManagerDelegate {
    /// 実行中プロセスの排他ロックを管理する
    ///
    /// ロックファイルの取得と強制置換を担当する
    private let processManager: ProcessManager
    /// Unixドメインソケットの待受と送受信を担当する
    ///
    /// デリゲートに自身を設定して使用する
    private var socketManager: SocketManager
    /// 全接続で共有される変換エンジンと設定と学習状態
    ///
    /// ロック取得後に1度だけ生成される
    private var shared: HazkeySharedResources?
    /// クライアントfdをキーとした接続単位の入力セッション
    ///
    /// サーバループはシングルスレッドのため通常のDictionaryで十分である
    private var sessions: [Int32: HazkeyServerState] = [:]

    /// ランタイムディレクトリのパス
    ///
    /// [XDG_RUNTIME_DIR]から導出し、未設定時はフォールバックを使う
    private let runtimeDir: URL
    /// ソケットファイルのパス
    ///
    /// ランタイムディレクトリ直下のサーバ名とUIDから作られる
    private let socketPath: String
    /// ロックファイルのパス
    ///
    /// ランタイムディレクトリ直下のサーバ名とUIDから作られる
    private let lockFilePath: String

    /// パスを組み立ててProcessManagerとSocketManagerを生成する
    ///
    /// [XDG_RUNTIME_DIR]が未設定の場合は、一時ディレクトリへのフォールバックを使う
    ///
    /// - Note: デリゲートに自身を設定する
    init() {
        let uid = getuid()
        self.runtimeDir = URL(
            fileURLWithPath:
                ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
                ?? "/tmp/hazkey-community-runtime-\(uid)", isDirectory: true)

        self.socketPath = "\(runtimeDir.path)/hazkey-community-server.\(uid).sock"
        self.lockFilePath = "\(runtimeDir.path)/hazkey-community-server.\(uid).lock"

        self.processManager = ProcessManager(lockFilePath: lockFilePath)
        self.socketManager = SocketManager(socketPath: socketPath)
        socketManager.delegate = self
    }

    /// コマンドライン引数を調べて強制置換の有無を返す
    ///
    /// [-r]または[--replace]が含まれる場合に真を返す
    ///
    /// - Returns: 強制置換が指定された場合は真、無い場合は偽
    func parseCommandLineArguments() -> Bool {
        let arguments = CommandLine.arguments
        for arg in arguments {
            if arg == "-r" || arg == "--replace" {
                return true
            }
        }
        return false
    }

    /// サーバを起動してメインループに入る
    ///
    /// ランタイムディレクトリの作成と排他ロックの取得と共有状態の生成とソケットの準備を順に行う
    ///
    /// 実行中の別サーバがいる場合は想定内のため静かに戻る
    ///
    /// ニューラル変換モデルを先に温めておき、最初の打鍵を速くする
    ///
    /// 終了時に学習データを保存する
    ///
    /// - Throws: ランタイムディレクトリの作成やソケットの準備に失敗した場合
    /// - Note: ウォームアップ中はソケットがlisten済みのため、接続は待機列で待つ
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
            // 別のサーバが既に動作している (ログはtryLock()内で出力済み)
            // 想定内のため、エラーにせず終了する
            return
        } catch {
            NSLog("Failed to start hazkey-community-server: \(error)")
            exit(1)
        }
        self.shared = HazkeySharedResources(emojiDictionaryURL: nil)
        try socketManager.setupSocket()
        // サーバ起動時に、ニューラル変換モデルをウォームアップする
        // 初回の推論ではモデルのロードとバックエンド(Vulkan)のデバイス・パイプライン初期化が走るため、
        // メインループの開始前に済ませて、最初の打鍵が遅くならないようにする
        //
        // この時点でソケットはlisten済みのため、ウォームアップ中に接続したクライアントは接続待ちキュー(バックログ)で待機し、拒否されない
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

    /// 受信データを対応する接続のセッションへ振り分ける
    ///
    /// セッションに対応するProtocolHandlerを作り、要求1件を処理する
    ///
    /// セッションが無いfdからの要求は破棄する
    ///
    /// - Parameters:
    ///   - manager: 通知元のSocketManager
    ///   - data: 受信した要求バイト列
    ///   - clientFd: 送信元クライアントのfd
    /// - Returns: 応答バイト列、セッションが無い場合は空である
    func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32)
        -> Data
    {
        guard let session = sessions[clientFd] else {
            NSLog("No session for client fd \(clientFd); dropping request.")
            return Data()
        }
        // ProtocolHandlerは薄いラッパーで要求ごとに生成され、自身は状態を持たない
        return ProtocolHandler(state: session).processProto(data: data)
    }

    /// 接続に対応する入力セッションを生成する
    ///
    /// 同じfdに古いセッションが残る場合は先に破棄する
    ///
    /// OSが閉じた直後のfd番号を再利用するためである
    ///
    /// - Parameters:
    ///   - manager: 通知元のSocketManager
    ///   - clientFd: 接続したクライアントのfd
    func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32) {
        guard let shared else { return }
        // fd再利用への対策:
        // OSは閉じたばかりの接続と同じfd番号を新しい接続に割り当てることがある
        // 新規セッションを作る前に、このfdに結び付く古いセッションを破棄しておく
        sessions.removeValue(forKey: clientFd)?.close()
        sessions[clientFd] = HazkeyServerState(shared: shared)
        NSLog("Session created for client fd \(clientFd) (\(sessions.count) active)")
    }

    /// 切断された接続のセッションを破棄して学習データを保存する
    ///
    /// - Parameters:
    ///   - manager: 通知元のSocketManager
    ///   - clientFd: 切断したクライアントのfd
    func socketManager(_ manager: SocketManager, clientDidDisconnect clientFd: Int32) {
        guard let session = sessions.removeValue(forKey: clientFd) else { return }
        session.close()
        let _ = shared?.saveLearningData()
        NSLog("Session closed for client fd \(clientFd) (\(sessions.count) active)")
    }
}

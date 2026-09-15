import Foundation

class HazkeyServer: SocketManagerDelegate {
    private let processManager: ProcessManager
    private var socketManager: SocketManager
    /// Server-wide converter, config, and learning state shared by every
    /// connection. Created once after the lock is acquired.
    private var shared: HazkeySharedResources?
    /// Per-connection composition sessions, keyed by client fd. The server
    /// loop is single-threaded, so plain-dictionary access is sufficient.
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
            // NSLogged by tryLock()
            // expected exit
            return
        } catch {
            NSLog("Failed to start hazkey-server: \(error)")
            exit(1)
        }
        self.shared = HazkeySharedResources(emojiDictionaryURL: nil)
        try socketManager.setupSocket()
        // start main loop
        NSLog("start listening...")
        socketManager.startListening()
        // finish process
        let _ = shared?.saveLearningData()
    }

    func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32)
        -> Data
    {
        guard let session = sessions[clientFd] else {
            NSLog("No session for client fd \(clientFd); dropping request.")
            return Data()
        }
        // ProtocolHandler is thin and per-request; no shared state of its own.
        return ProtocolHandler(state: session).processProto(data: data)
    }

    func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32) {
        guard let shared else { return }
        // fd-reuse safety: the OS may hand a fresh connection the same fd
        // number a just-closed connection used. Drop any stale session for
        // this fd before creating the new one.
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

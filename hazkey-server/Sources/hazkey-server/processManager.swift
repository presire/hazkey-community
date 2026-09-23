import Foundation
import Glibc

enum ProcessManagerError: Error {
    case lockCreationFailed
    case anotherInstanceRunning
    case terminationFailed
}

class ProcessManager {
    private let uid: uid_t
    private let pid: pid_t
    private let lockFilePath: String
    private var lockFd: Int32 = -1

    init(lockFilePath: String) {
        self.uid = getuid()
        self.pid = getpid()
        self.lockFilePath = lockFilePath
    }

    deinit {
        if lockFd != -1 {
            close(lockFd)
        }
    }

    func tryLock(force: Bool) throws {
        // 親ディレクトリは、HazkeyServer.start()が作成する

        // ロックを試行
        self.lockFd = open(lockFilePath, O_CREAT | O_RDWR, 0o600)
        guard self.lockFd != -1 else {
            NSLog("Failed to get lock info.")
            throw ProcessManagerError.lockCreationFailed
        }

        if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            // ロック失敗
            if let (oldPid, versionMatch) = readLockFile() {
                if !force, versionMatch {
                    NSLog("Another hazkey-community-server is already running.")
                    NSLog("Use -r or --replace option to replace the existing server.")
                    throw ProcessManagerError.anotherInstanceRunning
                }

                if !versionMatch {
                    NSLog("Version mismatch detected. Terminating old server...")
                }

                // プロセスを終了
                if kill(oldPid, 0) == 0 {
                    try terminateAnotherServer(pid: oldPid)
                }
            } else {
                // 壊れたロックファイル
                NSLog("Failed to read existing lock info.")
                terminateOtherServers()
            }

            // ロックを再試行
            close(lockFd)
            self.lockFd = open(lockFilePath, O_CREAT | O_RDWR, 0o600)
            if flock(self.lockFd, LOCK_EX | LOCK_NB) != 0 {
                NSLog("Failed to acquire lock after terminating existing process.")
                throw ProcessManagerError.anotherInstanceRunning
            }
        }

        // 現在のプロセス情報を書き込む
        writeLockFile()
    }

    private func readLockFile() -> (Int32, Bool)? {
        let capacity = 256
        lseek(lockFd, 0, SEEK_SET)
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }
        // 末尾バイトは0にする必要があるので capacity - 1
        let bytesRead = read(lockFd, buffer, capacity - 1)
        guard bytesRead > 0 else { return nil }
        let fullContent = String(cString: buffer)
        let lines = fullContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return nil }
        let versionMatch = lines[1] == hazkeyVersion
        guard let pid = Int32(lines[0]) else { return nil }
        return (pid, versionMatch)
    }

    private func writeLockFile() {
        guard ftruncate(lockFd, 0) == 0 else {
            NSLog("Failed to truncate lock file")
            return
        }
        lseek(lockFd, 0, SEEK_SET)
        let info = "\(getpid())\n\(hazkeyVersion)\n"
        let written = write(lockFd, info, info.utf8.count)
        if written != info.utf8.count {
            NSLog("Failed to write complete lock file data")
        }
        fsync(lockFd)
    }

    private func getOtherServerPIDs() throws -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // 実行ファイル名 "hazkey-community-server" は15文字を超え、/proc/<pid>/comm では切り詰められるため、
        // "pgrep -x" (comm照合) では一致しない
        // そのため、コマンドライン全体 (-f) に対して、argv[0]のファイル名が完全一致するものだけを照合する
        // (エディタで開いたファイルや "sh /usr/bin/hazkey-community-server" 等の誤一致を避ける)
        task.arguments = [
            "pgrep", "-u", String(uid), "-f", "^([^ ]*/)?hazkey-community-server( |$)",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let pidString = String(pid)

        return output.components(separatedBy: .newlines)
            .compactMap { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != pidString }
            .compactMap { Int32($0) }
    }

    private func terminateAnotherServer(pid: pid_t) throws {
        NSLog("Terminating existing server with PID \(pid)...")

        // SIGTERMを送って正常終了させる
        if kill(pid, SIGTERM) != 0 { return }

        for attempt in 1...30 {  // 30回試行 * 0.1秒
            usleep(100_000)  // 0.1秒

            // プロセスがまだ動いているか確認
            if kill(pid, 0) != 0 {
                NSLog("Existing server terminated successfully")
                return
            }

            if attempt == 15 {  // SIGKILLを試行
                NSLog("Server didn't respond to SIGTERM, sending SIGKILL...")
                kill(pid, SIGKILL)
            }
        }

        // 最終確認
        if kill(pid, 0) == 0 {
            NSLog("Failed to terminate existing server")
            throw ProcessManagerError.terminationFailed
        }

        NSLog("Existing server terminated")
    }

    private func terminateOtherServers() {
        let otherPids: [Int32]
        // ロックなしで動いているプロセスを終了させる
        do {
            otherPids = try getOtherServerPIDs()
        } catch {
            // getOtherServerPIDs()が失敗しても処理を続行する
            // サーバは既に終了しているため、通常は問題ない
            NSLog("getOtherServerPIDs failed: \(error)")
            otherPids = []
        }
        for killPid in otherPids {
            try? terminateAnotherServer(pid: killPid)
        }
    }
}

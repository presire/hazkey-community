import Foundation
import Glibc
import CHazkeyLinux

/// PIDを照合前に固定し、照合後の生存確認を経て同じプロセスだけへシグナルを送る
final class ServerProcessHandle {
    private let pid: pid_t
    private let fd: Int32
    private var legacySignals = false

    init?(pid: pid_t) {
        guard pid > 1, pid != getpid() else { return nil }
        self.pid = pid
        fd = hazkey_pidfd_open(pid)
        if fd < 0 {
            guard errno == ENOSYS else { return nil }
            legacySignals = true
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    var isRunning: Bool {
        if legacySignals { return ProcessManager.isSameUserServer(pid: pid) && kill(pid, 0) == 0 }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 0)
        return result == 0 || (result < 0 && errno == EINTR)
    }

    @discardableResult
    func send(_ signal: Int32) -> Bool {
        guard ProcessManager.isSameUserServer(pid: pid) else { return false }
        if !legacySignals {
            guard hazkey_pidfd_send_signal(fd, 0) == 0 else {
                guard errno == ENOSYS else { return false }
                legacySignals = true
                return send(signal)
            }
            return hazkey_pidfd_send_signal(fd, signal) == 0
        }
        return kill(pid, signal) == 0
    }
}

/// プロセス管理の失敗種別
///
/// ロック作成の失敗と多重起動と終了失敗を区別する
enum ProcessManagerError: Error {
    /// ロックファイルを開けなかった
    case lockCreationFailed
    /// 別インスタンスが動作中である
    case anotherInstanceRunning
    /// 旧サーバを終了できなかった
    case terminationFailed
}

/// 単一サーバ体制をflockで保つ管理者
///
/// ロックファイルで排他を確保する
///
/// バージョン不一致の旧サーバは置き換える
class ProcessManager {
    /// 実行ユーザID
    private let uid: uid_t
    /// 自プロセスID
    private let pid: pid_t
    /// ロックファイルのパス
    private let lockFilePath: String
    /// ロック用ファイル記述子(-1は未開封を示す)
    private var lockFd: Int32 = -1

    /// 管理者を初期化する
    ///
    /// uidとpidを取り込みロックパスを保持する
    ///
    /// - Parameter lockFilePath: ロックファイルのパス
    init(lockFilePath: String) {
        self.uid = getuid()
        self.pid = getpid()
        self.lockFilePath = lockFilePath
    }

    /// 開いていればロック記述子を閉じる
    deinit {
        if lockFd != -1 {
            close(lockFd)
        }
    }

    /// ロックを取得する
    ///
    /// ロックファイルを0600で開きflock(LOCK_EX|LOCK_NB)で試行する
    ///
    /// 失敗時はロックファイルを読みPIDとバージョン一致を確認する
    ///
    /// バージョン一致かつforceが偽の場合はanotherInstanceRunningを投げる
    ///
    /// バージョン不一致の場合は旧サーバを終了させる
    ///
    /// 書込み中の空ファイルは最大1秒だけ再読込みし、対象PIDが不明ならシグナルを送らない
    ///
    /// その後に開き直して再試行し失敗すればanotherInstanceRunningを投げる
    ///
    /// 成功時は自PIDとバージョンを書き込む
    ///
    /// - Parameter force: バージョン一致でも置き換える場合は真
    /// - Throws: 開けない場合はlockCreationFailed、置き換えられない場合は、anotherInstanceRunning、終了できない場合はterminationFailed
    func tryLock(force: Bool) throws {
        // 親ディレクトリは、HazkeyServer.start()が作成する

        // ロックを試行
        self.lockFd = try openValidatedLock()

        if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw ProcessManagerError.lockCreationFailed }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            var lockInfo = readLockFile()
            var acquired = false
            while lockInfo == nil, ContinuousClock.now < deadline {
                usleep(50_000)
                if flock(lockFd, LOCK_EX | LOCK_NB) == 0 {
                    acquired = true
                    break
                }
                lockInfo = readLockFile()
            }
            if acquired {
                try writeLockFile()
                return
            }
            if let (oldPid, versionMatch) = lockInfo {
                if !force, versionMatch {
                    NSLog("Another hazkey-community-server is already running.")
                    NSLog("Use -r or --replace option to replace the existing server.")
                    throw ProcessManagerError.anotherInstanceRunning
                }

                if !versionMatch {
                    NSLog("Version mismatch detected. Terminating old server...")
                }

                // プロセスを終了
                try terminateAnotherServer(pid: oldPid)
            } else {
                NSLog("Failed to read existing lock info; refusing replacement.")
                throw ProcessManagerError.anotherInstanceRunning
            }

            // ロックを再試行
            close(lockFd)
            self.lockFd = -1
            self.lockFd = try openValidatedLock()
            if flock(self.lockFd, LOCK_EX | LOCK_NB) != 0 {
                NSLog("Failed to acquire lock after terminating existing process.")
                throw ProcessManagerError.anotherInstanceRunning
            }
        }

        // 現在のプロセス情報を書き込む
        try writeLockFile()
    }

    /// リンクや他ユーザのファイルをロックとして使わない
    private func openValidatedLock() throws -> Int32 {
        let fd = open(lockFilePath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == EACCES {
                // SELinuxの有効時に、ドメイン外 (unconfined_t) の変換サーバが作ったファイル (user_tmp_t) が残ると、ここで拒否される
                hazkeyLog("Permission denied for the lock file \(lockFilePath).")
                hazkeyLog("If SELinux is enforcing, stop every hazkey-community-server and delete \(lockFilePath) and the socket file next to it.")
            }
            throw ProcessManagerError.lockCreationFailed
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == uid, info.st_nlink == 1 else {
            close(fd)
            throw ProcessManagerError.lockCreationFailed
        }
        return fd
    }

    /// ロックファイルを読みPIDとバージョン一致を返す
    ///
    /// 1行目をPIDとし2行目をバージョンとして照合する
    ///
    /// 読み取れない場合や行不足や形式不正ではnilを返す
    ///
    /// - Returns: PIDとバージョン一致の組、無効時はnil
    private func readLockFile() -> (Int32, Bool)? {
        let capacity = 256
        lseek(lockFd, 0, SEEK_SET)
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }
        // 末尾バイトは0にする必要があるのでcapacity - 1
        let bytesRead = read(lockFd, buffer, capacity - 1)
        guard bytesRead > 0 else { return nil }
        let fullContent = String(cString: buffer)
        let lines = fullContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, !lines[1].isEmpty else { return nil }
        let versionMatch = lines[1] == hazkeyVersion
        guard let pid = Int32(lines[0]), pid > 1, pid != self.pid else { return nil }
        return (pid, versionMatch)
    }

    /// PIDの再利用を考慮して、シグナル直前に実UIDと実行ファイル名を照合する
    static func isSameUserServer(pid: pid_t) -> Bool {
        guard pid > 1, pid != getpid(),
            let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8),
            let uidLine = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
            let realUID = uidLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first,
            UInt32(realUID) == getuid() else { return false }
        guard let executable = executablePath(of: "/proc/\(pid)/exe") else { return false }
        // 上流版Hazkeyの"hazkey-server"は併存対象なので名前では一致させず、自身と同じ実行ファイルの場合だけ許可する
        if URL(fileURLWithPath: executable).lastPathComponent == "hazkey-community-server" { return true }
        return executable == executablePath(of: "/proc/self/exe")
    }

    private static func executablePath(of link: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = readlink(link, &buffer, buffer.count - 1)
        guard length > 0, length < buffer.count - 1 else { return nil }
        var executable = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if executable.hasSuffix(" (deleted)") { executable.removeLast(" (deleted)".count) }
        return executable
    }

    /// 自PIDとバージョンをロックファイルに書く
    ///
    /// 先に内容を書き、最後に余剰を切り詰めて空ファイルになる窓を避ける
    private func writeLockFile() throws {
        let info = "\(getpid())\n\(hazkeyVersion)\n"
        try Array(info.utf8).withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ProcessManagerError.lockCreationFailed }
            var written = 0
            while written < bytes.count {
                let count = pwrite(lockFd, base.advanced(by: written), bytes.count - written, off_t(written))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProcessManagerError.lockCreationFailed }
                written += count
            }
        }
        guard ftruncate(lockFd, off_t(info.utf8.count)) == 0, fsync(lockFd) == 0 else {
            throw ProcessManagerError.lockCreationFailed
        }
    }

    /// 自分以外のサーバPIDを列挙する
    ///
    /// /procの実効UIDとargv[0]を照合する (pgrep -u/-fと同じ条件)
    ///
    /// 実行ファイル名hazkey-community-serverは15文字を超え、/proc/<pid>/commでは切り詰められるため"pgrep -x"では一致しない
    ///
    /// そのため起動コマンド行(-f)で照合し先頭引数の基底名が完全一致するものだけを集める
    ///
    /// 編集用に開いた文書や起動経路が異なる類似名の誤一致を避ける
    ///
    /// 自PIDは除外する
    ///
    /// - Returns: 他サーバのPID一覧
    /// - Throws: /procを列挙できない場合
    func getOtherServerPIDs() throws -> [Int32] {
        try FileManager.default.contentsOfDirectory(atPath: "/proc").compactMap { name in
            guard let otherPID = Int32(name), otherPID > 1, otherPID != pid,
                let status = try? readValidatedFileData(at: URL(fileURLWithPath: "/proc/\(name)/status"), limit: 65536),
                let uidLine = String(decoding: status, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
                let effectiveUID = uidLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst(2).first,
                UInt32(effectiveUID) == uid,
                let cmdline = try? readValidatedFileData(at: URL(fileURLWithPath: "/proc/\(name)/cmdline"), limit: 65536) else { return nil }
            let argv0 = cmdline.prefix { $0 != 0 }
            guard !argv0.isEmpty else { return nil }
            let command = String(decoding: argv0, as: UTF8.self)
            return command.range(of: "^([^ ]*/)?hazkey-community-server( |$)", options: .regularExpression) != nil ? otherPID : nil
        }
    }

    /// 別サーバを終了させる
    ///
    /// [SIGTERM]を送り0.1秒刻みで最大約3秒待つ
    ///
    /// 15回目で応答がなければ[SIGKILL]を送る
    ///
    /// 最後まで残る場合はterminationFailedを投げる
    ///
    /// - Parameter pid: 終了対象のプロセスID
    /// - Throws: 終了できない場合はterminationFailed
    private func terminateAnotherServer(pid: pid_t) throws {
        hazkeyLog("Terminating existing server with PID \(pid)...")

        // [SIGTERM]を送って正常終了させる
        guard let process = ServerProcessHandle(pid: pid), process.send(SIGTERM) else {
            hazkeyLog("Refusing to signal unverified or exited process \(pid)")
            return
        }

        for attempt in 1...30 {  // 30回試行*0.1秒
            usleep(100_000)  // 0.1秒

            // プロセスがまだ動いているか確認
            if !process.isRunning {
                NSLog("Existing server terminated successfully")
                return
            }

            if attempt == 15 {  // [SIGKILL]を試行
                guard process.send(SIGKILL) else {
                    hazkeyLog("Process identity changed or signal failed; refusing SIGKILL for \(pid)")
                    return
                }
                NSLog("Server didn't respond to SIGTERM, sending SIGKILL...")
            }
        }

        // 最終確認
        if process.isRunning {
            NSLog("Failed to terminate existing server")
            throw ProcessManagerError.terminationFailed
        }

        NSLog("Existing server terminated")
    }

}

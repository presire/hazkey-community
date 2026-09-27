import Foundation
import Glibc

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
    /// 読み取れない場合はpgrepで見つけた他サーバを終了させる
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
        guard lines.count >= 2 else { return nil }
        let versionMatch = lines[1] == hazkeyVersion
        guard let pid = Int32(lines[0]) else { return nil }
        return (pid, versionMatch)
    }

    /// 自PIDとバージョンをロックファイルに書く
    ///
    /// 先頭に切り詰めて2行で書き込みfsyncで確定する
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

    /// 自分以外のサーバPIDを列挙する
    ///
    /// pgrepにユーザIDと起動コマンド行照合を渡して探す
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
    /// - Throws: プロセス起動に失敗した場合
    private func getOtherServerPIDs() throws -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // 実行ファイル名hazkey-community-serverは15文字を超え、/proc/<pid>/commでは切り詰められるため、"pgrep -x"(comm照合)では一致しない
        // そのため、コマンドライン全体(-f)に対して、argv[0]のファイル名が完全一致するものだけを照合する
        // (エディタで開いたファイルや"sh /usr/bin/hazkey-community-server"等の誤一致を避ける)
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
        NSLog("Terminating existing server with PID \(pid)...")

        // [SIGTERM]を送って正常終了させる
        if kill(pid, SIGTERM) != 0 { return }

        for attempt in 1...30 {  // 30回試行*0.1秒
            usleep(100_000)  // 0.1秒

            // プロセスがまだ動いているか確認
            if kill(pid, 0) != 0 {
                NSLog("Existing server terminated successfully")
                return
            }

            if attempt == 15 {  // [SIGKILL]を試行
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

    /// 列挙できた他サーバを全て終了させる
    ///
    /// 取得に失敗してもログに残して処理を続ける
    ///
    /// - Note: 対象は通常既に終了しているため継続してよい
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

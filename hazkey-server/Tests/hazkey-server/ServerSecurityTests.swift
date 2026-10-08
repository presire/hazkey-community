import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class ServerSecurityTests: XCTestCase {
    func testRuntimeDirectoryRequiresPrivateOwnershipAndNonEmptyPath() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = "/tmp/hazkey-community-runtime-\(getuid())"
        XCTAssertEqual(ServerRuntimeDirectory.select(environment: [:]), fallback)
        XCTAssertEqual(ServerRuntimeDirectory.select(environment: ["XDG_RUNTIME_DIR": ""]), fallback)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(ServerRuntimeDirectory.select(environment: ["XDG_RUNTIME_DIR": root.path]), root.path)
        XCTAssertEqual(ServerRuntimeDirectory.select(environment: ["XDG_RUNTIME_DIR": root.path], uid: getuid() &+ 1),
                       "/tmp/hazkey-community-runtime-\(getuid() &+ 1)")
        XCTAssertEqual(chmod(root.path, 0o750), 0)
        XCTAssertEqual(ServerRuntimeDirectory.select(environment: ["XDG_RUNTIME_DIR": root.path]), fallback)
    }

    func testFallbackRejectsSymlinksAndUnsafeExistingDirectories() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("runtime").path
        try ServerRuntimeDirectory.prepare(path)
        try ServerRuntimeDirectory.prepare(path)
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(chmod(path, 0o755), 0)
        XCTAssertThrowsError(try ServerRuntimeDirectory.prepare(path))
        let link = root.appendingPathComponent("link").path
        XCTAssertEqual(symlink(path, link), 0)
        XCTAssertThrowsError(try ServerRuntimeDirectory.prepare(link))
    }

    func testOverlongSocketPathIsRejectedWithoutTruncation() {
        let manager = SocketManager(socketPath: "/tmp/" + String(repeating: "a", count: 108))
        XCTAssertThrowsError(try manager.setupSocket())
    }

    func testLockRejectsSymlinkHardlinkAndDirectory() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original").path
        let fd = open(original, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { close(fd) }
        let symlinkPath = root.appendingPathComponent("symlink").path
        XCTAssertEqual(symlink(original, symlinkPath), 0)
        XCTAssertThrowsError(try ProcessManager(lockFilePath: symlinkPath).tryLock(force: false))
        let hardlinkPath = root.appendingPathComponent("hardlink").path
        XCTAssertEqual(link(original, hardlinkPath), 0)
        XCTAssertThrowsError(try ProcessManager(lockFilePath: original).tryLock(force: false))
        XCTAssertThrowsError(try ProcessManager(lockFilePath: root.path).tryLock(force: false))
    }

    func testSignalVerificationRejectsSelfInvalidPIDAndNonServer() throws {
        XCTAssertFalse(ProcessManager.isSameUserServer(pid: 0))
        XCTAssertFalse(ProcessManager.isSameUserServer(pid: 1))
        XCTAssertFalse(ProcessManager.isSameUserServer(pid: getpid()))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        XCTAssertFalse(ProcessManager.isSameUserServer(pid: child.processIdentifier))
    }

    func testConfigSaveIsPrivateAndDoesNotFollowDestinationSymlink() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: target)
        let destination = root.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        try HazkeyServerConfig.writePrivateConfig(Data("new".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: HazkeyServerConfig.configJournalURL(for: destination).path))
    }

    func testConfigSaveOverwritesInPlaceAndRestrictsLegacyPermissions() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("config.json")
        try Data("old content that is longer".utf8).write(to: destination)
        XCTAssertEqual(chmod(destination.path, 0o644), 0)
        var before = stat()
        XCTAssertEqual(stat(destination.path, &before), 0)
        try HazkeyServerConfig.writePrivateConfig(Data("new".utf8), to: destination)
        var after = stat()
        XCTAssertEqual(stat(destination.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mode & 0o777, 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testConfigSaveRefusesHardLinkedDestination() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try Data("keep".utf8).write(to: other)
        let destination = root.appendingPathComponent("config.json")
        XCTAssertEqual(link(other.path, destination.path), 0)
        XCTAssertThrowsError(try HazkeyServerConfig.writePrivateConfig(Data("new".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: other), Data("keep".utf8))
    }

    func testLoadConfigRecoversFromInterruptedSave() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let savedConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        XCTAssertEqual(setenv("XDG_CONFIG_HOME", root.path, 1), 0)
        defer {
            if let savedConfigHome {
                setenv("XDG_CONFIG_HOME", savedConfigHome, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }
        let configDirectory = HazkeyServerConfig.getConfigDirectory()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.json")
        let journalURL = HazkeyServerConfig.configJournalURL(for: configURL)
        try Data(#"[{"profileName": "Recovered"}]"#.utf8).write(to: journalURL)

        // config.jsonの作成前に停止した場合
        XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, "Recovered")

        // config.jsonの上書き中に停止した場合
        try Data(#"[{"profileNa"#.utf8).write(to: configURL)
        XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, "Recovered")

        // config.jsonを書き終えてから一時ファイルを削除する前に停止した場合
        try Data(#"[{"profileName": "Saved"}]"#.utf8).write(to: configURL)
        XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, "Saved")

        // 一時ファイルも壊れている場合は、従来どおり読み込みエラーを返す
        try Data("{".utf8).write(to: journalURL)
        try Data("[".utf8).write(to: configURL)
        XCTAssertThrowsError(try HazkeyServerConfig.loadConfig())
    }

    func testReplaceAcceptsSwiftPMServerIdentityAndEvidenceRejectsSymlink() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = try XCTUnwrap(TestServerBinary.resolve(packageRoot: packageRoot))
        let evidenceTarget = root.appendingPathComponent("evidence-target")
        try Data("unchanged".utf8).write(to: evidenceTarget)
        let evidenceLink = root.appendingPathComponent("evidence-link")
        try FileManager.default.createSymbolicLink(at: evidenceLink, withDestinationURL: evidenceTarget)
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        for name in ["CONFIG", "DATA", "STATE", "CACHE"] {
            environment["XDG_\(name)_HOME"] = root.appendingPathComponent(name).path
        }
        environment["HAZKEY_PERF_EVIDENCE"] = evidenceLink.path
        environment["HAZKEY_ZENZAI_MODEL"] = root.appendingPathComponent("missing.gguf").path
        let lockPath = root.appendingPathComponent("runtime/hazkey-community-server.\(getuid()).lock")
        func start(_ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        func waitForLock(_ process: Process) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline {
                if let text = try? String(contentsOf: lockPath, encoding: .utf8),
                    text.hasPrefix("\(process.processIdentifier)\n") { return true }
                usleep(20_000)
            }
            return false
        }
        let first = try start([])
        defer { if first.isRunning { first.terminate() }; first.waitUntilExit() }
        guard waitForLock(first) else { XCTFail("First server did not acquire lock"); return }
        // 上流版と同じ名前 (hazkey-server) の別バイナリは、同一実行ファイル以外から終了対象にしない
        XCTAssertFalse(ProcessManager.isSameUserServer(pid: first.processIdentifier))
        let replacement = try start(["--replace"])
        defer { if replacement.isRunning { replacement.terminate() }; replacement.waitUntilExit() }
        guard waitForLock(replacement) else { XCTFail("Replacement server did not acquire lock"); return }
        first.waitUntilExit()
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(try Data(contentsOf: evidenceTarget), Data("unchanged".utf8))
        var info = stat()
        XCTAssertEqual(stat(lockPath.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testPermissionTighteningDoesNotFollowSymlinks() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        let linkPath = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: root)
        HazkeyServerConfig.tightenPrivateDirectory(linkPath)
        var info = stat()
        XCTAssertEqual(stat(root.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        HazkeyServerConfig.tightenPrivateDirectory(root)
        XCTAssertEqual(stat(root.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }
}

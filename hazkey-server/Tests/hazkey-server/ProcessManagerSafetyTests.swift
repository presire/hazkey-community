import Foundation
import Glibc
import CHazkeyLinux
import XCTest

@testable import hazkey_server

final class ProcessManagerSafetyTests: XCTestCase {
    private func sleeper(at root: URL, namedServer: Bool = true) throws -> Process {
        let executable = root.appendingPathComponent(namedServer ? "hazkey-community-server" : "not-a-server")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["30"]
        try child.run()
        return child
    }

    private func stop(_ child: Process) {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }

    func testEmptyContendedLockNeverKillsUnrelatedNamedServer() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try sleeper(at: root)
        defer { stop(child) }
        let lock = root.appendingPathComponent("empty.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return XCTFail("open failed") }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let start = ContinuousClock.now
        XCTAssertThrowsError(try ProcessManager(lockFilePath: lock.path).tryLock(force: true)) {
            XCTAssertTrue($0 is ProcessManagerError)
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(900))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertTrue(child.isRunning)
    }

    func testPartiallyWrittenLockIsRetriedBeforeDecision() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try sleeper(at: root)
        defer { stop(child) }
        let lock = root.appendingPathComponent("partial.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return XCTFail("open failed") }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let prefix = "\(child.processIdentifier)\n"
        XCTAssertEqual(prefix.withCString { write(fd, $0, prefix.utf8.count) }, prefix.utf8.count)
        let complete = "\(child.processIdentifier)\n\(hazkeyVersion)\n"
        let finished = expectation(description: "lock writer completed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            _ = complete.withCString { pwrite(fd, $0, complete.utf8.count, 0) }
            finished.fulfill()
        }
        let start = ContinuousClock.now
        XCTAssertThrowsError(try ProcessManager(lockFilePath: lock.path).tryLock(force: false))
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(100))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(800))
        wait(for: [finished], timeout: 1)
        XCTAssertTrue(child.isRunning)
    }

    func testLockWriteOverwritesThenTruncatesOldContents() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("old.lock")
        try Data(String(repeating: "obsolete", count: 100).utf8).write(to: lock)
        let manager = ProcessManager(lockFilePath: lock.path)
        try manager.tryLock(force: false)
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), "\(getpid())\n\(hazkeyVersion)\n")
    }

    func testPidfdSignalTargetsVerifiedProcessAndRejectsExitedProcess() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try sleeper(at: root)
        defer { stop(child) }
        let fd = hazkey_pidfd_open(child.processIdentifier)
        if fd < 0, errno == ENOSYS { throw XCTSkip("Kernel does not support pidfd") }
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(hazkey_pidfd_send_signal(fd, 0), 0)
        let handle = try XCTUnwrap(ServerProcessHandle(pid: child.processIdentifier))
        XCTAssertTrue(handle.isRunning)
        XCTAssertTrue(handle.send(SIGTERM))
        child.waitUntilExit()
        XCTAssertFalse(handle.isRunning)
        XCTAssertFalse(handle.send(SIGKILL))
        XCTAssertEqual(hazkey_pidfd_send_signal(fd, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testPidfdRefusesUnverifiedExecutable() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try sleeper(at: root, namedServer: false)
        defer { stop(child) }
        let handle = try XCTUnwrap(ServerProcessHandle(pid: child.processIdentifier))
        XCTAssertFalse(handle.send(SIGTERM))
        XCTAssertFalse(handle.send(SIGKILL))
        XCTAssertTrue(child.isRunning)
    }

    func testProcScanMatchesOnlyExactServerArgvBasename() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try sleeper(at: root)
        defer { stop(server) }
        let other = try sleeper(at: root, namedServer: false)
        defer { stop(other) }
        let pids = try ProcessManager(lockFilePath: root.appendingPathComponent("lock").path).getOtherServerPIDs()
        XCTAssertTrue(pids.contains(server.processIdentifier))
        XCTAssertFalse(pids.contains(other.processIdentifier))
        XCTAssertFalse(pids.contains(getpid()))
    }

    func testProcScanRejectsEmptyArgvZeroEvenWhenArgumentNamesServer() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("hazkey-community-server")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        var argv: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in argv { free(pointer) } }
        for argument in ["", fifo.path] {
            argv.append(try XCTUnwrap(strdup(argument)))
        }
        argv.append(nil)
        var childPID: pid_t = 0
        let error = hazkey_spawn_probe("/bin/cat", &argv, &childPID)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        defer {
            kill(childPID, SIGKILL)
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0, errno == EINTR {}
        }
        let pids = try ProcessManager(lockFilePath: root.appendingPathComponent("lock").path).getOtherServerPIDs()
        XCTAssertFalse(pids.contains(childPID))
    }

    func testVersionMismatchReplacesOnlyIsolatedServer() throws {
        try withIsolatedServerEnvironment { _ in
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let executable = try XCTUnwrap(TestServerBinary.resolve(packageRoot: package))
            let runtime = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"])
            try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let lock = URL(fileURLWithPath: runtime).appendingPathComponent("hazkey-community-server.\(getuid()).lock")
            func start() throws -> Process {
                let child = Process()
                child.executableURL = executable
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try child.run()
                return child
            }
            func waitForLock(_ child: Process) -> Bool {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while child.isRunning, ContinuousClock.now < deadline {
                    if let text = try? String(contentsOf: lock, encoding: .utf8),
                        text.hasPrefix("\(child.processIdentifier)\n") { return true }
                    usleep(20_000)
                }
                return false
            }
            let first = try start()
            defer { stop(first) }
            guard waitForLock(first) else { return XCTFail("First server did not acquire lock") }
            let fd = open(lock.path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { return XCTFail("open failed") }
            let old = "\(first.processIdentifier)\nold-version\n"
            XCTAssertEqual(old.withCString { pwrite(fd, $0, old.utf8.count, 0) }, old.utf8.count)
            XCTAssertEqual(ftruncate(fd, off_t(old.utf8.count)), 0)
            close(fd)
            let second = try start()
            defer { stop(second) }
            XCTAssertTrue(waitForLock(second))
            XCTAssertFalse(first.isRunning)
        }
    }
}

import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class SocketManagerSafetyTests: XCTestCase {
    private final class Delegate: SocketManagerDelegate {
        var response = Data(repeating: 65, count: 2 * 1024 * 1024)
        var connected: [Int32] = []
        var disconnected: [Int32] = []
        func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32) -> Data { response }
        func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32) { connected.append(clientFd) }
        func socketManager(_ manager: SocketManager, clientDidDisconnect clientFd: Int32) { disconnected.append(clientFd) }
        func socketManager(_ manager: SocketManager, canReclaimIdleClient clientFd: Int32) -> Bool { true }
    }

    private func connectClient(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                if let base = destination.baseAddress {
                    _ = strncpy(base.assumingMemoryBound(to: CChar.self), source, destination.count - 1)
                }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let error = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    func testStalledResponseDisconnectsAtTwoSecondsAndOtherClientContinues() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        manager.delegate = delegate
        let stalled = try connectClient(path)
        defer { close(stalled) }
        manager.handleNewConnection()
        let stalledServer = try XCTUnwrap(delegate.connected.first)
        var bufferSize: Int32 = 4096
        XCTAssertEqual(setsockopt(stalledServer, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size)), 0)
        let healthy = try connectClient(path)
        defer { close(healthy) }
        manager.handleNewConnection()
        let healthyServer = try XCTUnwrap(delegate.connected.last)
        try writeData(to: stalled, data: Data([0, 0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(SocketManager.responseTimeout, SocketManager.requestTimeout)
        let start = ContinuousClock.now
        manager.handleClientData(stalledServer)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(1900))
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        XCTAssertEqual(delegate.disconnected, [stalledServer])
        XCTAssertEqual(manager.connectedClientCount, 1)
        delegate.response = Data("healthy".utf8)
        try writeData(to: healthy, data: Data([0, 0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(healthyServer)
        XCTAssertEqual(try readData(from: healthy, count: 4, deadline: .now.advanced(by: .seconds(1))), Data([0, 0, 0, 7]))
        XCTAssertEqual(try readData(from: healthy, count: 7, deadline: .now.advanced(by: .seconds(1))), delegate.response)
    }

    private func transact(_ request: Hazkey_RequestEnvelope, fd: Int32) throws -> Hazkey_ResponseEnvelope {
        let body = try request.serializedData()
        var length = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        try writeData(to: fd, data: header + body, deadline: deadline)
        let responseHeader = try readData(from: fd, count: 4, deadline: deadline)
        let count = responseHeader.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard count <= 2 * 1024 * 1024 else { throw POSIXError(.EFBIG) }
        return try Hazkey_ResponseEnvelope(serializedBytes: readData(from: fd, count: Int(count), deadline: deadline))
    }

    func testSignalShutdownClosesSocketAndPersistsPendingLearning() throws {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            try withIsolatedServerEnvironment { _ in
                let runtime = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"])
                try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let config = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("config.json")
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                var profile = HazkeyServerConfig.genDefaultConfig()
                profile.zenzaiEnable = false
                profile.useInputHistory = true
                profile.stopStoreNewHistory = false
                try Data(("[" + profile.jsonString() + "]").utf8).write(to: config)
                let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                let process = Process()
                process.executableURL = try XCTUnwrap(TestServerBinary.resolve(packageRoot: package))
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
                let socketPath = URL(fileURLWithPath: runtime).appendingPathComponent("hazkey-community-server.\(getuid()).sock").path
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !FileManager.default.fileExists(atPath: socketPath), process.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
                let client = try connectClient(socketPath)
                defer { close(client) }
                XCTAssertEqual(try transact(.with { $0.newComposingText = .init() }, fd: client).status, .success)
                for character in "kanji" {
                    XCTAssertEqual(try transact(.with { $0.inputChar = .with { $0.text = String(character) } }, fd: client).status, .success)
                }
                let candidates = try transact(.with { $0.getCandidates = .with { $0.isSuggest = false } }, fd: client)
                let index = try XCTUnwrap(candidates.candidates.candidates.firstIndex { $0.text == "漢字" })
                XCTAssertEqual(try transact(.with { $0.prefixComplete = .with { $0.index = Int32(index) } }, fd: client).status, .success)
                XCTAssertEqual(kill(process.processIdentifier, signalNumber), 0)
                let exitDeadline = ContinuousClock.now.advanced(by: .seconds(4))
                while process.isRunning, ContinuousClock.now < exitDeadline { usleep(10_000) }
                XCTAssertFalse(process.isRunning)
                XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
                guard !process.isRunning else { return }
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                let state = HazkeyServerState()
                defer { state.close() }
                XCTAssertTrue(try state.shared.allLearningMemoryEntries().contains { $0.data.word == "漢字" })
            }
        }
    }
}

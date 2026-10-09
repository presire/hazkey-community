import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class SocketManagerSafetyTests: XCTestCase {
    private final class Delegate: SocketManagerDelegate {
        var response = Data(repeating: 65, count: 2 * 1024 * 1024)
        var connected: [Int32] = []
        var disconnected: [Int32] = []
        var received: [Data] = []
        func socketManager(_ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32) -> Data {
            received.append(data)
            return response
        }
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
        // 受信はフレームの完成を待たないが、応答を書けない接続には[responseTimeout]の2秒期限を適用する
        XCTAssertEqual(SocketManager.responseTimeout, .milliseconds(2000))
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
        return try readResponse(fd: fd, deadline: deadline)
    }

    private func readResponse(fd: Int32, deadline: ContinuousClock.Instant) throws -> Hazkey_ResponseEnvelope {
        let responseHeader = try readData(from: fd, count: 4, deadline: deadline)
        let count = responseHeader.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard count <= 2 * 1024 * 1024 else { throw POSIXError(.EFBIG) }
        return try Hazkey_ResponseEnvelope(serializedBytes: readData(from: fd, count: Int(count), deadline: deadline))
    }

    private func withRunningServer(_ body: (Process, String) throws -> Void) throws {
        try withIsolatedServerEnvironment { _ in
            let runtime = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"])
            try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let config = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            var profile = HazkeyServerConfig.genDefaultConfig()
            profile.zenzaiEnable = false
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
            let startupDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: socketPath), process.isRunning,
                ContinuousClock.now < startupDeadline { usleep(10_000) }
            try body(process, socketPath)
        }
    }

    func testPartialHeaderDoesNotBlockAnotherClientAndExpiresAtTwoSeconds() throws {
        try withRunningServer { process, socketPath in
            let stalled = try connectClient(socketPath)
            defer { close(stalled) }
            let request = Hazkey_RequestEnvelope.with { $0.newComposingText = .init() }
            let body = try request.serializedData()
            var length = UInt32(body.count).bigEndian
            let header = withUnsafeBytes(of: &length) { Data($0) }
            let partialStart = ContinuousClock.now
            try writeData(to: stalled, data: Data(header.prefix(3)), deadline: .now.advanced(by: .seconds(1)))
            let healthy = try connectClient(socketPath)
            defer { close(healthy) }
            let start = ContinuousClock.now
            XCTAssertEqual(try transact(request, fd: healthy).status, .success)
            let elapsed = start.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(1))
            print("Partial-header peer response latency: \(elapsed)")
            XCTAssertTrue(process.isRunning)
            XCTAssertEqual(SocketManager.partialFrameTimeout, .milliseconds(2000))
            var event = pollfd(fd: stalled, events: Int16(POLLIN | POLLHUP), revents: 0)
            XCTAssertEqual(poll(&event, 1, 3500), 1)
            var byte: UInt8 = 0
            XCTAssertEqual(Glibc.read(stalled, &byte, 1), 0)
            let duration = partialStart.duration(to: .now)
            XCTAssertGreaterThanOrEqual(duration, .milliseconds(1900))
            XCTAssertLessThan(duration, .seconds(4))
            XCTAssertEqual(try transact(request, fd: healthy).status, .success)
            XCTAssertTrue(process.isRunning)
        }
    }

    func testTricklingPartialBodyDoesNotExtendItsAbsoluteDeadline() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data()
        manager.delegate = delegate
        var now = ContinuousClock.now
        manager.activityClock = { now }
        let client = try connectClient(path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        try writeData(to: client, data: Data([0, 0, 0, 3, 65]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        now = now.advanced(by: .milliseconds(1999))
        try writeData(to: client, data: Data([66]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        manager.drainBufferedClientData()
        XCTAssertTrue(delegate.disconnected.isEmpty)
        now = now.advanced(by: .milliseconds(1))
        manager.drainBufferedClientData()
        XCTAssertEqual(delegate.disconnected, [server])
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testDispatchCapLetsOtherClientRespondAndDrainsWithoutNewInput() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data("ok".utf8)
        manager.delegate = delegate
        let pipeline = try connectClient(path)
        defer { close(pipeline) }
        manager.handleNewConnection()
        let pipelineServer = try XCTUnwrap(delegate.connected.last)
        let healthy = try connectClient(path)
        defer { close(healthy) }
        manager.handleNewConnection()
        let healthyServer = try XCTUnwrap(delegate.connected.last)
        XCTAssertEqual(SocketManager.maxFramesPerTurn, 16)
        let count = 3 * SocketManager.maxFramesPerTurn
        try writeData(to: pipeline, data: Data(repeating: 0, count: count * 4), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(pipelineServer)
        XCTAssertEqual(delegate.received.count, SocketManager.maxFramesPerTurn)
        try writeData(to: healthy, data: Data([0, 0, 0, 1, 72]), deadline: .now.advanced(by: .seconds(1)))
        let start = ContinuousClock.now
        manager.handleClientData(healthyServer)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        XCTAssertEqual(delegate.received.last, Data("H".utf8))
        XCTAssertEqual(try readData(from: healthy, count: 6, deadline: .now.advanced(by: .seconds(1))),
                       Data([0, 0, 0, 2, 111, 107]))
        for round in 2...3 {
            manager.drainBufferedClientData()
            XCTAssertEqual(delegate.received.count, round * SocketManager.maxFramesPerTurn + 1)
        }
        XCTAssertEqual(try readData(from: pipeline, count: count * 6, deadline: .now.advanced(by: .seconds(1))).count,
                       count * 6)
        XCTAssertTrue(delegate.disconnected.isEmpty)
    }

    func testPartialTailDeadlineStartsBeforeDispatchAndSurvivesBufferConsumption() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data()
        manager.delegate = delegate
        var now = ContinuousClock.now
        manager.activityClock = { now }
        let client = try connectClient(path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        let frames = Data(repeating: 0, count: 3 * SocketManager.maxFramesPerTurn * 4)
        try writeData(to: client, data: frames + Data([0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received.count, SocketManager.maxFramesPerTurn)
        now = now.advanced(by: .milliseconds(1999))
        manager.drainBufferedClientData()
        XCTAssertEqual(delegate.received.count, 2 * SocketManager.maxFramesPerTurn)
        XCTAssertTrue(delegate.disconnected.isEmpty)
        now = now.advanced(by: .milliseconds(1))
        manager.drainBufferedClientData()
        XCTAssertEqual(delegate.disconnected, [server])
        XCTAssertEqual(delegate.received.count, 2 * SocketManager.maxFramesPerTurn)
    }

    func testFollowingPartialFrameGetsNewDeadlineAndReconnectDoesNotInheritIt() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data()
        manager.delegate = delegate
        var now = ContinuousClock.now
        manager.activityClock = { now }
        let client = try connectClient(path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        try writeData(to: client, data: Data([0, 0, 0, 3, 65]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        now = now.advanced(by: .milliseconds(1999))
        try writeData(to: client, data: Data([66, 67, 0, 0, 0, 3, 68]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received, [Data("ABC".utf8)])
        now = now.advanced(by: .milliseconds(1))
        manager.drainBufferedClientData()
        XCTAssertTrue(delegate.disconnected.isEmpty)
        now = now.advanced(by: .milliseconds(1999))
        manager.drainBufferedClientData()
        XCTAssertEqual(delegate.disconnected, [server])
        let next = try connectClient(path)
        defer { close(next) }
        manager.handleNewConnection()
        try writeData(to: next, data: Data([0, 0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(try XCTUnwrap(delegate.connected.last))
        XCTAssertEqual(delegate.received, [Data("ABC".utf8), Data()])
        XCTAssertEqual(manager.connectedClientCount, 1)
    }

    func testPollTimeoutOnlySkipsWaitForCompleteBufferedFrames() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data()
        manager.delegate = delegate
        XCTAssertEqual(manager.pollTimeoutMs, 1000)
        let client = try connectClient(path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        XCTAssertEqual(manager.pollTimeoutMs, 1000)
        let frames = Data(repeating: 0, count: 2 * SocketManager.maxFramesPerTurn * 4)
        try writeData(to: client, data: frames + Data([0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received.count, SocketManager.maxFramesPerTurn)
        XCTAssertEqual(manager.pollTimeoutMs, 0)
        manager.drainBufferedClientData()
        XCTAssertEqual(delegate.received.count, 2 * SocketManager.maxFramesPerTurn)
        XCTAssertEqual(manager.pollTimeoutMs, 1000)
        try writeData(to: client, data: Data([0, 0, 0, 0, 3, 65]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received.count, 2 * SocketManager.maxFramesPerTurn + 1)
        XCTAssertEqual(manager.pollTimeoutMs, 1000)
        try writeData(to: client, data: Data([66, 67]) + frames, deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received[2 * SocketManager.maxFramesPerTurn + 1], Data("ABC".utf8))
        XCTAssertEqual(manager.pollTimeoutMs, 0)
        manager.drainBufferedClientData()
        XCTAssertEqual(manager.pollTimeoutMs, 0)
        manager.drainBufferedClientData()
        XCTAssertEqual(manager.pollTimeoutMs, 1000)
        XCTAssertEqual(delegate.received.count, 4 * SocketManager.maxFramesPerTurn + 2)
        XCTAssertTrue(delegate.disconnected.isEmpty)
    }

    func testMainLoopPipelineDoesNotStarveAnotherClientOrWaitForMoreInput() throws {
        try withRunningServer { process, socketPath in
            let pipeline = try connectClient(socketPath)
            defer { close(pipeline) }
            let healthy = try connectClient(socketPath)
            defer { close(healthy) }
            let request = Hazkey_RequestEnvelope.with { $0.newComposingText = .init() }
            let body = try request.serializedData()
            var length = UInt32(body.count).bigEndian
            let frame = withUnsafeBytes(of: &length) { Data($0) } + body
            var frames = Data()
            let count = 4 * SocketManager.maxFramesPerTurn
            XCTAssertEqual(count, 64)
            for _ in 0..<count { frames.append(frame) }
            let pipelineStart = ContinuousClock.now
            // 全64件に共通の1秒未満の期限を置き、16件を処理するたびに[poll]で待機する不具合を検出する
            let deadline = pipelineStart.advanced(by: .milliseconds(750))
            try writeData(to: pipeline, data: frames, deadline: deadline)
            XCTAssertEqual(try readResponse(fd: pipeline, deadline: deadline).status, .success)
            let start = ContinuousClock.now
            XCTAssertEqual(try transact(request, fd: healthy).status, .success)
            let peerElapsed = start.duration(to: .now)
            XCTAssertLessThan(peerElapsed, .seconds(1))
            for _ in 1..<count {
                let response = try readResponse(fd: pipeline, deadline: deadline)
                XCTAssertEqual(response.status, .success)
            }
            let pipelineElapsed = pipelineStart.duration(to: .now)
            XCTAssertLessThan(pipelineElapsed, .milliseconds(750))
            print("64-frame pipeline latency: \(pipelineElapsed); peer response latency: \(peerElapsed)")
            XCTAssertTrue(process.isRunning)
        }
    }

    func testPartialBodyAndPipelinedFramesDispatchOnlyCompleteRequests() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SocketManager(socketPath: root.appendingPathComponent("test.sock").path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data("ok".utf8)
        manager.delegate = delegate
        let client = try connectClient(root.appendingPathComponent("test.sock").path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        try writeData(to: client, data: Data([0, 0, 0, 3, 65]), deadline: .now.advanced(by: .seconds(1)))
        let start = ContinuousClock.now
        manager.handleClientData(server)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        XCTAssertTrue(delegate.received.isEmpty)
        XCTAssertTrue(delegate.disconnected.isEmpty)
        try writeData(to: client, data: Data([66, 67, 0, 0, 0, 1, 68, 0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received, [Data("ABC".utf8), Data("D".utf8)])
        XCTAssertEqual(try readData(from: client, count: 12, deadline: .now.advanced(by: .seconds(1))),
                       Data([0, 0, 0, 2, 111, 107, 0, 0, 0, 2, 111, 107]))
        try writeData(to: client, data: Data([0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.received.last, Data())
        XCTAssertEqual(delegate.received.count, 3)
    }

    func testOversizedHeaderDisconnectsAndReusedConnectionHasNoBufferedPrefix() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data()
        manager.delegate = delegate
        let client = try connectClient(path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        var length = UInt32(SocketManager.maxMessageSize + 1).bigEndian
        try writeData(to: client, data: withUnsafeBytes(of: &length) { Data($0) },
                      deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        XCTAssertEqual(delegate.disconnected, [server])
        XCTAssertTrue(delegate.received.isEmpty)
        XCTAssertEqual(manager.connectedClientCount, 0)
        let next = try connectClient(path)
        defer { close(next) }
        manager.handleNewConnection()
        try writeData(to: next, data: Data([0, 0, 0, 0]), deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(try XCTUnwrap(delegate.connected.last))
        XCTAssertEqual(delegate.received, [Data()])
        XCTAssertEqual(try readData(from: next, count: 4, deadline: .now.advanced(by: .seconds(1))), Data([0, 0, 0, 0]))
        XCTAssertEqual(manager.connectedClientCount, 1)
    }

    func testMaximumSizedFrameFitsBoundedBufferAcrossReadRounds() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test.sock").path
        let manager = SocketManager(socketPath: path)
        try manager.setupSocket()
        defer { manager.closeSocket() }
        let delegate = Delegate()
        delegate.response = Data()
        manager.delegate = delegate
        let client = try connectClient(path)
        defer { close(client) }
        manager.handleNewConnection()
        let server = try XCTUnwrap(delegate.connected.last)
        var length = UInt32(SocketManager.maxMessageSize).bigEndian
        try writeData(to: client, data: withUnsafeBytes(of: &length) { Data($0) },
                      deadline: .now.advanced(by: .seconds(1)))
        manager.handleClientData(server)
        let chunk = Data(repeating: 65, count: 64 * 1024)
        for _ in 0..<16 {
            try writeData(to: client, data: chunk, deadline: .now.advanced(by: .seconds(1)))
            manager.handleClientData(server)
        }
        XCTAssertEqual(delegate.received, [Data(repeating: 65, count: SocketManager.maxMessageSize)])
        XCTAssertTrue(delegate.disconnected.isEmpty)
        XCTAssertEqual(SocketManager.maxReceiveBufferSize, SocketManager.maxMessageSize + 4)
        XCTAssertEqual(try readData(from: client, count: 4, deadline: .now.advanced(by: .seconds(1))), Data([0, 0, 0, 0]))
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

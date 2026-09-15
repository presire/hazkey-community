import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// Connection-cap tests for multi-client support.
///
/// Drives the REAL accept path (`handleNewConnection`) directly — no poll
/// loop, no threads — by opening client UNIX sockets and accepting them one
/// by one. The first `maxClientCount` connections are accepted; the next one
/// is rejected (server closes it) without disturbing the accepted set.
final class SocketManagerClientLimitTests: XCTestCase {
    private final class CountingDelegate: SocketManagerDelegate {
        var connected: [Int32] = []
        var disconnected: [Int32] = []
        func socketManager(
            _ manager: SocketManager, didReceiveData data: Data, from clientFd: Int32
        ) -> Data { Data() }
        func socketManager(_ manager: SocketManager, clientDidConnect clientFd: Int32) {
            connected.append(clientFd)
        }
        func socketManager(_ manager: SocketManager, clientDidDisconnect clientFd: Int32) {
            disconnected.append(clientFd)
        }
    }

    private var temporaryDirectory: URL?
    private var manager: SocketManager?
    private var clientFds: [Int32] = []

    override func tearDown() {
        for fd in clientFds {
            close(fd)
        }
        clientFds = []
        manager?.closeSocket()
        manager = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    private func connectClient(to socketPath: String) -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        XCTAssertNotEqual(fd, -1, "client socket() failed")
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy the path bytes with explicit NUL termination (same pattern as
        // SocketManager.setupSocket: strncpy straight into sun_path).
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                guard let base = raw.baseAddress else { return }
                _ = strncpy(
                    base.assumingMemoryBound(to: CChar.self), src, pathLen - 1)
            }
        }
        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrSize)
            }
        }
        XCTAssertEqual(result, 0, "client connect() failed: errno \(errno)")
        clientFds.append(fd)
        return fd
    }

    func testAcceptsUpToMaxClientCountThenRejects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-client-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectory = root
        let socketPath = root.appendingPathComponent("test.sock").path

        let manager = SocketManager(socketPath: socketPath)
        self.manager = manager
        try manager.setupSocket()
        // `delegate` is weak: the local keeps the mock alive for the test.
        let delegate = CountingDelegate()
        manager.delegate = delegate

        // Accept exactly maxClientCount connections: none is evicted.
        for _ in 0..<SocketManager.maxClientCount {
            _ = connectClient(to: socketPath)
            manager.handleNewConnection()
        }
        XCTAssertEqual(delegate.connected.count, SocketManager.maxClientCount)
        XCTAssertEqual(manager.connectedClientCount, SocketManager.maxClientCount)

        // One more connection is rejected: the delegate sees no new connect
        // and the server side closes the socket, so the client's read hits EOF.
        let extraFd = connectClient(to: socketPath)
        manager.handleNewConnection()
        XCTAssertEqual(delegate.connected.count, SocketManager.maxClientCount)
        XCTAssertEqual(manager.connectedClientCount, SocketManager.maxClientCount)

        var byte: UInt8 = 0
        let readResult = read(extraFd, &byte, 1)
        XCTAssertEqual(readResult, 0, "expected EOF on rejected connection")
    }
}

import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// The server loop is single-threaded, so a stalled client must not block the
/// request/response path forever. `readData`/`writeData` wait for socket
/// progress with a bounded timeout instead of busy-waiting indefinitely.
final class SocketIOTimeoutTests: XCTestCase {
    private enum SocketIOTestError: Error {
        case socketPairFailed(Int32)
    }

    private func makeSocketPair() throws -> (server: Int32, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0 else {
            throw SocketIOTestError.socketPairFailed(errno)
        }
        return (fds[0], fds[1])
    }

    /// The server end of a real connection is non-blocking (see
    /// `SocketManager.handleNewConnection`), which is what makes the bounded
    /// wait reachable at all.
    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// A client that sends a partial frame (or nothing) must be abandoned
    /// after the timeout rather than pinning the loop.
    func testReadTimesOutOnStalledClient() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.server)
            close(pair.peer)
        }
        setNonBlocking(pair.server)

        XCTAssertThrowsError(try readData(from: pair.server, count: 4, timeoutMs: 100)) { error in
            guard case SocketError.ioTimeout = error else {
                return XCTFail("expected ioTimeout, got \(error)")
            }
        }
    }

    /// Normal path is unchanged: a complete frame is read within the timeout.
    func testReadCompletesForNormalMessage() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.server)
            close(pair.peer)
        }
        setNonBlocking(pair.server)

        let body = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01])
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        let written = frame.withUnsafeBytes { write(pair.peer, $0.baseAddress, frame.count) }
        XCTAssertEqual(written, frame.count)

        let header = try readData(from: pair.server, count: 4, timeoutMs: 1000)
        let readLen = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(readLen, UInt32(body.count))
        let received = try readData(from: pair.server, count: Int(readLen), timeoutMs: 1000)
        XCTAssertEqual(received, body)
    }

    /// A peer that never drains its receive buffer must not block the writer
    /// forever either.
    func testWriteTimesOutWhenPeerDoesNotDrain() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.server)
            close(pair.peer)
        }
        setNonBlocking(pair.server)

        // Shrink both buffers so a modest payload reliably fills them.
        var bufferSize: Int32 = 4096
        _ = setsockopt(
            pair.server, SOL_SOCKET, SO_SNDBUF, &bufferSize,
            socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(
            pair.peer, SOL_SOCKET, SO_RCVBUF, &bufferSize,
            socklen_t(MemoryLayout<Int32>.size))

        let payload = Data(count: 1024 * 1024)
        XCTAssertThrowsError(try writeData(to: pair.server, data: payload, timeoutMs: 100)) { error in
            guard case SocketError.ioTimeout = error else {
                return XCTFail("expected ioTimeout, got \(error)")
            }
        }
    }
}

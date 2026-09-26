import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// サーバループは単一スレッドのため、停滞したクライアントがリクエスト/レスポンス経路を永久にブロックしてはならない
/// "readData" / "writeData"は、無期限のビジーウェイトではなく、上限付きタイムアウトでソケットの進行を待つ
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

    /// 実際の接続におけるサーバ側は非ブロッキングである ("SocketManager.handleNewConnection"を参照)
    /// これにより、上限付き待機の経路に到達できる
    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// 部分フレームだけを送る、または何も送らないクライアントは、ループを占有せずタイムアウト後に切断する必要がある
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

    /// 正常経路は不変であり、完全なフレームはタイムアウト内に読み取る
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

    /// 受信バッファを読み出さないピアも、書き込み側を永久にブロックしてはならない
    func testWriteTimesOutWhenPeerDoesNotDrain() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.server)
            close(pair.peer)
        }
        setNonBlocking(pair.server)

        // 小さなペイロードでも確実に埋まるよう、両方のバッファを縮小する
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

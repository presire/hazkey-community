import Foundation

enum SocketError: Error {
    case pollFailed(Int32)
    case clientDisconnected(String)
    case readFailed(String, Int32)
    case incompleteRead(String)
    case messageTooLarge(UInt32)
    case writeFailed(String, Int32)
    case incompleteWrite(String)
    case ioTimeout(String)
}

/// readData / writeDataが単一クライアントの進捗を待つ最大時間 (ミリ秒)
/// サーバループはシングルスレッドなので、1つの接続を無制限に待つと他の全クライアントが止まってしまう
/// この値は、クライアント側の読み込みタイムアウト (HazkeyServerConnector::transact) に合わせて選択しており、
/// レスポンス待ち中のクライアントが早期に打ち切られることはない
let socketIOProgressTimeoutMs: Int32 = 10_000

/// fdがeventsに対して準備完了になるまでtimeoutMsを上限に待つ
/// fdが準備できれば正常に返る。(呼び出し元のread() / write()がその後EOF / EAGAINを正確に検知する)
/// 準備できなければ、SocketError.ioTimeoutを投げる
private func waitForSocketReady(fd: Int32, events: Int16, timeoutMs: Int32) throws {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    while true {
        let res = poll(&pfd, 1, timeoutMs)
        if res < 0 {
            if errno == EINTR { continue }
            throw SocketError.pollFailed(errno)
        }
        if res == 0 {
            throw SocketError.ioTimeout("no socket progress within \(timeoutMs) ms")
        }
        return
    }
}

func readData(from fd: Int32, count: Int, timeoutMs: Int32 = socketIOProgressTimeoutMs) throws -> Data {
    var buffer = Data(count: count)
    var bytesRead = 0

    try buffer.withUnsafeMutableBytes { bufPtr in
        let baseAddress = bufPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)

        while bytesRead < count {
            let n = read(fd, baseAddress.advanced(by: bytesRead), count - bytesRead)

            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForSocketReady(fd: fd, events: Int16(POLLIN), timeoutMs: timeoutMs)
                    continue
                }
                throw SocketError.readFailed("Read failed", errno)
            }
            if n == 0 {
                throw SocketError.clientDisconnected("Client disconnected while reading")
            }
            bytesRead += n
        }
    }

    if bytesRead < count {
        throw SocketError.incompleteRead("Failed to read all bytes")
    }

    return buffer
}

func writeData(to fd: Int32, data: Data, timeoutMs: Int32 = socketIOProgressTimeoutMs) throws {
    var bytesWritten = 0

    try data.withUnsafeBytes { bufPtr in
        let baseAddress = bufPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)

        while bytesWritten < data.count {
            let n = write(fd, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)

            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForSocketReady(fd: fd, events: Int16(POLLOUT), timeoutMs: timeoutMs)
                    continue
                }
                throw SocketError.writeFailed("Write failed", errno)
            }
            if n == 0 {
                throw SocketError.clientDisconnected("Client disconnected while writing")
            }
            bytesWritten += n
        }
    }

    if bytesWritten < data.count {
        throw SocketError.incompleteWrite("Failed to write all bytes")
    }
}

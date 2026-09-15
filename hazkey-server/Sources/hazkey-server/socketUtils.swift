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

/// Maximum time (milliseconds) `readData`/`writeData` wait for progress on a
/// single client before giving up. The server loop is single-threaded, so an
/// unbounded wait on one connection would stall every other client. Chosen to
/// match the client-side read timeout (`HazkeyServerConnector::transact`),
/// so a client still waiting for its response is never aborted early.
let socketIOProgressTimeoutMs: Int32 = 10_000

/// Waits until `fd` is ready for `events`, up to `timeoutMs`. Returns
/// normally when the fd is ready (the caller's read()/write() then reports
/// EOF/EAGAIN precisely); throws `SocketError.ioTimeout` when it is not.
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

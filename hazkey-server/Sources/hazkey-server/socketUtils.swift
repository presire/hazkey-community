import Foundation

/// ソケット入出力の失敗を表すエラー
///
/// pollの失敗と相手側の切断と読み書きの失敗と期限切れを区別する
enum SocketError: Error {
    /// pollが失敗したときのerrnoを保持する
    case pollFailed(Int32)
    /// 相手側が接続を閉じたことを示す
    case clientDisconnected(String)
    /// 読み込み呼び出しが失敗したことを示す
    case readFailed(String, Int32)
    /// 要求バイト数を読み切れなかったことを示す
    case incompleteRead(String)
    /// メッセージが上限サイズを超えたことを示す
    case messageTooLarge(UInt32)
    /// 書き込み呼び出しが失敗したことを示す
    case writeFailed(String, Int32)
    /// 要求バイト数を書き切れなかったことを示す
    case incompleteWrite(String)
    /// 入出力全体の期限が切れたことを示す
    case ioTimeout(String)
}

/// readData/writeDataの入出力全体に使う最大時間(ミリ秒)
///
/// サーバループはシングルスレッドなので1つの接続を無制限に待つと他の全クライアントが止まってしまう
///
/// この値はクライアント側の読み込みタイムアウト (HazkeyServerConnector::transact) に合わせて選んでおりレスポンス待ち中のクライアントを早期に打ち切らない
let socketIOProgressTimeoutMs: Int32 = 10_000

/// ファイル記述子が読み書き可能になるまでpollで待つ
///
/// [EINTR]で中断した場合は再試行する
///
/// 期限内に準備できなかった場合はSocketError.ioTimeoutを投げる
///
/// poll自体が失敗した場合はSocketError.pollFailedを投げる
///
/// 準備できた場合は正常に戻り呼び出し元のread() / write()がEOF / EAGAINを正確に検知する
///
/// - Parameters:
///   - fd: 待ち対象のファイル記述子
///   - events: pollに渡す待ちイベント ([POLLIN]または[POLLOUT])
///   - deadline: 入出力全体で共有する絶対期限
/// - Throws: 期限切れやpoll失敗のとき対応するSocketErrorを投げる
private func waitForSocketReady(fd: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    while true {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw SocketError.ioTimeout("socket deadline expired") }
        let parts = remaining.components
        let milliseconds = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000 + 1
        let res = poll(&pfd, 1, Int32(clamping: milliseconds))
        if res < 0 {
            if errno == EINTR { continue }
            throw SocketError.pollFailed(errno)
        }
        if res == 0 {
            throw SocketError.ioTimeout("socket deadline expired")
        }
        return
    }
}

/// 指定バイト数を正確に読み込む
///
/// 読み込みが[EAGAIN] / [EWOULDBLOCK]で返った時は、waitForSocketReadyで[POLLIN]の準備を待って再試行する
///
/// 0バイトで返ったときは相手側が閉じたものとして、SocketError.clientDisconnectedを投げる
///
/// 要求数に満たないまま終わった時は、SocketError.incompleteReadを投げる
///
/// - Parameters:
///   - fd: 読み込み元のファイル記述子
///   - count: 読み込むバイト数
///   - timeoutMs: 進捗を待つ上限時間 (ミリ秒)
/// - Returns: 読み込んだデータを返す
/// - Throws: 失敗や切断や期限切れの時、対応するSocketErrorを投げる
/// - Note: 既定ではsocketIOProgressTimeoutMsを使用する
func readData(from fd: Int32, count: Int, timeoutMs: Int32 = socketIOProgressTimeoutMs) throws -> Data {
    try readData(from: fd, count: count, deadline: .now.advanced(by: .milliseconds(timeoutMs)))
}

/// ヘッダと本体で同じ絶対期限を共有して読み込む
func readData(from fd: Int32, count: Int, deadline: ContinuousClock.Instant) throws -> Data {
    guard count >= 0 else { throw SocketError.incompleteRead("Negative byte count") }
    guard count > 0 else { return Data() }
    var buffer = Data(count: count)
    var bytesRead = 0

    try buffer.withUnsafeMutableBytes { bufPtr in
        guard let baseAddress = bufPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw SocketError.incompleteRead("Missing read buffer")
        }

        while bytesRead < count {
            guard ContinuousClock.now < deadline else {
                throw SocketError.ioTimeout("request deadline expired")
            }
            let n = read(fd, baseAddress.advanced(by: bytesRead), count - bytesRead)

            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForSocketReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
                    continue
                }
                if errno == EINTR { continue }
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

/// 全バイトを書き込む
///
/// 書き込みが[EAGAIN] / [EWOULDBLOCK]で返った時はwaitForSocketReadyで[POLLOUT]の準備を待って再試行する
///
/// 0バイトで返ったときは相手側が閉じたものとしてSocketError.clientDisconnectedを投げる
///
/// 要求数に満たないまま終わった時は、SocketError.incompleteWriteを投げる
///
/// - Parameters:
///   - fd: 書き込み先のファイル記述子
///   - data: 書き込むデータ
///   - timeoutMs: 進捗を待つ上限時間(ミリ秒)
/// - Throws: 失敗や切断や期限切れのとき対応するSocketErrorを投げる
/// - Note: 既定ではsocketIOProgressTimeoutMsを使用する
func writeData(to fd: Int32, data: Data, timeoutMs: Int32 = socketIOProgressTimeoutMs) throws {
    try writeData(to: fd, data: data, deadline: .now.advanced(by: .milliseconds(timeoutMs)))
}

/// レスポンスのヘッダと本体で同じ絶対期限を共有して書き込む
func writeData(to fd: Int32, data: Data, deadline: ContinuousClock.Instant) throws {
    guard !data.isEmpty else { return }
    var bytesWritten = 0

    try data.withUnsafeBytes { bufPtr in
        guard let baseAddress = bufPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw SocketError.incompleteWrite("Missing write buffer")
        }

        while bytesWritten < data.count {
            guard ContinuousClock.now < deadline else {
                throw SocketError.ioTimeout("response deadline expired")
            }
            let n = write(fd, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)

            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForSocketReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                if errno == EINTR { continue }
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

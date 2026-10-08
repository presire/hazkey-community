import Foundation
import Glibc

/// FIFO等の非正規ファイルを拒否し、検証した同じfdから上限未満の内容だけを読む
///
/// followFinalSymlinkがfalseの場合は最終成分のリンクも拒否する
///
/// trueの場合はリンク先を開くが、正規ファイルとサイズの検証は開いたfdに対して行う
/// (dotfiles管理等でリンクにしたユーザ辞書・設定を、従来どおり読めるようにする)
func withValidatedFileData<T>(
    at url: URL, limit: Int, followFinalSymlink: Bool = false, _ body: (Int32, Data) throws -> T
) throws -> T {
    guard limit > 0, !url.path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followFinalSymlink ? 0 : O_NOFOLLOW))
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EINVAL) }
    guard info.st_size >= 0, info.st_size < limit else { throw POSIXError(.EFBIG) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Glibc.read(fd, &buffer, min(buffer.count, limit - data.count))
        if count < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 { break }
        data.append(contentsOf: buffer[0..<count])
        guard data.count < limit else { throw POSIXError(.EFBIG) }
    }
    return try body(fd, data)
}

func readValidatedFileData(at url: URL, limit: Int, followFinalSymlink: Bool = false) throws -> Data {
    try withValidatedFileData(at: url, limit: limit, followFinalSymlink: followFinalSymlink) { _, data in data }
}

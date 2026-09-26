import Foundation
import Glibc
import XCTest

/// Shared isolated temporary root for tests that spawn `hazkey-community-server`.
///
/// The server derives its socket path as
/// `<XDG_RUNTIME_DIR>/hazkey-community-server.<uid>.sock`, and AF_UNIX `sun_path` accepts at
/// most 107 usable bytes. A long `<prefix>-<UUID>` directory name can push the socket path over
/// that limit; `bind` then silently truncates it while `chmod` uses the untruncated path and
/// fails, so the spawned server exits and the test times out. `make()` keeps the root short and
/// fails fast if the canonical socket path still would not fit.
enum TestTempRoot {
    /// AF_UNIX `sun_path` is `char[108]`, so the usable path length is 107 bytes (plus NUL).
    static let maxSocketPathBytes = 107

    /// Creates a unique, short temporary directory such as `/tmp/hk1a2b3c4d5e`.
    static func make() throws -> URL {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        requireFitsInSunPath(canonicalSocketPath(under: url))
        return url
    }

    /// The socket path the server will create for the conventional `runtime/` layout.
    static func canonicalSocketPath(under root: URL, uid: uid_t = getuid()) -> String {
        root.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hazkey-community-server.\(uid).sock").path
    }

    /// Fails the test immediately (instead of a 120s server timeout) when the path is too long.
    static func requireFitsInSunPath(
        _ socketPath: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard socketPath.utf8.count <= maxSocketPathBytes else {
            XCTFail(
                "AF_UNIX socket path is \(socketPath.utf8.count) bytes, exceeding the "
                    + "\(maxSocketPathBytes)-byte sun_path limit: \(socketPath)",
                file: file, line: line)
            return
        }
    }
}

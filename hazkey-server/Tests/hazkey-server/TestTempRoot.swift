import Foundation
import Glibc
import XCTest

/// "hazkey-community-server"を起動するテストで共有する隔離済みの一時ルート
///
/// サーバはソケットパスを"<XDG_RUNTIME_DIR>/hazkey-community-server.<uid>.sock"として導出し、
/// AF_UNIX "sun_path"は、最大107バイトまで使用できる
///
/// 長い"<prefix>-<UUID>"形式のディレクトリ名ではソケットパスがこの上限を超えることがある
/// その場合、"bind"はパスを暗黙に切り詰める一方で、"chmod"は切り詰め前のパスを使用して失敗するため、起動したサーバが終了してテストがタイムアウトする
/// "make()"はルートを短く保ち、正規のソケットパスがなお収まらない場合は速やかに失敗させる
enum TestTempRoot {
    /// AF_UNIX "sun_path"は"char[108]"のため、使用可能なパス長は107バイトである
    /// NULは別に必要
    static let maxSocketPathBytes = 107

    /// "/tmp/hk1a2b3c4d5e"のような、一意かつ短い一時ディレクトリを作成する
    static func make() throws -> URL {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        requireFitsInSunPath(canonicalSocketPath(under: url))
        return url
    }

    /// 標準的な"runtime/"レイアウトでサーバが作成するソケットパス
    static func canonicalSocketPath(under root: URL, uid: uid_t = getuid()) -> String {
        root.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hazkey-community-server.\(uid).sock").path
    }

    /// パスが長すぎる場合、120秒のサーバタイムアウトを待たずにテストを直ちに失敗させる
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

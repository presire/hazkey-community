import Foundation

/// テストが起動する"hazkey-community-server"実行ファイルを解決する
///
/// 従来のCMakeレイアウトに合わせ、SwiftPMのデバッグビルドよりリリースビルド成果物を優先する
/// Swift 6.4はSwift Buildを使用し、その成果物は"out/Products/<Config>-<os>-<arch>/"配下に置かれ、"<config>"の簡易シンボリックリンクも作られる
/// そのため、シンボリックリンク経由と明示的な成果物パスの両方を探索する
enum TestServerBinary {
    /// 明示的な"HAZKEY_SERVER_TEST_BIN"は、パスが存在しない場合でも常に優先する
    /// 呼び出し元が意図的に失敗経路を検証する場合があるため
    static func resolve(packageRoot: URL) -> URL? {
        if let override = ProcessInfo.processInfo.environment["HAZKEY_SERVER_TEST_BIN"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        for path in candidatePaths(packageRoot: packageRoot)
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 実行ファイルの候補パス
    /// リリース版、デバッグ版の順に並べる
    /// 呼び出し元が失敗メッセージに含められるよう、探索順で返す
    static func candidatePaths(packageRoot: URL) -> [String] {
        let repositoryRoot = packageRoot.deletingLastPathComponent()
        let scratch = repositoryRoot
            .appendingPathComponent("build/hazkey-server/swift-build", isDirectory: true)
        var candidates = [
            // 簡易シンボリックリンク
            // Swift Buildと標準のSwiftPMに存在する
            scratch.appendingPathComponent("release/hazkey-server").path
        ]
        for config in ["Release-linux-x86_64", "Release-linux-aarch64"] {
            candidates.append(
                scratch.appendingPathComponent("out/Products/\(config)/hazkey-server").path)
        }
        for triple in ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"] {
            candidates.append(
                scratch.appendingPathComponent("\(triple)/release/hazkey-server").path)
        }
        candidates.append(packageRoot.appendingPathComponent(".build/debug/hazkey-server").path)
        for config in ["Debug-linux-x86_64", "Debug-linux-aarch64"] {
            candidates.append(
                packageRoot.appendingPathComponent(".build/out/Products/\(config)/hazkey-server")
                    .path)
        }
        return candidates
    }
}

import Foundation

/// Resolves the `hazkey-community-server` executable that tests spawn.
///
/// Release build products are preferred over SwiftPM debug builds, matching the historical
/// CMake layout. Swift 6.4 uses Swift Build, whose products live under
/// `out/Products/<Config>-<os>-<arch>/` with a `<config>` convenience symlink, so both the
/// symlinked and the explicit product paths are probed.
enum TestServerBinary {
    /// Explicit `HAZKEY_SERVER_TEST_BIN` always wins, even when it does not exist (callers may
    /// intentionally exercise the failure path).
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

    /// Candidate executable paths, release first, then debug. Returned in probe order so callers
    /// can include them in failure messages.
    static func candidatePaths(packageRoot: URL) -> [String] {
        let repositoryRoot = packageRoot.deletingLastPathComponent()
        let scratch = repositoryRoot
            .appendingPathComponent("build/hazkey-server/swift-build", isDirectory: true)
        var candidates = [
            // Convenience symlink: present in Swift Build and native SwiftPM.
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

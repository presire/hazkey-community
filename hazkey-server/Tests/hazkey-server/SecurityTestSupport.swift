import Foundation
import Glibc

func withIsolatedServerEnvironment<T>(_ body: (URL) throws -> T) throws -> T {
    let root = try TestTempRoot.make()
    let keys = ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "HAZKEY_ZENZAI_MODEL", "HAZKEY_DICTIONARY"]
    let saved = keys.map { ProcessInfo.processInfo.environment[$0] }
    defer {
        for (key, value) in zip(keys, saved) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: root)
    }
    for key in keys {
        let path = root.appendingPathComponent(key == "XDG_RUNTIME_DIR" ? "runtime" : key).path
        setenv(key, path, 1)
    }
    let dictionary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("azooKey_dictionary_storage/Dictionary")
    setenv("HAZKEY_DICTIONARY", dictionary.path, 1)
    return try body(root)
}

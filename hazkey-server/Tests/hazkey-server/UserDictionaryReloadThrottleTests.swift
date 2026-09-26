import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// ユーザ辞書の再読込スロットル
///
/// 候補生成は毎打鍵で走るため、"UserDictionary.reloadIfNeeded()"が毎回statすると、ホットパス上で稀にOSレベルのブロックを踏む
/// "reloadThrottleInterval" (1秒) 以内の通常呼び出しは、ファイルシステムに触れずfalseを返し、
/// 設定適用時は、"force: true"でスロットルを迂回して編集を取り込む、という契約を固定する
final class UserDictionaryReloadThrottleTests: XCTestCase {
    /// "XDG_CONFIG_HOME" / "XDG_STATE_HOME"を一時ディレクトリへ向けて実行する
    /// 元の値は終了時に復元する
    private func withTemporaryXDG<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-userdict-throttle-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let originalConfigDirectory = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let originalStateDirectory = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", configDirectory.path, 1)
        setenv("XDG_STATE_HOME", stateDirectory.path, 1)
        defer {
            if let originalConfigDirectory {
                setenv("XDG_CONFIG_HOME", originalConfigDirectory, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            if let originalStateDirectory {
                setenv("XDG_STATE_HOME", originalStateDirectory, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        return try body(root)
    }

    /// "$XDG_CONFIG_HOME/hazkey-community/user_dictionary.tsv"へ内容を書き込む
    /// "modificationDate"を渡すとmtimeを明示的に固定する (スロットル判定をsleepに頼らず決定的にするため)
    @discardableResult
    private func writeUserDictionary(
        _ contents: String,
        root: URL,
        modificationDate: Date? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("hazkey-community", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("user_dictionary.tsv", isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        return url
    }

    /// (a) 新規インスタンスの初回呼び出しは、事前に書かれた辞書ファイルを検出してtrueを返し、エントリを読み込む
    ///     (スロットルはnilのため適用されない)
    func testFirstCallOnFreshInstanceLoadsPrewrittenFile() throws {
        try withTemporaryXDG { root in
            try writeUserDictionary("はし\t橋\n", root: root)

            let dictionary = UserDictionary()
            XCTAssertTrue(dictionary.reloadIfNeeded())
            XCTAssertEqual(dictionary.count, 1)
        }
    }

    /// (b) スロットル間隔内の2回目呼び出しは、ファイル内容とmtimeが変わっていても再statせずfalseを返し、キャッシュ済みエントリを保持する
    func testSecondCallWithinThrottleIntervalDoesNotRestat() throws {
        try withTemporaryXDG { root in
            try writeUserDictionary("はし\t橋\n", root: root)
            let dictionary = UserDictionary()
            XCTAssertTrue(dictionary.reloadIfNeeded())
            XCTAssertEqual(dictionary.count, 1)

            // mtimeを明示的に変更して書く (内容も増える)。
            try writeUserDictionary(
                "はし\t橋\nねこ\t猫\n", root: root,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000))

            XCTAssertFalse(dictionary.reloadIfNeeded())
            XCTAssertEqual(dictionary.count, 1)
        }
    }

    /// (c) "force: true"はスロットルを迂回し、間隔内でも変更を検出してtrueを返す
    func testForceReloadBypassesThrottleAndDetectsChange() throws {
        try withTemporaryXDG { root in
            try writeUserDictionary("はし\t橋\n", root: root)
            let dictionary = UserDictionary()
            XCTAssertTrue(dictionary.reloadIfNeeded())
            XCTAssertEqual(dictionary.count, 1)

            try writeUserDictionary(
                "はし\t橋\nねこ\t猫\n", root: root,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertFalse(dictionary.reloadIfNeeded())
            XCTAssertEqual(dictionary.count, 1)

            XCTAssertTrue(dictionary.reloadIfNeeded(force: true))
            XCTAssertEqual(dictionary.count, 2)
        }
    }
}

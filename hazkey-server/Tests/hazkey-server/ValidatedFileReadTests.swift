import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class ValidatedFileReadTests: XCTestCase {
    private func seedDictionary() throws -> UserDictionary {
        let file = UserDictionary.defaultPath()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("よみ\t以前の語\n".utf8).write(to: file)
        let dictionary = UserDictionary()
        XCTAssertTrue(dictionary.reloadIfNeeded(force: true))
        XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "以前の語")
        return dictionary
    }

    func testFIFODictionaryDoesNotHangAndKeepsLastGoodEntries() throws {
        try withIsolatedServerEnvironment { _ in
            let dictionary = try seedDictionary()
            let path = UserDictionary.defaultPath().path
            XCTAssertEqual(unlink(path), 0)
            XCTAssertEqual(mkfifo(path, 0o600), 0)
            let watchdog = DispatchWorkItem {
                let fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                if fd >= 0 { close(fd) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: watchdog)
            defer { watchdog.cancel() }
            let start = ContinuousClock.now
            XCTAssertFalse(dictionary.reloadIfNeeded(force: true))
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
            XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "以前の語")
        }
    }

    func testOversizedDictionaryIsRejectedAndKeepsLastGoodEntries() throws {
        try withIsolatedServerEnvironment { _ in
            let dictionary = try seedDictionary()
            let path = UserDictionary.defaultPath().path
            let fd = open(path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { return XCTFail("open failed") }
            defer { close(fd) }
            XCTAssertEqual(ftruncate(fd, off_t(UserDictionary.fileSizeLimit)), 0)
            XCTAssertFalse(dictionary.reloadIfNeeded(force: true))
            XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "以前の語")
        }
    }

    func testDictionarySymlinkFollowsRegularTargetsRejectsFIFOAndAcceptsParentSymlink() throws {
        try withIsolatedServerEnvironment { root in
            let dictionary = try seedDictionary()
            let file = UserDictionary.defaultPath()
            let fifo = root.appendingPathComponent("target.fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertEqual(unlink(file.path), 0)
            XCTAssertEqual(symlink(fifo.path, file.path), 0)
            let start = ContinuousClock.now
            XCTAssertFalse(dictionary.reloadIfNeeded(force: true))
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
            XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "以前の語")
            XCTAssertEqual(unlink(file.path), 0)

            // dotfiles管理のリンクと、リンクを保つGUIの保存 (リンク先だけが更新される) に追従する
            let target = root.appendingPathComponent("target.tsv")
            try Data("よみ\tリンクの語\n".utf8).write(to: target)
            XCTAssertEqual(symlink(target.path, file.path), 0)
            XCTAssertTrue(dictionary.reloadIfNeeded(force: true))
            XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "リンクの語")
            try Data("よみ\t更新後のリンクの語\n".utf8).write(to: target)
            var times = [
                timespec(tv_sec: 1_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000, tv_nsec: 0),
            ]
            XCTAssertEqual(utimensat(AT_FDCWD, target.path, &times, 0), 0)
            XCTAssertTrue(dictionary.reloadIfNeeded(force: true))
            XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "更新後のリンクの語")
            XCTAssertEqual(unlink(file.path), 0)
            try Data("よみ\t親リンクの語\n".utf8).write(to: file)
            let configHome = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
            let parentLink = root.appendingPathComponent("config-link")
            XCTAssertEqual(symlink(configHome, parentLink.path), 0)
            setenv("XDG_CONFIG_HOME", parentLink.path, 1)
            XCTAssertTrue(dictionary.reloadIfNeeded(force: true))
            XCTAssertEqual(dictionary.exactMatches(hiragana: "よみ").first?.word, "親リンクの語")
        }
    }

    func testConfigAndJournalRejectFIFOAndSizeButFollowFinalSymlinkToRegularFile() throws {
        try withIsolatedServerEnvironment { root in
            let config = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let journal = HazkeyServerConfig.configJournalURL(for: config)
            for file in [config, journal] {
                XCTAssertEqual(mkfifo(file.path, 0o600), 0)
                XCTAssertThrowsError(try readValidatedFileData(at: file, limit: HazkeyServerConfig.configFileSizeLimit))
                XCTAssertEqual(unlink(file.path), 0)
                let fd = open(file.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return XCTFail("open failed") }
                XCTAssertEqual(ftruncate(fd, off_t(HazkeyServerConfig.configFileSizeLimit)), 0)
                close(fd)
                XCTAssertThrowsError(try readValidatedFileData(at: file, limit: HazkeyServerConfig.configFileSizeLimit))
                XCTAssertEqual(unlink(file.path), 0)
                let target = root.appendingPathComponent("valid.json")
                try Data(#"[{"profileName":"Link"}]"#.utf8).write(to: target)
                XCTAssertEqual(symlink(target.path, file.path), 0)
                XCTAssertThrowsError(try readValidatedFileData(at: file, limit: HazkeyServerConfig.configFileSizeLimit))
                XCTAssertNoThrow(try readValidatedFileData(
                    at: file, limit: HazkeyServerConfig.configFileSizeLimit, followFinalSymlink: true))
                XCTAssertEqual(unlink(file.path), 0)
                let fifoTarget = root.appendingPathComponent("target.fifo")
                XCTAssertEqual(mkfifo(fifoTarget.path, 0o600), 0)
                XCTAssertEqual(symlink(fifoTarget.path, file.path), 0)
                XCTAssertThrowsError(try readValidatedFileData(
                    at: file, limit: HazkeyServerConfig.configFileSizeLimit, followFinalSymlink: true))
                XCTAssertEqual(unlink(file.path), 0)
                XCTAssertEqual(unlink(fifoTarget.path), 0)
            }
            let linkedConfig = root.appendingPathComponent("linked-config.json")
            try Data(#"[{"profileName":"Linked config"}]"#.utf8).write(to: linkedConfig)
            XCTAssertEqual(symlink(linkedConfig.path, config.path), 0)
            XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, "Linked config")
            XCTAssertEqual(unlink(config.path), 0)
            XCTAssertEqual(mkfifo(config.path, 0o600), 0)
            XCTAssertThrowsError(try HazkeyServerConfig.loadConfig())
            XCTAssertEqual(mkfifo(journal.path, 0o600), 0)
            XCTAssertThrowsError(try HazkeyServerConfig.loadConfig())
            XCTAssertEqual(unlink(config.path), 0)
            XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName,
                           HazkeyServerConfig.genDefaultConfig().profileName)
        }
    }

    func testConfigLoadsThroughSymlinkedConfigHome() throws {
        try withIsolatedServerEnvironment { root in
            let home = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
            let config = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"[{"profileName":"Parent link"}]"#.utf8).write(to: config)
            let link = root.appendingPathComponent("linked-home")
            XCTAssertEqual(symlink(home, link.path), 0)
            setenv("XDG_CONFIG_HOME", link.path, 1)
            XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, "Parent link")
        }
    }

    func testSaveRejectsConfigThatWouldExceedTheReadLimitAndKeepsTheSavedConfig() throws {
        try withIsolatedServerEnvironment { _ in
            // 前提: 読み直せる設定を一度保存しておく
            let config = HazkeyServerConfig()
            var saved = HazkeyServerConfig.genDefaultConfig()
            saved.profileName = "Saved"
            try config.saveConfig([saved])
            let revision = config.configRevision
            let configPath = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("config.json")
            let journalPath = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("config.json.tmp")
            let savedBytes = try Data(contentsOf: configPath)

            // 実行: JSONエスケープで1文字6バイトになる制御文字を並べ、上限以上のJSONを生成させる
            var oversized = HazkeyServerConfig.genDefaultConfig()
            oversized.profileName = String(repeating: "\u{0001}", count: 800_000)
            XCTAssertThrowsError(try config.saveConfig([oversized])) { error in
                guard case ConfigError.configTooLarge(let size, let limit)? = error as? ConfigError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertGreaterThanOrEqual(size, limit)
                XCTAssertEqual(limit, HazkeyServerConfig.configFileSizeLimit)
            }

            // 検証: ファイル・リビジョン・メモリ上の設定は変わらず、ジャーナルも残らない
            XCTAssertEqual(try Data(contentsOf: configPath), savedBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath.path))
            XCTAssertEqual(config.configRevision, revision)
            XCTAssertEqual(config.currentProfile.profileName, "Saved")
            XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, "Saved")

            // 検証: 上限未満なら保存でき、そのまま読み直せる
            var large = HazkeyServerConfig.genDefaultConfig()
            large.profileName = String(repeating: "\u{0001}", count: 300_000)
            try config.saveConfig([large])
            XCTAssertEqual(try HazkeyServerConfig.loadConfig().first?.profileName, large.profileName)
        }
    }
}

import CHazkeyLinux
import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class CustomInputFileSafetyTests: XCTestCase {
    func testDeepWildcardKeyIsRejectedAndOnlyItsTableIsSkipped() throws {
        try withIsolatedServerEnvironment { _ in
            let folder = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("table")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let key = String(repeating: "{any character}", count: 69_000)
            let contents = key + "\tx\n"
            XCTAssertLessThan(contents.utf8.count, TABLE_FILE_SIZE_LIMIT)
            try Data(contents.utf8).write(to: folder.appendingPathComponent("deep.tsv"))
            XCTAssertThrowsError(try HazkeyServerConfig.readValidatedCustomFile(
                filename: "deep.tsv", directory: "table", limit: TABLE_FILE_SIZE_LIMIT
            ) { try HazkeyServerConfig.loadInputTable(fromBoundedContents: $0) }) { error in
                XCTAssertEqual(error as? InputTableValidationError,
                               .keyColumnTooLong(line: 1, bytes: key.utf8.count))
            }

            try Data("ka\tか\n".utf8).write(to: folder.appendingPathComponent("normal.tsv"))
            let config = HazkeyServerConfig()
            config.currentProfile.enabledTables = ["deep.tsv", "normal.tsv"].map { filename in
                .with { $0.name = filename; $0.filename = filename; $0.isBuiltIn = false }
            }
            let tableName = UUID().uuidString
            config.loadInputTable(tableName: tableName)
            var composing = ComposingText()
            composing.insertAtCursorPosition("ka", inputStyle: .mapped(id: .tableName(tableName)))
            XCTAssertEqual(composing.convertTarget, "か")
        }
    }

    func testCustomTableKeyByteBoundaryAndNormalKeyStillLoad() throws {
        for count in [64, TABLE_KEY_COLUMN_BYTE_LIMIT] {
            let key = String(repeating: "a", count: count)
            let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: key + "\tx\n")
            XCTAssertEqual(try InputStyleManager.exportTable(table), key + "\tx")
        }
        let bytes = TABLE_KEY_COLUMN_BYTE_LIMIT + 1
        XCTAssertThrowsError(try HazkeyServerConfig.loadInputTable(
            fromBoundedContents: String(repeating: "a", count: bytes) + "\tx\n")) { error in
                XCTAssertEqual(error as? InputTableValidationError, .keyColumnTooLong(line: 1, bytes: bytes))
            }
        XCTAssertThrowsError(try HazkeyServerConfig.loadInputTable(
            fromBoundedContents: String(repeating: "あ", count: 342) + "\tx\n")) { error in
                XCTAssertEqual(error as? InputTableValidationError, .keyColumnTooLong(line: 1, bytes: 1026))
            }
    }

    func testLongLinesWithoutTabAreIgnoredLikeTheForkParser() throws {
        let contents = "\n" + String(repeating: "a", count: 69_000) + "\nka\tか\n\n"
        let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: contents)
        XCTAssertEqual(try InputStyleManager.exportTable(table), "ka\tか")
    }

    func testHugeColumnFollowedOnlyByEmptyColumnsIsIgnoredLikeTheForkParser() throws {
        for suffix in ["\t", "\t\t"] {
            let contents = String(repeating: "X", count: 69_000) + suffix + "\nka\tか\n"
            let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: contents)
            XCTAssertEqual(try InputStyleManager.exportTable(table), "ka\tか")
        }
    }

    func testValueColumnByteBoundaryRejectsUnclosedBraceScanBeforeParsing() throws {
        let value = String(repeating: "x", count: TABLE_VALUE_COLUMN_BYTE_LIMIT)
        let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: "a\t" + value + "\n")
        XCTAssertEqual(try InputStyleManager.exportTable(table), "a\t" + value)
        for value in [String(repeating: "{", count: 69_000),
                      String(repeating: "x", count: TABLE_VALUE_COLUMN_BYTE_LIMIT + 1),
                      String(repeating: "あ", count: 342)] {
            XCTAssertThrowsError(try HazkeyServerConfig.loadInputTable(fromBoundedContents: "a\t" + value + "\n")) { error in
                XCTAssertEqual(error as? InputTableValidationError,
                               .valueColumnTooLong(line: 1, bytes: value.utf8.count))
            }
        }
    }

    func testLeadingEmptyColumnsCannotBypassKeyLengthValidation() throws {
        let key = String(repeating: "{any character}", count: 69_000)
        for prefix in ["\t", "\t\t"] {
            XCTAssertThrowsError(try HazkeyServerConfig.loadInputTable(fromBoundedContents: prefix + key + "\tx\n")) { error in
                XCTAssertEqual(error as? InputTableValidationError, .keyColumnTooLong(line: 1, bytes: key.utf8.count))
            }
        }
        let table = try HazkeyServerConfig.loadInputTable(fromBoundedContents: "\t\tka\tか\n")
        XCTAssertEqual(try InputStyleManager.exportTable(table), "ka\tか")
    }

    func testCustomFilenamesRejectTraversalSymlinksAndOversizeFiles() throws {
        let root = try TestTempRoot.make()
        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer {
            if let previous { setenv("XDG_CONFIG_HOME", previous, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        for directory in ["keymap", "table"] {
            let folder = HazkeyServerConfig.getConfigDirectory().appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["", ".", "..", "../outside.tsv", "/outside.tsv", "bad\0.tsv"] {
                XCTAssertThrowsError(try HazkeyServerConfig.validatedCustomFile(filename: name, directory: directory, limit: 16))
            }
            let valid = folder.appendingPathComponent("valid.tsv")
            try Data("a\tb".utf8).write(to: valid)
            XCTAssertEqual(try HazkeyServerConfig.validatedCustomFile(filename: "valid.tsv", directory: directory, limit: 16), valid)
            let large = folder.appendingPathComponent("large.tsv")
            try Data(count: 16).write(to: large)
            XCTAssertThrowsError(try HazkeyServerConfig.validatedCustomFile(filename: "large.tsv", directory: directory, limit: 16))
            let outside = root.appendingPathComponent("outside.tsv")
            try Data("a\tb".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.tsv"), withDestinationURL: outside)
            XCTAssertThrowsError(try HazkeyServerConfig.validatedCustomFile(filename: "link.tsv", directory: directory, limit: 16))
        }
    }

    func testCustomFileIsReadThroughTheValidatedDescriptor() throws {
        let root = try TestTempRoot.make()
        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer {
            if let previous { setenv("XDG_CONFIG_HOME", previous, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        let folder = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("table")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let valid = folder.appendingPathComponent("valid.tsv")
        try Data("ka\t\u{304B}\n".utf8).write(to: valid)

        let contents = try HazkeyServerConfig.readValidatedCustomFile(
            filename: "valid.tsv", directory: "table", limit: 64
        ) { $0 }
        XCTAssertEqual(contents, "ka\t\u{304B}\n")
        XCTAssertNoThrow(
            try HazkeyServerConfig.readValidatedCustomFile(filename: "valid.tsv", directory: "table", limit: 64) {
                try HazkeyServerConfig.loadInputTable(fromBoundedContents: $0)
            })

        let fifo = folder.appendingPathComponent("pipe.tsv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(
            try HazkeyServerConfig.readValidatedCustomFile(filename: "pipe.tsv", directory: "table", limit: 64) { _ in })
    }

    // 検証後に同じinodeへ追記された内容を、入力テーブルの解析が読まないことを検証する
    // 変換エンジンはURLから全体を読み直すため、元のファイルを渡すと上限を超えた内容まで読む
    func testInputTableIgnoresContentAppendedToTheSameInodeAfterTheBoundedRead() throws {
        try withIsolatedServerEnvironment { _ in
            let folder = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("table")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let table = folder.appendingPathComponent("grow.tsv")
            try Data("ka\t\u{304B}\n".utf8).write(to: table)

            let exported = try HazkeyServerConfig.readValidatedCustomFile(
                filename: "grow.tsv", directory: "table", limit: 64
            ) { contents -> String in
                // 上限付きの読み込みの後、解析の前に同じinodeへ上限を超える規則を追記する
                let handle = try FileHandle(forWritingTo: table)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(String(repeating: "zz\t\u{305A}\n", count: 64).utf8))
                try handle.close()
                return try InputStyleManager.exportTable(
                    HazkeyServerConfig.loadInputTable(fromBoundedContents: contents))
            }
            XCTAssertTrue(exported.contains("ka\t\u{304B}"))
            XCTAssertFalse(exported.contains("zz"))
        }
    }

    // 入力テーブルへ渡す[memfd]の複製が書き込み封印され、変更できないことを検証する
    func testSealedTableCopyRejectsWritesAndGrowth() {
        let fd = Array("ka\t\u{304B}\n".utf8).withUnsafeBytes { bytes in
            hazkey_sealed_memfd("hazkey-test", bytes.baseAddress, bytes.count)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(write(fd, "x", 1), -1)
        XCTAssertEqual(errno, EPERM)
        XCTAssertNotEqual(ftruncate(fd, 4096), 0)
        let reopened = open("/proc/self/fd/\(fd)", O_WRONLY | O_CLOEXEC)
        if reopened >= 0 {
            XCTAssertEqual(write(reopened, "x", 1), -1)
            close(reopened)
        }
    }

    func testCustomKeymapSkipsMultiCharacterFieldsWithoutTruncation() {
        let map = HazkeyServerConfig.parseCustomKeymap("ab\tx\na\txy\nb\tx\tyz\nc\tx\ny\tz\tw\nz")
        XCTAssertNil(map["a"])
        XCTAssertNil(map["b"])
        XCTAssertEqual(map["c"]?.0, "x")
        XCTAssertEqual(map["y"]?.0, "z")
        XCTAssertEqual(map["y"]?.1, "w")
        XCTAssertNil(map["z"])
    }
}

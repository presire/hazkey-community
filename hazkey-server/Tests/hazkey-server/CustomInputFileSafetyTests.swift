import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class CustomInputFileSafetyTests: XCTestCase {
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

        let (path, contents) = try HazkeyServerConfig.readValidatedCustomFile(
            filename: "valid.tsv", directory: "table", limit: 64
        ) { descriptorURL, contents in
            (descriptorURL.path, contents)
        }
        XCTAssertTrue(path.hasPrefix("/proc/self/fd/"))
        XCTAssertEqual(contents, "ka\t\u{304B}\n")
        XCTAssertNoThrow(
            try HazkeyServerConfig.readValidatedCustomFile(filename: "valid.tsv", directory: "table", limit: 64) {
                descriptorURL, _ in try InputStyleManager.loadTable(from: descriptorURL)
            })

        let fifo = folder.appendingPathComponent("pipe.tsv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(
            try HazkeyServerConfig.readValidatedCustomFile(filename: "pipe.tsv", directory: "table", limit: 64) { _, _ in })
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

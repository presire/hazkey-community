import Foundation
import Glibc
import XCTest

@testable import hazkey_server

final class SafeLoggingTests: XCTestCase {
    func testHelperPreservesHostilePercentTextJapaneseAndTabs() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("log")
        let fd = open(output.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return XCTFail("open failed") }
        defer { close(fd) }
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { return XCTFail("dup failed") }
        defer { close(saved) }
        XCTAssertEqual(dup2(fd, STDERR_FILENO), STDERR_FILENO)
        let message = "日本語\t%s%s%s%s%s%s%s%s%n%@%p"
        hazkeyLog(message)
        XCTAssertEqual(dup2(saved, STDERR_FILENO), STDERR_FILENO)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains(message))
    }

    func testCustomKeymapHostilePercentLineDoesNotCrash() throws {
        try withIsolatedServerEnvironment { _ in
            let directory = HazkeyServerConfig.getConfigDirectory().appendingPathComponent("keymap")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let contents = "%s%s%s%s%s%s%s%s%s%s%s%s\tx\na\tb\n"
            try Data(contents.utf8).write(to: directory.appendingPathComponent("hostile.tsv"))
            let keymap = try HazkeyServerConfig.readValidatedCustomFile(
                filename: "hostile.tsv", directory: "keymap", limit: 65536
            ) { text in HazkeyServerConfig.parseCustomKeymap(text) }
            XCTAssertEqual(keymap["a"]?.0, "b")
            XCTAssertEqual(keymap.count, 1)
        }
    }

    func testResponseLoggingUsesOnlyPayloadCase() {
        XCTAssertEqual(ProtocolHandler.responsePayloadType(.text("秘匿入力%s")), "text")
        XCTAssertEqual(ProtocolHandler.responsePayloadType(.candidates(.with {
            $0.candidates = [.with { $0.text = "秘匿候補" }]
        })), "candidates")
        XCTAssertEqual(ProtocolHandler.responsePayloadType(nil), "none")
    }

    func testAllNSLogFormatsAreNonInterpolatedLiterals() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/hazkey-server")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let calls = try NSRegularExpression(pattern: #"\bNSLog\s*\("#)
        let literal = try NSRegularExpression(pattern: #"\bNSLog\s*\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]"#)
        var count = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for call in calls.matches(in: text, range: range) {
                count += 1
                let remaining = NSRange(location: call.range.location, length: range.length - call.range.location)
                guard let match = literal.firstMatch(in: text, options: .anchored, range: remaining),
                    let formatRange = Range(match.range(at: 1), in: text) else {
                    XCTFail("Non-literal NSLog format in \(file.path)")
                    continue
                }
                let format = String(text[formatRange])
                XCTAssertFalse(format.contains(#"\("#), "Interpolated NSLog format in \(file.path)")
                if format.contains("%") {
                    XCTAssertEqual(file.lastPathComponent, "utils.swift")
                    XCTAssertEqual(format, "%@")
                    XCTAssertTrue(text.contains(#"NSLog("%@", message as NSString)"#))
                }
            }
        }
        XCTAssertGreaterThan(count, 0)
    }
}

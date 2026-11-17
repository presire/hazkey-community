import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 補助記号辞書の読み込み (SymbolDictionaryProvider) のテスト
final class SymbolDictionaryProviderTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        temporaryDirectory = try TestTempRoot.make()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    /// 内容をファイルへ書いて読み込む
    private func load(_ contents: String) throws -> SymbolDictionaryProvider? {
        let url = try XCTUnwrap(temporaryDirectory).appendingPathComponent("symbol_dictionary.tsv")
        try Data(contents.utf8).write(to: url)
        return SymbolDictionaryProvider(tsvURL: url)
    }

    /// 3列のTSVから、読みごとのtierと記号を行順で読み込み、りーだー (長音符を含む読み) も受け付ける
    func testLoadsTiersAndSymbolsInRowOrder() throws {
        let provider = try XCTUnwrap(
            try load("やじるし\t→\tA\r\nやじるし\t←\tA\nした\t↓\tB\nりーだー\t…\tA\nやじるし\t→\tA\n"))
        XCTAssertEqual(provider.readingCount, 3)
        XCTAssertEqual(provider.entry(forReading: "やじるし"), .init(tier: .a, symbols: ["→", "←"]))
        XCTAssertEqual(provider.entry(forReading: "した"), .init(tier: .b, symbols: ["↓"]))
        XCTAssertEqual(provider.entry(forReading: "りーだー"), .init(tier: .a, symbols: ["…"]))
        // 辞書に無い読みはnilで、呼び出し側がBティアとして扱う
        XCTAssertNil(provider.entry(forReading: "みぎ"))
    }

    /// 列数・読み (許可外の文字・1文字)・tier・記号でない表記 (°C、かな) が不正な行は読み飛ばす
    func testSkipsInvalidRows() throws {
        let rows = [
            "どすう\t°C\tA", "どすう\t℃\tA", "ヤジルシ\t→\tA", "や\t→\tB", "やじるし1\t→\tA", "まる\t○\tC",
            "まる\t○", "まる\t○\tB\textra", "まる\tまる\tB", "まる\t\tB", "まる\t●\tB",
        ]
        let provider = try XCTUnwrap(try load(rows.joined(separator: "\n")))
        XCTAssertEqual(provider.readingCount, 2)
        XCTAssertEqual(provider.entry(forReading: "どすう")?.symbols, ["℃"])
        XCTAssertEqual(provider.entry(forReading: "まる")?.symbols, ["●"])
    }

    /// 同じ読みでtierが食い違う辞書は、全体を拒否する
    func testRejectsConflictingTiers() throws {
        XCTAssertNil(try load("まる\t○\tB\nまる\t●\tA\n"))
    }

    /// 有効な行が無い辞書と、UTF-8として読めない辞書は拒否する
    func testRejectsEmptyAndNonUTF8Dictionaries() throws {
        XCTAssertNil(try load("ヤジルシ\t→\tA\n"))
        let url = try XCTUnwrap(temporaryDirectory).appendingPathComponent("broken.tsv")
        try Data([0xE3, 0x81, 0x09, 0xFF, 0x0A]).write(to: url)
        XCTAssertNil(SymbolDictionaryProvider(tsvURL: url))
    }

    /// 1[MiB]以下の辞書は受け付け、1[MiB]を超える辞書・FIFO・存在しないパスは拒否する
    func testFileSizeLimitAndNonRegularFiles() throws {
        let row = "やじるし\t→\tA\n"
        let rowBytes = row.utf8.count
        let filler = SymbolDictionaryProvider.maxFileSize - rowBytes
        // 空行は読み飛ばされるため、改行で上限ちょうどまで埋める
        let exact = row + String(repeating: "\n", count: filler)
        XCTAssertNotNil(try load(exact))
        XCTAssertNil(try load(exact + "\n"))

        let fifo = try XCTUnwrap(temporaryDirectory).appendingPathComponent("fifo.tsv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(SymbolDictionaryProvider(tsvURL: fifo))
        XCTAssertNil(
            SymbolDictionaryProvider(tsvURL: try XCTUnwrap(temporaryDirectory).appendingPathComponent("missing.tsv")))
    }

    /// リポジトリの生成物は全行が有効で、Aティアの代表的な読みを含む
    func testRepositoryDictionaryLoads() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SymbolDictionary/symbol_dictionary.tsv")
        let provider = try XCTUnwrap(SymbolDictionaryProvider(tsvURL: url))
        XCTAssertEqual(provider.entry(forReading: "やじるし")?.tier, .a)
        XCTAssertEqual(provider.entry(forReading: "やじるし")?.symbols.first, "→")
        XCTAssertEqual(provider.entry(forReading: "かぎかっこ")?.symbols.first, "「」")
        XCTAssertEqual(provider.entry(forReading: "した")?.tier, .b)
    }
}

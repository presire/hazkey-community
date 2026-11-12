import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 郵便番号の候補プロバイダの正規化・TSV解析・ファイル境界のテスト
final class PostalCodeProviderTests: XCTestCase {
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

    /// 一時ディレクトリにTSVを書き込む
    ///
    /// - Parameters:
    ///   - contents: 書き込む内容
    ///   - name: ファイル名
    /// - Returns: 書き込んだファイルのパス
    private func writeTSV(_ contents: String, name: String = "postal_codes.tsv") throws -> URL {
        let url = try XCTUnwrap(temporaryDirectory).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: 正規化

    func testNormalizeAcceptsDigitsAndEveryHyphenVariant() {
        let accepted: [(String, String)] = [
            ("1000001", "1000001"),
            ("１０００００１", "1000001"),
            ("100-0001", "1000001"),
            ("１００ー０００１", "1000001"),
            ("100\u{FF0D}0001", "1000001"),
            ("100\u{2010}0001", "1000001"),
            ("100\u{2212}0001", "1000001"),
            ("100\u{FF70}0001", "1000001"),
            ("1０0-０001", "1000001"),
        ]
        for (input, key) in accepted {
            XCTAssertEqual(PostalCodeProvider.normalize(input), key, input)
        }
    }

    func testNormalizeRejectsOtherShapes() {
        let rejected = [
            "", "100000", "10000011", "1000-001", "10-00001", "100--0001", "100-0001-",
            "-1000001", "100 0001", "1000001k", "ａ000001", "100_0001", "١٠٠٠٠٠١",
        ]
        for input in rejected {
            XCTAssertNil(PostalCodeProvider.normalize(input), input)
        }
    }

    // MARK: TSVの解析

    func testMalformedRowsAreSkippedAndDataOrderIsKept() throws {
        let url = try writeTSV(
            """
            1000001\t東京都千代田区千代田
            bad
            12345\t短い番号
            1000002\t
            100000a\t数字でない番号
            1000003\t余分\t列
            1000005\t大阪府テスト市町域B\r
            1000005\t大阪府テスト市町域A

            1000004\t前後が入れ替わった行

            """)
        let provider = try XCTUnwrap(PostalCodeProvider(tsvURL: url))
        XCTAssertEqual(provider.entryCount, 4)
        XCTAssertEqual(provider.addresses(forKey: "1000001"), ["東京都千代田区千代田"])
        // 同じ番号の行はデータの出現順を保ち、並んでいない行は番号順へ並べ替える
        XCTAssertEqual(provider.addresses(forKey: "1000005"), ["大阪府テスト市町域B", "大阪府テスト市町域A"])
        XCTAssertEqual(provider.addresses(forKey: "1000004"), ["前後が入れ替わった行"])
        XCTAssertEqual(provider.addresses(forKey: "1000002"), [])
        XCTAssertEqual(provider.addresses(forKey: "1000003"), [])
        XCTAssertEqual(provider.addresses(forKey: "9999999"), [])
        XCTAssertEqual(provider.addresses(forKey: "100-0001"), [])
    }

    func testNoValidRowsYieldsNil() throws {
        XCTAssertNil(PostalCodeProvider(tsvURL: try writeTSV("bad\nalso\tbad\n1000001\t\n")))
        XCTAssertNil(PostalCodeProvider(tsvURL: try writeTSV("", name: "empty.tsv")))
    }

    // MARK: ファイルの境界

    func testMissingFileAndDirectoryYieldNil() throws {
        let directory = try XCTUnwrap(temporaryDirectory)
        XCTAssertNil(PostalCodeProvider(tsvURL: directory.appendingPathComponent("missing.tsv")))
        XCTAssertNil(PostalCodeProvider(tsvURL: directory))
    }

    func testFIFOIsRejectedWithoutBlocking() throws {
        let fifo = try XCTUnwrap(temporaryDirectory).appendingPathComponent("fifo.tsv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        // 書き込み側が無いFIFOを開いても停止せず、通常ファイルでないため拒否する
        XCTAssertNil(PostalCodeProvider(tsvURL: fifo))
    }

    func testFileAtTheReadLimitIsRejected() throws {
        let url = try writeTSV("1000001\t東京都千代田区千代田\n", name: "large.tsv")
        // 疎なファイルで上限ちょうどの大きさにする
        XCTAssertEqual(truncate(url.path, off_t(PostalCodeProvider.readLimit)), 0)
        XCTAssertNil(PostalCodeProvider(tsvURL: url))
    }

    func testFinalSymlinkToRegularFileIsRead() throws {
        let target = try writeTSV("1000001\t東京都千代田区千代田\n", name: "target.tsv")
        let link = try XCTUnwrap(temporaryDirectory).appendingPathComponent("link.tsv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let provider = try XCTUnwrap(PostalCodeProvider(tsvURL: link))
        XCTAssertEqual(provider.addresses(forKey: "1000001"), ["東京都千代田区千代田"])
    }
}

import Foundation
import XCTest

@testable import hazkey_server

/// submoduleの郵便番号辞書 (hazkey-address-dictionary/PostalCode/postal_codes.tsv) の制約と既知の値のテスト
final class PostalCodeDataTests: XCTestCase {
    private static var tsvURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("hazkey-address-dictionary/PostalCode/postal_codes.tsv")
    }

    /// 必須の郵便番号辞書を読み込む
    private func loadLines() throws -> [Substring] {
        let text = try String(contentsOf: Self.tsvURL, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { $0 }
    }

    func testEveryRowHasTwoColumnsSortedCodesAndCleanAddresses() throws {
        let lines = try loadLines()
        XCTAssertFalse(lines.isEmpty)
        var previousCode = ""
        var seenPairs: Set<Substring> = []
        let forbiddenFragments = ["(", ")", "（", "）", "以下に掲載がない場合", "がくる場合"]
        for (index, line) in lines.enumerated() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            XCTAssertEqual(columns.count, 2, "line \(index + 1)")
            guard columns.count == 2 else { continue }
            let code = String(columns[0])
            let address = columns[1]
            XCTAssertTrue(code.utf8.count == 7 && code.utf8.allSatisfy { (0x30...0x39).contains($0) }, "line \(index + 1)")
            XCTAssertFalse(address.isEmpty, "line \(index + 1)")
            XCTAssertLessThanOrEqual(previousCode, code, "line \(index + 1)")
            XCTAssertTrue(seenPairs.insert(line).inserted, "duplicate line \(index + 1)")
            for fragment in forbiddenFragments {
                XCTAssertFalse(address.contains(fragment), "line \(index + 1) contains \(fragment)")
            }
            previousCode = code
        }
    }

    func testKnownCodesResolveToTheirAddresses() throws {
        _ = try loadLines()
        let provider = try XCTUnwrap(PostalCodeProvider(tsvURL: Self.tsvURL))
        XCTAssertEqual(provider.addresses(forKey: "1000001"), ["東京都千代田区千代田"])
        XCTAssertEqual(provider.addresses(forKey: "0600000"), ["北海道札幌市中央区"])
    }

    /// 実データでの構築時間・初回と平均の照会時間・常駐メモリの増分を記録する
    func testPostalCodeProviderBenchmark() throws {
        let lines = try loadLines()
        let keys = lines.compactMap { $0.split(separator: "\t").first.map(String.init) }
        let firstKey = try XCTUnwrap(keys.first)

        let residentBefore = Self.residentBytes()
        let clock = ContinuousClock()
        var provider: PostalCodeProvider?
        let buildDuration = clock.measure { provider = PostalCodeProvider(tsvURL: Self.tsvURL) }
        let residentAfter = Self.residentBytes()
        let loaded = try XCTUnwrap(provider)

        var firstAddresses: [String] = []
        let firstLookupDuration = clock.measure { firstAddresses = loaded.addresses(forKey: firstKey) }
        XCTAssertFalse(firstAddresses.isEmpty)
        var hitCount = 0
        let lookupDuration = clock.measure {
            for key in keys { hitCount += loaded.addresses(forKey: key).count }
        }
        let normalizeDuration = clock.measure {
            for key in keys { _ = PostalCodeProvider.normalize(key) }
        }
        XCTAssertGreaterThan(hitCount, 0)
        let lookupMicroseconds = Double(lookupDuration.components.attoseconds) / 1e12
            + Double(lookupDuration.components.seconds) * 1e6
        let normalizeMicroseconds = Double(normalizeDuration.components.attoseconds) / 1e12
            + Double(normalizeDuration.components.seconds) * 1e6
        print(
            "POSTAL_BENCH rows=\(loaded.entryCount) build=\(buildDuration)"
                + " first_lookup=\(firstLookupDuration)"
                + " lookup_avg_us=\(lookupMicroseconds / Double(keys.count))"
                + " normalize_avg_us=\(normalizeMicroseconds / Double(keys.count))"
                + " rss_delta_kib=\((residentAfter - residentBefore) / 1024)")
    }

    /// /proc/self/statm から常駐メモリ (バイト) を読む
    private static func residentBytes() -> Int {
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
        let fields = statm.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else { return 0 }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    }
}

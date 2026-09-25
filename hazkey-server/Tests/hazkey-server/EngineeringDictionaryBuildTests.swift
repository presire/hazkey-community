import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// [community] Drift guard for the generated engineering terms dictionary.
///
/// `hazkey-engineering-dictionary` ships both the source TSV and the compiled
/// LOUDS shards. CI never re-runs the offline screening that produced the TSV;
/// it only re-runs this compilation and asserts the committed binaries match
/// byte for byte, so a stale or hand-edited shard cannot reach a release.
///
/// Set `HAZKEY_ENGINEERING_DICTIONARY_REGENERATE=1` to rewrite the committed
/// output instead of asserting against it. That is the supported way to
/// refresh the asset after the TSV or the system dictionary changes.
final class EngineeringDictionaryBuildTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var assetRoot: URL {
        Self.repositoryRoot.appendingPathComponent("hazkey-engineering-dictionary", isDirectory: true)
    }

    private static var sourceTSVURL: URL {
        Self.assetRoot.appendingPathComponent("data/engineering_entries.tsv", isDirectory: false)
    }

    private static var committedLoudsURL: URL {
        Self.assetRoot.appendingPathComponent("EngineeringDictionary/louds", isDirectory: true)
    }

    private static var systemCharIDURL: URL {
        Self.repositoryRoot.appendingPathComponent(
            "hazkey-server/azooKey_dictionary_storage/Dictionary/louds/charID.chid",
            isDirectory: false)
    }

    /// `pos` 列から CID への対応。`CIDData.固有名詞` / `固有名詞組織` / `一般名詞` と同値で、新規CIDは追加しない
    private static let cidByPOS: [String: Int] = [
        "proper": 1288,
        "org": 1292,
        "general": 1285,
    ]
    /// 一般。専門用語専用のMIDは存在しない
    private static let generalMID = 501
    /// `DicdataStore.threshold` (-17) を下回らせない開始スコア
    private static let baseScore: PValue = -15.5

    private enum FixtureError: Error {
        case missingAsset(String)
        case malformedRow(Int, String)
    }

    private func loadEntries() throws -> [DicdataElement] {
        let url = Self.sourceTSVURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FixtureError.missingAsset(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [DicdataElement] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if line.hasPrefix("#") {
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, !columns[0].isEmpty, !columns[1].isEmpty,
                let cid = Self.cidByPOS[String(columns[2])]
            else {
                throw FixtureError.malformedRow(offset + 1, String(line))
            }
            entries.append(
                DicdataElement(
                    word: String(columns[1]),
                    ruby: String(columns[0]),
                    lcid: cid,
                    rcid: cid,
                    mid: Self.generalMID,
                    value: Self.baseScore
                ))
        }
        return entries
    }

    private func build(into loudsDirectory: URL) throws {
        try? FileManager.default.removeItem(at: loudsDirectory)
        try FileManager.default.createDirectory(at: loudsDirectory, withIntermediateDirectories: true)
        try DictionaryBuilder.exportDictionary(
            entries: try self.loadEntries(),
            to: loudsDirectory,
            baseName: "engineering",
            shardByFirstCharacter: true,
            charIDFileURL: Self.systemCharIDURL
        )
        // 照合スタンプ。DicdataStore はこれがシステム辞書と一致しなければ工学用語辞書を無効化する
        try FileManager.default.copyItem(
            at: Self.systemCharIDURL,
            to: loudsDirectory.appendingPathComponent("charID.chid", isDirectory: false))
    }

    private func fileNames(in directory: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).map { $0.lastPathComponent })
    }

    func testCommittedLoudsMatchesFreshBuildFromSourceTSV() throws {
        guard FileManager.default.isReadableFile(atPath: Self.sourceTSVURL.path) else {
            throw XCTSkip("hazkey-engineering-dictionary asset is not checked out")
        }
        if ProcessInfo.processInfo.environment["HAZKEY_ENGINEERING_DICTIONARY_REGENERATE"] == "1" {
            try self.build(into: Self.committedLoudsURL)
            print("[hazkey] regenerated \(Self.committedLoudsURL.path)")
            return
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazkey-engineering-louds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try self.build(into: temporary)

        let expected = try self.fileNames(in: Self.committedLoudsURL)
        let actual = try self.fileNames(in: temporary)
        XCTAssertEqual(
            actual, expected,
            "committed LOUDS file set drifted from a fresh build of engineering_entries.tsv")

        for name in expected.intersection(actual) {
            let committed = try Data(
                contentsOf: Self.committedLoudsURL.appendingPathComponent(name, isDirectory: false))
            let rebuilt = try Data(contentsOf: temporary.appendingPathComponent(name, isDirectory: false))
            XCTAssertEqual(committed, rebuilt, "committed \(name) differs from a fresh build")
        }
    }

    func testSourceTSVRowsSatisfyTheEngineConstraints() throws {
        guard FileManager.default.isReadableFile(atPath: Self.sourceTSVURL.path) else {
            throw XCTSkip("hazkey-engineering-dictionary asset is not checked out")
        }
        let charIDText = try String(contentsOf: Self.systemCharIDURL, encoding: .utf8)
        let knownCharacters = Set(charIDText)
        let entries = try self.loadEntries()
        XCTAssertFalse(entries.isEmpty)

        // 同じ読み・表記でも CID が異なる要素は別エントリとして許す
        var seen: Set<String> = []
        for entry in entries {
            XCTAssertLessThanOrEqual(
                entry.ruby.count, 20, "ruby exceeds DicdataStore.maxlength: \(entry.ruby)")
            XCTAssertTrue(
                entry.ruby.allSatisfy { knownCharacters.contains($0) },
                "ruby contains a character missing from charID.chid: \(entry.ruby)")
            XCTAssertTrue(
                entry.ruby.allSatisfy { $0.isKatakana || $0 == "ー" },
                "ruby is not katakana: \(entry.ruby)")
            XCTAssertTrue(
                seen.insert("\(entry.ruby)\t\(entry.word)\t\(entry.lcid)").inserted,
                "duplicate entry: \(entry.ruby) -> \(entry.word) (\(entry.lcid))")
        }
        XCTAssertGreaterThan(Self.baseScore, -17, "score must stay above DicdataStore.threshold")
    }
}

extension Character {
    fileprivate var isKatakana: Bool {
        guard let scalar = self.unicodeScalars.first, self.unicodeScalars.count == 1 else {
            return false
        }
        return (0x30A1...0x30FA).contains(scalar.value) || (0x30FC...0x30FF).contains(scalar.value)
    }
}

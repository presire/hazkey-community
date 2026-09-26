import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 工学用語辞書トグルのエンドツーエンド検証
///
/// コンバータ構築時に工学用語ソースを住所ソースと並べて登録し、Profile.use_engineering_dictionaryで有効化を制御する
/// これらのテストは、コミット済みサブモジュールアセットに対して実際のサーバ状態を操作する
final class EngineeringDictionaryServerTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
        "HAZKEY_ADDRESS_DICTIONARY",
        "HAZKEY_ENGINEERING_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case setFailed(String)
        case missingPath(String)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var systemDictionaryURL: URL {
        Self.repositoryRoot.appendingPathComponent(
            "hazkey-server/azooKey_dictionary_storage/Dictionary", isDirectory: true)
    }

    private static var engineeringDictionaryURL: URL {
        Self.repositoryRoot.appendingPathComponent(
            "hazkey-engineering-dictionary/EngineeringDictionary", isDirectory: true)
    }

    private static var engineeringSourceTSVURL: URL {
        Self.repositoryRoot.appendingPathComponent(
            "hazkey-engineering-dictionary/data/engineering_entries.tsv", isDirectory: false)
    }

    private static var addressDictionaryURL: URL {
        Self.repositoryRoot.appendingPathComponent(
            "hazkey-address-dictionary/AddressDictionary", isDirectory: true)
    }

    private static let engineeringReading = "ざいりんくす"
    private static let engineeringWord = "Xilinx"
    private static let addressReading = "ひとつや"
    private static let addressWord = "一ツ家"

    override func setUpWithError() throws {
        for asset in [Self.engineeringDictionaryURL, Self.addressDictionaryURL] {
            guard
                FileManager.default.isReadableFile(
                    atPath: asset.appendingPathComponent("louds/charID.chid").path)
            else {
                throw XCTSkip("\(asset.deletingLastPathComponent().lastPathComponent) is not checked out")
            }
        }
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey-community"), withIntermediateDirectories: true)

        let paths = [
            "XDG_DATA_HOME": "data",
            "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime",
            "XDG_STATE_HOME": "state",
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            let overridePath: String? =
                switch variable {
                case "HAZKEY_DICTIONARY":
                    Self.systemDictionaryURL.path
                case "HAZKEY_ADDRESS_DICTIONARY":
                    Self.addressDictionaryURL.path
                case "HAZKEY_ENGINEERING_DICTIONARY":
                    Self.engineeringDictionaryURL.path
                default:
                    nil
                }
            if let overridePath {
                try self.setEnvironment(variable, overridePath)
                continue
            }
            guard let directory = paths[variable] else {
                throw SetupError.missingPath(variable)
            }
            try self.setEnvironment(variable, root.appendingPathComponent(directory).path)
        }
        temporaryDirectory = root
    }

    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                setenv(variable, value, 1)
            } else {
                unsetenv(variable)
            }
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func setEnvironment(_ variable: String, _ value: String) throws {
        guard setenv(variable, value, 1) == 0 else {
            throw SetupError.setFailed(variable)
        }
    }

    private func candidateWords(_ shared: HazkeySharedResources, reading: String) -> [String] {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }

    private func makeSharedResources(
        useEngineeringDictionary: Bool, useAddressDictionary: Bool = false
    ) -> HazkeySharedResources {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = false
        shared.serverConfig.currentProfile.useEngineeringDictionary = useEngineeringDictionary
        shared.serverConfig.currentProfile.useAddressDictionary = useAddressDictionary
        shared.syncConverterAddressDictionary()
        return shared
    }

    private func offers(_ shared: HazkeySharedResources) -> (engineering: Bool, address: Bool) {
        (
            self.candidateWords(shared, reading: Self.engineeringReading).contains(Self.engineeringWord),
            self.candidateWords(shared, reading: Self.addressReading).contains(Self.addressWord)
        )
    }

    func testEngineeringDictionaryIsDiscoveredFromTheEnvironment() {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        XCTAssertEqual(
            shared.serverConfig.engineeringDictionaryPath?.standardizedFileURL.path,
            Self.engineeringDictionaryURL.standardizedFileURL.path)
        XCTAssertTrue(
            shared.converter.isSupplementalDictionaryAvailable(
                for: HazkeySharedResources.engineeringDictionarySourceID))
        XCTAssertTrue(
            shared.converter.isSupplementalDictionaryAvailable(
                for: HazkeySharedResources.addressDictionarySourceID))
    }

    func testUnsetEnvironmentFallsBackToTheSystemResourcePath() {
        unsetenv("HAZKEY_ENGINEERING_DICTIONARY")
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        let systemPath = URL(fileURLWithPath: systemResourcePath).appendingPathComponent(
            "EngineeringDictionary", isDirectory: true)
        XCTAssertEqual(
            shared.serverConfig.engineeringDictionaryPath,
            HazkeyServerConfig.existingDirectoryURL(systemPath, fileManager: FileManager()))
    }

    func testEngineeringTermIsOfferedWhenEnabled() {
        let shared = self.makeSharedResources(useEngineeringDictionary: true)
        XCTAssertTrue(
            self.candidateWords(shared, reading: Self.engineeringReading).contains(Self.engineeringWord),
            "\(Self.engineeringWord) missing from candidates")
        XCTAssertTrue(
            self.candidateWords(shared, reading: "いそうどうきかいろ").contains("位相同期回路"),
            "位相同期回路 missing from candidates")
    }

    func testEngineeringTermIsWithheldWhenDisabled() {
        let shared = self.makeSharedResources(useEngineeringDictionary: false)
        XCTAssertFalse(
            self.candidateWords(shared, reading: Self.engineeringReading).contains(Self.engineeringWord),
            "\(Self.engineeringWord) leaked into candidates while the engineering dictionary was off")
    }

    func testEngineeringAndAddressTogglesAreIndependent() {
        let shared = self.makeSharedResources(useEngineeringDictionary: true, useAddressDictionary: false)
        var offered = self.offers(shared)
        XCTAssertTrue(offered.engineering)
        XCTAssertFalse(offered.address)

        shared.serverConfig.currentProfile.useEngineeringDictionary = false
        shared.serverConfig.currentProfile.useAddressDictionary = true
        shared.syncConverterAddressDictionary()
        offered = self.offers(shared)
        XCTAssertFalse(offered.engineering)
        XCTAssertTrue(offered.address)

        shared.serverConfig.currentProfile.useEngineeringDictionary = true
        shared.syncConverterAddressDictionary()
        offered = self.offers(shared)
        XCTAssertTrue(offered.engineering)
        XCTAssertTrue(offered.address)
    }

    func testReinitializeConfigurationReappliesTheEngineeringToggle() {
        let shared = self.makeSharedResources(useEngineeringDictionary: false)
        XCTAssertFalse(self.offers(shared).engineering)
        shared.serverConfig.currentProfile.useEngineeringDictionary = true
        shared.reinitializeConfiguration()
        XCTAssertTrue(self.offers(shared).engineering)
    }

    func testMissingEngineeringAssetLeavesAddressAndNormalConversionWorking() throws {
        try self.setEnvironment("HAZKEY_ENGINEERING_DICTIONARY", "/nonexistent/hazkey-engineering-dictionary")
        let shared = self.makeSharedResources(useEngineeringDictionary: true, useAddressDictionary: true)
        XCTAssertNil(shared.serverConfig.engineeringDictionaryPath)
        XCTAssertFalse(
            shared.converter.isSupplementalDictionaryAvailable(
                for: HazkeySharedResources.engineeringDictionarySourceID))
        let offered = self.offers(shared)
        XCTAssertFalse(offered.engineering)
        XCTAssertTrue(offered.address)
        XCTAssertFalse(self.candidateWords(shared, reading: "へんかん").isEmpty)
    }

    func testMissingAddressAssetLeavesEngineeringWorking() {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        let converter = HazkeySharedResources.makeConverter(
            dictionaryURL: Self.systemDictionaryURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(
                    id: HazkeySharedResources.addressDictionarySourceID,
                    directoryURL: URL(fileURLWithPath: "/nonexistent/hazkey-address-dictionary")),
                SupplementalDictionarySource(
                    id: HazkeySharedResources.engineeringDictionarySourceID,
                    directoryURL: Self.engineeringDictionaryURL),
            ])
        XCTAssertFalse(
            converter.isSupplementalDictionaryAvailable(for: HazkeySharedResources.addressDictionarySourceID))
        XCTAssertTrue(
            converter.isSupplementalDictionaryAvailable(
                for: HazkeySharedResources.engineeringDictionarySourceID))
        XCTAssertTrue(
            self.convert(converter, options: shared.baseConvertRequestOptions, reading: Self.engineeringReading)
                .contains(Self.engineeringWord))
    }

    /// 複数ソースinitが拒否された場合は補助辞書なしで構築し、通常変換を継続する
    func testRejectedSourceListFallsBackToTheSystemDictionaryAlone() {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        let converter = HazkeySharedResources.makeConverter(
            dictionaryURL: Self.systemDictionaryURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(id: "engineering", directoryURL: Self.engineeringDictionaryURL),
                SupplementalDictionarySource(id: "engineering", directoryURL: Self.engineeringDictionaryURL),
            ])
        XCTAssertFalse(
            converter.isSupplementalDictionaryAvailable(
                for: HazkeySharedResources.engineeringDictionarySourceID))
        XCTAssertFalse(
            converter.setSupplementalDictionaryEnabled(
                true, for: HazkeySharedResources.engineeringDictionarySourceID))
        let words = self.convert(
            converter, options: shared.baseConvertRequestOptions, reading: Self.engineeringReading)
        XCTAssertFalse(words.contains(Self.engineeringWord))
        XCTAssertTrue(
            self.convert(converter, options: shared.baseConvertRequestOptions, reading: "へんかん")
                .contains("変換"))
    }

    /// Pythonは、base converterが単独で候補に出せるため、収録基準どおり工学用語辞書には入れていない
    /// トグルOFFでも候補に出ることと、ソースTSVに存在しないことの両方を確認する
    func testBaseConvertibleTermIsNotShippedAndIsOfferedWithoutTheDictionary() throws {
        let tsv = try String(contentsOf: Self.engineeringSourceTSVURL, encoding: .utf8)
        let surfaces = Set(
            tsv.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap {
                $0.split(separator: "\t", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
            })
        XCTAssertFalse(surfaces.isEmpty)
        XCTAssertFalse(surfaces.contains("Python"))

        let shared = self.makeSharedResources(useEngineeringDictionary: false)
        XCTAssertTrue(self.candidateWords(shared, reading: "ぱいそん").contains("Python"))
    }

    private func convert(
        _ converter: KanaKanjiConverter, options: ConvertRequestOptions, reading: String
    ) -> [String] {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        var options = options
        options.zenzaiMode = .off
        return converter.requestCandidates(composingText, options: options).mainResults.map(\.text)
    }
}

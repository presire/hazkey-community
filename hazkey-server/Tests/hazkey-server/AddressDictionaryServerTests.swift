import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// [community] End-to-end coverage for the address dictionary toggle.
///
/// The supplemental source is wired at converter construction and gated by
/// `Profile.use_address_dictionary`. These tests drive the real server state
/// against the committed `hazkey-address-dictionary` asset.
final class AddressDictionaryServerTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
        "HAZKEY_ADDRESS_DICTIONARY",
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

    private static var addressDictionaryURL: URL {
        Self.repositoryRoot.appendingPathComponent(
            "hazkey-address-dictionary/AddressDictionary", isDirectory: true)
    }

    override func setUpWithError() throws {
        guard
            FileManager.default.isReadableFile(
                atPath: Self.addressDictionaryURL.appendingPathComponent("louds/charID.chid").path)
        else {
            throw XCTSkip("hazkey-address-dictionary submodule is not checked out")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-address-dictionary-\(UUID().uuidString)", isDirectory: true)
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
                    Self.repositoryRoot.appendingPathComponent(
                        "hazkey-server/azooKey_dictionary_storage/Dictionary", isDirectory: true
                    ).path
                case "HAZKEY_ADDRESS_DICTIONARY":
                    Self.addressDictionaryURL.path
                default:
                    nil
                }
            if let overridePath {
                guard setenv(variable, overridePath, 1) == 0 else {
                    throw SetupError.setFailed(variable)
                }
                continue
            }
            guard let directory = paths[variable] else {
                throw SetupError.missingPath(variable)
            }
            guard setenv(variable, root.appendingPathComponent(directory).path, 1) == 0 else {
                throw SetupError.setFailed(variable)
            }
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

    private func candidateWords(
        _ shared: HazkeySharedResources, reading: String, isSuggest: Bool = false
    ) -> [String] {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }

    private func makeSharedResources(useAddressDictionary: Bool) -> HazkeySharedResources {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = false
        shared.serverConfig.currentProfile.useAddressDictionary = useAddressDictionary
        shared.syncConverterAddressDictionary()
        return shared
    }

    func testAddressDictionaryIsDiscoveredFromTheEnvironment() {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        XCTAssertEqual(
            shared.serverConfig.addressDictionaryPath?.standardizedFileURL.path,
            Self.addressDictionaryURL.standardizedFileURL.path)
        XCTAssertTrue(shared.converter.isSupplementalDictionaryAvailable)
    }

    func testUnsetEnvironmentFallsBackToTheSystemResourcePath() {
        unsetenv("HAZKEY_ADDRESS_DICTIONARY")
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        let systemPath = URL(fileURLWithPath: systemResourcePath).appendingPathComponent(
            "AddressDictionary", isDirectory: true)
        XCTAssertEqual(
            shared.serverConfig.addressDictionaryPath,
            HazkeyServerConfig.existingDirectoryURL(systemPath, fileManager: FileManager()))
    }

    func testHardPlaceNameIsOfferedWhenEnabled() {
        let shared = self.makeSharedResources(useAddressDictionary: true)
        XCTAssertTrue(
            self.candidateWords(shared, reading: "ひとつや").contains("一ツ家"),
            "一ツ家 missing from candidates")
    }

    func testDistrictPrefixedMunicipalityIsOfferedWhenEnabled() {
        let shared = self.makeSharedResources(useAddressDictionary: true)
        XCTAssertTrue(
            self.candidateWords(shared, reading: "あいらぐんゆうすいちょう").contains("姶良郡湧水町"),
            "姶良郡湧水町 missing from candidates")
    }

    func testHardPlaceNameIsWithheldWhenDisabled() {
        let shared = self.makeSharedResources(useAddressDictionary: false)
        XCTAssertFalse(
            self.candidateWords(shared, reading: "ひとつや").contains("一ツ家"),
            "一ツ家 leaked into candidates while the address dictionary was off")
    }

    /// 上伊那郡辰野町 は base converter が単独で先頭に出せるため、収録基準どおり住所辞書には入れていない。
    /// トグルOFFでも同じ先頭候補が出ることが、基準が守られている証拠になる。
    /// (住所辞書ONでは部分読みに対する候補が下位に増えるため、候補列全体の一致は要求しない)
    func testBaseConvertibleDistrictNameIsOfferedRegardlessOfTheToggle() {
        let reading = "かみいなぐんたつのまち"
        let enabled = self.candidateWords(self.makeSharedResources(useAddressDictionary: true), reading: reading)
        let disabled = self.candidateWords(self.makeSharedResources(useAddressDictionary: false), reading: reading)
        XCTAssertEqual(enabled.first, "上伊那郡辰野町")
        XCTAssertEqual(disabled.first, "上伊那郡辰野町")
    }

    func testToggleTakesEffectWithoutRebuildingTheConverter() {
        let shared = self.makeSharedResources(useAddressDictionary: false)
        XCTAssertFalse(self.candidateWords(shared, reading: "ひとつや").contains("一ツ家"))

        shared.serverConfig.currentProfile.useAddressDictionary = true
        shared.syncConverterAddressDictionary()
        XCTAssertTrue(self.candidateWords(shared, reading: "ひとつや").contains("一ツ家"))
    }

    func testMissingAssetLeavesNormalConversionWorking() throws {
        guard setenv("HAZKEY_ADDRESS_DICTIONARY", "/nonexistent/hazkey-address-dictionary", 1) == 0
        else {
            throw SetupError.setFailed("HAZKEY_ADDRESS_DICTIONARY")
        }
        let shared = self.makeSharedResources(useAddressDictionary: true)
        XCTAssertNil(shared.serverConfig.addressDictionaryPath)
        XCTAssertFalse(shared.converter.isSupplementalDictionaryAvailable)
        XCTAssertFalse(self.candidateWords(shared, reading: "ひとつや").contains("一ツ家"))
        XCTAssertFalse(self.candidateWords(shared, reading: "へんかん").isEmpty)
    }
}

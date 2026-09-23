import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class ConfigValidationTests: XCTestCase {
    func testDecodeProfilesRejectsWrongJSONShapes() {
        // Given: valid JSON whose top level or member has the wrong shape.
        let inputs = [Data("{}".utf8), Data("[\"profile\"]".utf8)]

        // When / Then: neither shape is accepted as a profile list.
        for input in inputs {
            XCTAssertThrowsError(try HazkeyServerConfig.decodeProfiles(from: input))
        }
    }

    func testDecodeProfilesNormalizesEmptyArrayToDefaultProfile() throws {
        // Given: an empty persisted profile list.
        let input = Data("[]".utf8)

        // When: it is decoded.
        let profiles = try HazkeyServerConfig.decodeProfiles(from: input)

        // Then: exactly one default profile is returned.
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(try XCTUnwrap(profiles.first).profileName, "Default")
    }

    func testNormalizeProfileUsesDefaultsForUnsetOptionalValues() throws {
        // Given: a profile received with optional configuration values unset.
        var profile = Hazkey_Config_Profile()
        profile.profileName = "Partial"

        // When: it crosses the configuration boundary.
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // Then: defaults are made explicit for all runtime numeric and enum settings.
        XCTAssertEqual(normalized.autoConvertMode, .autoConvertForMultipleChars)
        XCTAssertEqual(normalized.autoConvertMinChars, 2)
        XCTAssertEqual(normalized.numSuggestions, 3)
        XCTAssertEqual(normalized.numCandidatesPerPage, 9)
        XCTAssertEqual(normalized.zenzaiInferLimit, 10)
    }

    func testHalfwidthKatakanaCandidateOptionUsesExplicitProfileValue() throws {
        // Given: profiles that explicitly disable and enable halfwidth-kana candidates.
        var disabledProfile = HazkeyServerConfig.genDefaultConfig()
        disabledProfile.specialConversionMode.halfwidthKatakana = false
        var enabledProfile = HazkeyServerConfig.genDefaultConfig()
        enabledProfile.specialConversionMode.halfwidthKatakana = true
        let config = HazkeyServerConfig()

        // When: each normalized profile produces converter request options.
        config.currentProfile = try HazkeyServerConfig.normalizeProfile(disabledProfile)
        let disabledOptions = config.genBaseConvertRequestOptions()
        config.currentProfile = try HazkeyServerConfig.normalizeProfile(enabledProfile)
        let enabledOptions = config.genBaseConvertRequestOptions()

        // Then: the converter option preserves the explicit profile setting.
        XCTAssertFalse(disabledOptions.halfWidthKanaCandidate)
        XCTAssertTrue(enabledOptions.halfWidthKanaCandidate)
    }

    func testNormalizeProfileEnablesMissingHalfwidthKatakanaSetting() throws {
        // Given: a legacy profile whose halfwidth-katakana optional field is absent.
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.specialConversionMode.clearHalfwidthKatakana()

        // When: it crosses the configuration boundary.
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // Then: the default enabled value becomes explicit.
        XCTAssertTrue(normalized.specialConversionMode.hasHalfwidthKatakana)
        XCTAssertTrue(normalized.specialConversionMode.halfwidthKatakana)
    }

    func testNormalizeProfileRejectsUnknownEnumAndInvalidNumericValues() {
        // Given: profiles containing values the server cannot safely interpret.
        var unknownEnum = HazkeyServerConfig.genDefaultConfig()
        unknownEnum.autoConvertMode = .UNRECOGNIZED(99)
        var invalidNumber = HazkeyServerConfig.genDefaultConfig()
        invalidNumber.zenzaiInferLimit = 101

        // When / Then: validation rejects both before persistence.
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfile(unknownEnum))
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfile(invalidNumber))
    }

    func testNormalizeProfileAcceptsNumericBoundsAndRejectsEmptyProfiles() throws {
        // Given: profiles using the UI's inclusive numeric limits.
        var minimum = HazkeyServerConfig.genDefaultConfig()
        minimum.numSuggestions = 1
        minimum.autoConvertMinChars = 1
        minimum.numCandidatesPerPage = 1
        minimum.zenzaiInferLimit = 1
        var maximum = HazkeyServerConfig.genDefaultConfig()
        maximum.numSuggestions = 10
        maximum.autoConvertMinChars = 10
        maximum.numCandidatesPerPage = 10
        maximum.zenzaiInferLimit = 100

        // When: valid boundary profiles are normalized.
        let normalized = try HazkeyServerConfig.normalizeProfiles([minimum, maximum])

        // Then: both values survive and an empty SetConfig list is rejected.
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(try XCTUnwrap(normalized.first).numSuggestions, 1)
        XCTAssertEqual(try XCTUnwrap(normalized.last).zenzaiInferLimit, 100)
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfiles([]))
    }

    func testCustomKeymapParserSkipsMalformedRowsAndLoadsValidRows() {
        // Given: empty, tab-only, incomplete, and over-wide rows around valid rules.
        let contents = "\n\t\nA\tあ\nB\tい\t\nC\tう\textra\tignored\nD\nE\t\n"

        // When: the custom keymap is parsed.
        let keymap = HazkeyServerConfig.parseCustomKeymap(contents)

        // Then: malformed rows are ignored without preventing valid rules from loading.
        XCTAssertEqual(keymap["A"]?.0, "あ")
        XCTAssertNil(keymap["A"]?.1)
        XCTAssertEqual(keymap["B"]?.0, "い")
        XCTAssertNil(keymap["B"]?.1)
        XCTAssertNil(keymap["D"])
        XCTAssertNil(keymap["E"])
        XCTAssertEqual(keymap["C"]?.0, "う")
        XCTAssertEqual(keymap["C"]?.1, "e")
    }

    func testZenzaiModelResolverUsesValidCustomWeightAndRejectsInvalidCustomWeight() throws {
        // Given: a profile with custom weights enabled and both valid and invalid paths.
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let customModel = directory.appendingPathComponent("custom.gguf")
        try Data().write(to: customModel)
        let discoveredModel = directory.appendingPathComponent("discovered.gguf")
        try Data().write(to: discoveredModel)
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useZenzaiCustomWeight = true
        profile.zenzaiWeightPath = customModel.path

        // When: the custom path is valid, then changed to a missing path.
        let resolvedCustom = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)
        profile.zenzaiWeightPath = directory.appendingPathComponent("missing.gguf").path
        let resolvedMissing = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)

        // Then: the valid custom model wins, while an invalid explicit path disables Zenzai.
        XCTAssertEqual(resolvedCustom, customModel)
        XCTAssertNil(resolvedMissing)
    }

    func testZenzaiModelResolverUsesDiscoveryWhenCustomWeightIsDisabledOrEmpty() throws {
        // Given: an available discovered model and a profile without an active custom path.
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let discoveredModel = directory.appendingPathComponent("discovered.gguf")
        try Data().write(to: discoveredModel)
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useZenzaiCustomWeight = false
        profile.zenzaiWeightPath = directory.appendingPathComponent("ignored.gguf").path

        // When: custom weights are disabled, then enabled with an empty path.
        let disabledResolution = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)
        profile.useZenzaiCustomWeight = true
        profile.zenzaiWeightPath = ""
        let emptyResolution = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)

        // Then: normal model discovery is retained in both cases.
        XCTAssertEqual(disabledResolution, discoveredModel)
        XCTAssertEqual(emptyResolution, discoveredModel)
    }

    func testManagedZenzaiSymlinkToJinenModelIsAcceptedByResolver() throws {
        // Given: a managed <dataDir>/hazkey-community/zenzai/zenzai.gguf symlink pointing at a jinen-key GGUF.
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelsDirectory = directory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
        let jinenModel = modelsDirectory.appendingPathComponent("jinen-v2-small-Q5_K_M.gguf")
        try Data("jinen-fixture".utf8).write(to: jinenModel)
        let managedDirectory = directory.appendingPathComponent("hazkey-community/zenzai", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedDirectory, withIntermediateDirectories: true)
        let managedSymlink = managedDirectory.appendingPathComponent("zenzai.gguf")
        try FileManager.default.createSymbolicLink(at: managedSymlink, withDestinationURL: jinenModel)
        let savedDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let savedModelOverride = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"]
        guard setenv("XDG_DATA_HOME", directory.path, 1) == 0 else {
            XCTFail("Failed to sandbox XDG_DATA_HOME")
            return
        }
        guard unsetenv("HAZKEY_ZENZAI_MODEL") == 0 else {
            XCTFail("Failed to clear HAZKEY_ZENZAI_MODEL")
            return
        }
        defer {
            if let savedDataHome {
                setenv("XDG_DATA_HOME", savedDataHome, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
            if let savedModelOverride {
                setenv("HAZKEY_ZENZAI_MODEL", savedModelOverride, 1)
            }
        }

        // When: discovery runs against the sandboxed data dir and the result feeds the resolver.
        let discovered = getZenzaiModelPath()
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useZenzaiCustomWeight = false
        let resolved = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discovered)

        // Then: the managed symlink is discovered and accepted, pointing at the jinen target.
        XCTAssertEqual(discovered, managedSymlink)
        XCTAssertEqual(resolved, managedSymlink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: try XCTUnwrap(resolved).path),
            jinenModel.path)
    }

    func testReloadZenzaiModelReResolvesRetargetedManagedSymlink() throws {
        // Given: a managed symlink initially targeting one jinen key, loaded by a live config.
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelsDirectory = directory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
        let firstJinenModel = modelsDirectory.appendingPathComponent("jinen-v2-small-Q5_K_M.gguf")
        try Data("jinen-fixture-a".utf8).write(to: firstJinenModel)
        let secondJinenModel = modelsDirectory.appendingPathComponent("jinen-v2-xsmall-Q4_K_M.gguf")
        try Data("jinen-fixture-b".utf8).write(to: secondJinenModel)
        let managedDirectory = directory.appendingPathComponent("hazkey-community/zenzai", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedDirectory, withIntermediateDirectories: true)
        let managedSymlink = managedDirectory.appendingPathComponent("zenzai.gguf")
        try FileManager.default.createSymbolicLink(
            at: managedSymlink, withDestinationURL: firstJinenModel)
        let savedDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let savedConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let savedModelOverride = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"]
        guard setenv("XDG_DATA_HOME", directory.path, 1) == 0,
            setenv(
                "XDG_CONFIG_HOME", directory.appendingPathComponent("config").path, 1) == 0,
            unsetenv("HAZKEY_ZENZAI_MODEL") == 0
        else {
            XCTFail("Failed to sandbox XDG_DATA_HOME/XDG_CONFIG_HOME")
            return
        }
        defer {
            if let savedDataHome {
                setenv("XDG_DATA_HOME", savedDataHome, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
            if let savedConfigHome {
                setenv("XDG_CONFIG_HOME", savedConfigHome, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            if let savedModelOverride {
                setenv("HAZKEY_ZENZAI_MODEL", savedModelOverride, 1)
            }
        }
        let config = HazkeyServerConfig()
        config.reloadZenzaiModel()
        XCTAssertEqual(
            config.zenzaiModelPath?.resolvingSymlinksInPath(),
            firstJinenModel.resolvingSymlinksInPath())

        // When: the symlink is retargeted to a different jinen key and the model is reloaded.
        try FileManager.default.removeItem(at: managedSymlink)
        try FileManager.default.createSymbolicLink(
            at: managedSymlink, withDestinationURL: secondJinenModel)
        config.reloadZenzaiModel()

        // Then: the new target is returned, not the cached old one.
        XCTAssertEqual(config.zenzaiModelPath, managedSymlink)
        XCTAssertEqual(
            config.zenzaiModelPath?.resolvingSymlinksInPath(),
            secondJinenModel.resolvingSymlinksInPath())
        XCTAssertNotEqual(
            config.zenzaiModelPath?.resolvingSymlinksInPath(),
            firstJinenModel.resolvingSymlinksInPath())
    }

    /// The converter caches loaded models in a process-global registry keyed by the
    /// weight path string (`SharedZenzModelCache.cacheKey(path:deviceConfig:)`), so the
    /// path handed to it must be the resolved artifact and not the stable managed
    /// symlink. Before that resolution the Settings model switch kept serving the
    /// previously loaded weights until the server restarted, even though
    /// `reload_zenzai_model` ran.
    func testGenZenzaiModeHandsOverResolvedModelPathSoModelSwitchTakesEffect() throws {
        // Given: a managed symlink targeting one jinen artifact.
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelsDirectory = directory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
        let firstJinenModel = modelsDirectory.appendingPathComponent("jinen-v2-small-Q5_K_M.gguf")
        try Data("jinen-fixture-a".utf8).write(to: firstJinenModel)
        let secondJinenModel = modelsDirectory.appendingPathComponent("jinen-v2-xsmall-Q4_K_M.gguf")
        try Data("jinen-fixture-b".utf8).write(to: secondJinenModel)
        let managedDirectory = directory.appendingPathComponent("hazkey-community/zenzai", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedDirectory, withIntermediateDirectories: true)
        let managedSymlink = managedDirectory.appendingPathComponent("zenzai.gguf")
        try FileManager.default.createSymbolicLink(
            at: managedSymlink, withDestinationURL: firstJinenModel)
        let savedDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let savedConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let savedModelOverride = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"]
        guard setenv("XDG_DATA_HOME", directory.path, 1) == 0,
            setenv(
                "XDG_CONFIG_HOME", directory.appendingPathComponent("config").path, 1) == 0,
            unsetenv("HAZKEY_ZENZAI_MODEL") == 0
        else {
            XCTFail("Failed to sandbox XDG_DATA_HOME/XDG_CONFIG_HOME")
            return
        }
        defer {
            if let savedDataHome {
                setenv("XDG_DATA_HOME", savedDataHome, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
            if let savedConfigHome {
                setenv("XDG_CONFIG_HOME", savedConfigHome, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            if let savedModelOverride {
                setenv("HAZKEY_ZENZAI_MODEL", savedModelOverride, 1)
            }
        }
        let config = HazkeyServerConfig()
        config.reloadZenzaiModel()

        // The config keeps reporting the managed symlink; only the converter input resolves.
        XCTAssertEqual(config.zenzaiModelPath, managedSymlink)

        let beforeSwitch = config.genZenzaiMode(leftContext: "")
        XCTAssertNotEqual(beforeSwitch, .off, "Zenzai must be available for this check")
        let beforeWeight = try XCTUnwrap(
            Self.zenzaiWeightURL(of: beforeSwitch), "ZenzaiMode must carry a weight URL")
        XCTAssertEqual(
            beforeWeight.resolvingSymlinksInPath(), firstJinenModel.resolvingSymlinksInPath())
        XCTAssertNotEqual(beforeWeight, managedSymlink)

        // A reload without retargeting must not perturb the mode, so the difference
        // asserted below can only come from the model path itself.
        config.reloadZenzaiModel()
        XCTAssertEqual(config.genZenzaiMode(leftContext: ""), beforeSwitch)

        // When: the symlink is retargeted (a model switch) and reloaded.
        try FileManager.default.removeItem(at: managedSymlink)
        try FileManager.default.createSymbolicLink(
            at: managedSymlink, withDestinationURL: secondJinenModel)
        config.reloadZenzaiModel()
        let afterSwitch = config.genZenzaiMode(leftContext: "")

        // Then: the path handed to the converter changed, so its cache key changes and
        // the newly selected artifact is loaded instead of the stale one.
        let afterWeight = try XCTUnwrap(
            Self.zenzaiWeightURL(of: afterSwitch), "ZenzaiMode must carry a weight URL")
        XCTAssertEqual(
            afterWeight.resolvingSymlinksInPath(), secondJinenModel.resolvingSymlinksInPath())
        XCTAssertNotEqual(afterWeight, managedSymlink)
        XCTAssertNotEqual(afterSwitch, beforeSwitch)
    }

    /// Reads `ConvertRequestOptions.ZenzaiMode.weightURL`, which the converter module
    /// keeps internal; this suite only needs to observe the value it was given.
    private static func zenzaiWeightURL<T>(of mode: T) -> URL? {
        Mirror(reflecting: mode).children.first { $0.label == "weightURL" }?.value as? URL
    }

    func testZenzaiModelResolverRejectsDirectoryCustomWeight() throws {
        // Given: custom weight enabled with a directory and a symlink to a directory.
        let directory = try XCTUnwrap(FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let weightDirectory = directory.appendingPathComponent("weights-dir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: weightDirectory, withIntermediateDirectories: true)
        let directorySymlink = directory.appendingPathComponent("dir-link")
        try FileManager.default.createSymbolicLink(
            at: directorySymlink, withDestinationURL: weightDirectory)
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useZenzaiCustomWeight = true

        // When: the explicit custom path is a non-regular file in either form.
        profile.zenzaiWeightPath = weightDirectory.path
        let resolvedDirectory = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: nil)
        profile.zenzaiWeightPath = directorySymlink.path
        let resolvedDirectorySymlink = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: nil)

        // Then: both are rejected exactly like a missing custom path (nil, Zenzai disabled).
        XCTAssertNil(resolvedDirectory)
        XCTAssertNil(resolvedDirectorySymlink)
    }

    func testProfileHistoryDirectoryIsSharedUnlessIsolationIsEnabled() {
        // Given: a profile with an identifier that cannot be used directly as a path component.
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.profileID = "work/team"
        let stateDirectory = URL(fileURLWithPath: "/tmp/hazkey-state")

        // When: history isolation is disabled, then enabled.
        profile.useProfileIndependentHistory = false
        let sharedDirectory = HazkeyServerConfig.memoryDirectory(for: profile, stateDirectory: stateDirectory)
        profile.useProfileIndependentHistory = true
        let isolatedDirectory = HazkeyServerConfig.memoryDirectory(for: profile, stateDirectory: stateDirectory)

        // Then: shared history retains its existing location and isolated history has one safe component.
        XCTAssertEqual(sharedDirectory, stateDirectory.appendingPathComponent("memory", isDirectory: true))
        XCTAssertEqual(isolatedDirectory.deletingLastPathComponent(), sharedDirectory)
        XCTAssertFalse(isolatedDirectory.lastPathComponent.contains("/"))
        XCTAssertNotEqual(isolatedDirectory, sharedDirectory)
    }

    func testRichCandidateSelectionUsesTheRequestKind() {
        // Given: independently enabled rich suggestion and rich candidate settings.
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useRichSuggestion = true
        profile.useRichCandidates = false

        // When: options are selected for suggestion and manual conversion requests.
        let suggestionValue = HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: true)
        let conversionValue = HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: false)

        // Then: each request reads only its corresponding setting.
        XCTAssertTrue(suggestionValue)
        XCTAssertFalse(conversionValue)

        profile.useRichSuggestion = false
        profile.useRichCandidates = true
        XCTAssertFalse(HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: true))
        XCTAssertTrue(HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: false))
    }

    // MARK: - [community] Emoji 17 direct conversion (test-first, RED)

    func testDefaultExtendedEmojiIsEnabled() {
        // The factory default keeps extended emoji conversion enabled.
        XCTAssertTrue(HazkeyServerConfig.genDefaultConfig().specialConversionMode.extendedEmoji)
        XCTAssertTrue(HazkeyServerConfig.genDefaultConfig().extendedEmojiEffective)
    }

    func testAbsentExtendedEmojiNormalizesToEnabled() throws {
        // Given: a legacy profile whose extended_emoji optional is absent.
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.specialConversionMode.clearExtendedEmoji()
        XCTAssertFalse(profile.specialConversionMode.hasExtendedEmoji)

        // When: it crosses the configuration boundary.
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // Then: the enabled default becomes explicit.
        XCTAssertTrue(normalized.specialConversionMode.hasExtendedEmoji)
        XCTAssertTrue(normalized.specialConversionMode.extendedEmoji)
        XCTAssertTrue(normalized.extendedEmojiEffective)
    }

    func testExplicitFalseExtendedEmojiIsPreserved() throws {
        // Given: a profile that explicitly disables extended emoji.
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.specialConversionMode.extendedEmoji = false

        // When: it crosses the configuration boundary.
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // Then: the explicit opt-out survives normalization.
        XCTAssertTrue(normalized.specialConversionMode.hasExtendedEmoji)
        XCTAssertFalse(normalized.specialConversionMode.extendedEmoji)
        XCTAssertFalse(normalized.extendedEmojiEffective)
    }

    func testNormalizeProfileDefaultsMissingAddressDictionaryAndPreservesExplicitFalse() throws {
        // Given: a legacy profile missing the address-dictionary field and one opting out.
        var missing = HazkeyServerConfig.genDefaultConfig()
        missing.clearUseAddressDictionary()
        XCTAssertFalse(missing.hasUseAddressDictionary)
        var disabled = HazkeyServerConfig.genDefaultConfig()
        disabled.useAddressDictionary = false

        // When: each crosses the configuration boundary.
        let normalizedMissing = try HazkeyServerConfig.normalizeProfile(missing)
        let normalizedDisabled = try HazkeyServerConfig.normalizeProfile(disabled)

        // Then: the missing field defaults to disabled while the explicit opt-out survives.
        XCTAssertTrue(normalizedMissing.hasUseAddressDictionary)
        XCTAssertFalse(normalizedMissing.useAddressDictionary)
        XCTAssertFalse(normalizedMissing.useAddressDictionaryEffective)
        XCTAssertTrue(normalizedDisabled.hasUseAddressDictionary)
        XCTAssertFalse(normalizedDisabled.useAddressDictionary)
        XCTAssertFalse(normalizedDisabled.useAddressDictionaryEffective)
    }
}

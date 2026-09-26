import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class ConfigValidationTests: XCTestCase {
    func testDecodeProfilesRejectsWrongJSONShapes() {
        // 前提: 最上位またはメンバーの形が不正な有効JSON。
        let inputs = [Data("{}".utf8), Data("[\"profile\"]".utf8)]

        // 実行・検証: どちらの形もプロファイルリストとして受け入れない。
        for input in inputs {
            XCTAssertThrowsError(try HazkeyServerConfig.decodeProfiles(from: input))
        }
    }

    func testDecodeProfilesNormalizesEmptyArrayToDefaultProfile() throws {
        // 前提: 空の永続化済みプロファイルリスト。
        let input = Data("[]".utf8)

        // 実行: これをデコードする。
        let profiles = try HazkeyServerConfig.decodeProfiles(from: input)

        // 検証: 既定プロファイルを1件だけ返す。
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(try XCTUnwrap(profiles.first).profileName, "Default")
    }

    func testNormalizeProfileUsesDefaultsForUnsetOptionalValues() throws {
        // 前提: optional設定値が未設定のまま受け取ったプロファイル。
        var profile = Hazkey_Config_Profile()
        profile.profileName = "Partial"

        // 実行: 設定境界を通過させる。
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // 検証: 実行時の数値設定とenum設定すべてに既定値が明示される。
        XCTAssertEqual(normalized.autoConvertMode, .autoConvertForMultipleChars)
        XCTAssertEqual(normalized.autoConvertMinChars, 2)
        XCTAssertEqual(normalized.numSuggestions, 3)
        XCTAssertEqual(normalized.numCandidatesPerPage, 9)
        XCTAssertEqual(normalized.zenzaiInferLimit, 10)
    }

    func testHalfwidthKatakanaCandidateOptionUsesExplicitProfileValue() throws {
        // 前提: 半角かな候補を明示的に無効化または有効化したプロファイル。
        var disabledProfile = HazkeyServerConfig.genDefaultConfig()
        disabledProfile.specialConversionMode.halfwidthKatakana = false
        var enabledProfile = HazkeyServerConfig.genDefaultConfig()
        enabledProfile.specialConversionMode.halfwidthKatakana = true
        let config = HazkeyServerConfig()

        // 実行: 正規化済みプロファイルごとにconverter要求オプションを生成する。
        config.currentProfile = try HazkeyServerConfig.normalizeProfile(disabledProfile)
        let disabledOptions = config.genBaseConvertRequestOptions()
        config.currentProfile = try HazkeyServerConfig.normalizeProfile(enabledProfile)
        let enabledOptions = config.genBaseConvertRequestOptions()

        // 検証: converterオプションは明示的なプロファイル設定を保持する。
        XCTAssertFalse(disabledOptions.halfWidthKanaCandidate)
        XCTAssertTrue(enabledOptions.halfWidthKanaCandidate)
    }

    func testNormalizeProfileEnablesMissingHalfwidthKatakanaSetting() throws {
        // 前提: 半角カタカナのoptionalフィールドがない旧プロファイル。
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.specialConversionMode.clearHalfwidthKatakana()

        // 実行: 設定境界を通過させる。
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // 検証: 既定の有効値が明示される。
        XCTAssertTrue(normalized.specialConversionMode.hasHalfwidthKatakana)
        XCTAssertTrue(normalized.specialConversionMode.halfwidthKatakana)
    }

    func testNormalizeProfileRejectsUnknownEnumAndInvalidNumericValues() {
        // 前提: サーバが安全に解釈できない値を含むプロファイル。
        var unknownEnum = HazkeyServerConfig.genDefaultConfig()
        unknownEnum.autoConvertMode = .UNRECOGNIZED(99)
        var invalidNumber = HazkeyServerConfig.genDefaultConfig()
        invalidNumber.zenzaiInferLimit = 101

        // 実行・検証: 永続化前に検証で両方を拒否する。
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfile(unknownEnum))
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfile(invalidNumber))
    }

    func testNormalizeProfileAcceptsNumericBoundsAndRejectsEmptyProfiles() throws {
        // 前提: UIの両端を含む数値上限・下限を使うプロファイル。
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

        // 実行: 有効な境界値プロファイルを正規化する。
        let normalized = try HazkeyServerConfig.normalizeProfiles([minimum, maximum])

        // 検証: 両方の値を保持し、空のSetConfigリストは拒否する。
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(try XCTUnwrap(normalized.first).numSuggestions, 1)
        XCTAssertEqual(try XCTUnwrap(normalized.last).zenzaiInferLimit, 100)
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfiles([]))
    }

    func testCustomKeymapParserSkipsMalformedRowsAndLoadsValidRows() {
        // 前提: 有効な規則に混在する空行、タブだけの行、不完全な行、列数過多の行。
        let contents = "\n\t\nA\tあ\nB\tい\t\nC\tう\textra\tignored\nD\nE\t\n"

        // 実行: カスタムキーマップをパースする。
        let keymap = HazkeyServerConfig.parseCustomKeymap(contents)

        // 検証: 不正な行は無視し、有効な規則の読み込みは妨げない。
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
        // 前提: カスタム重みを有効にし、有効・無効両方のパスを持つプロファイル。
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

        // 実行: カスタムパスを有効なものから欠落したパスへ変更する。
        let resolvedCustom = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)
        profile.zenzaiWeightPath = directory.appendingPathComponent("missing.gguf").path
        let resolvedMissing = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)

        // 検証: 有効なカスタムモデルを優先し、無効な明示パスではZenzaiを無効にする。
        XCTAssertEqual(resolvedCustom, customModel)
        XCTAssertNil(resolvedMissing)
    }

    func testZenzaiModelResolverUsesDiscoveryWhenCustomWeightIsDisabledOrEmpty() throws {
        // 前提: 利用可能な検出済みモデルと、有効なカスタムパスを持たないプロファイル。
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

        // 実行: カスタム重みを無効化し、次に空のパスで有効化する。
        let disabledResolution = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)
        profile.useZenzaiCustomWeight = true
        profile.zenzaiWeightPath = ""
        let emptyResolution = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discoveredModel)

        // 検証: どちらの場合も通常のモデル検出を維持する。
        XCTAssertEqual(disabledResolution, discoveredModel)
        XCTAssertEqual(emptyResolution, discoveredModel)
    }

    func testManagedZenzaiSymlinkToJinenModelIsAcceptedByResolver() throws {
        // 前提: jinenキーのGGUFを指す管理下の<dataDir>/hazkey-community/zenzai/zenzai.ggufシンボリックリンク。
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

        // 実行: サンドボックス化したデータディレクトリで検出を行い、その結果をresolverへ渡す。
        let discovered = getZenzaiModelPath()
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useZenzaiCustomWeight = false
        let resolved = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: discovered)

        // 検証: 管理下のシンボリックリンクを検出・受理し、jinenの対象を指す。
        XCTAssertEqual(discovered, managedSymlink)
        XCTAssertEqual(resolved, managedSymlink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: try XCTUnwrap(resolved).path),
            jinenModel.path)
    }

    func testReloadZenzaiModelReResolvesRetargetedManagedSymlink() throws {
        // 前提: 稼働中の設定が読み込んだ、最初は1つのjinenキーを指す管理下のシンボリックリンク。
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

        // 実行: シンボリックリンクの対象を別のjinenキーへ変え、モデルを再読み込みする。
        try FileManager.default.removeItem(at: managedSymlink)
        try FileManager.default.createSymbolicLink(
            at: managedSymlink, withDestinationURL: secondJinenModel)
        config.reloadZenzaiModel()

        // 検証: キャッシュ済みの旧対象ではなく、新しい対象を返す。
        XCTAssertEqual(config.zenzaiModelPath, managedSymlink)
        XCTAssertEqual(
            config.zenzaiModelPath?.resolvingSymlinksInPath(),
            secondJinenModel.resolvingSymlinksInPath())
        XCTAssertNotEqual(
            config.zenzaiModelPath?.resolvingSymlinksInPath(),
            firstJinenModel.resolvingSymlinksInPath())
    }

    /// converterは重みパス文字列をキーにしたプロセス全体のレジストリ
    /// (`SharedZenzModelCache.cacheKey(path:deviceConfig:)`) で読み込み済みモデルを
    /// キャッシュする。そのため渡すパスは固定の管理下シンボリックリンクではなく、
    /// 解決済みアーティファクトでなければならない。この解決前は
    /// `reload_zenzai_model` を実行しても、サーバ再起動までSettingsのモデル切替が
    /// 既に読み込まれた重みを使い続けていた。
    func testGenZenzaiModeHandsOverResolvedModelPathSoModelSwitchTakesEffect() throws {
        // 前提: 1つのjinenアーティファクトを指す管理下のシンボリックリンク。
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

        // configは管理下のシンボリックリンクを返し続け、解決するのはconverter入力だけ。
        XCTAssertEqual(config.zenzaiModelPath, managedSymlink)

        let beforeSwitch = config.genZenzaiMode(leftContext: "")
        XCTAssertNotEqual(beforeSwitch, .off, "Zenzai must be available for this check")
        let beforeWeight = try XCTUnwrap(
            Self.zenzaiWeightURL(of: beforeSwitch), "ZenzaiMode must carry a weight URL")
        XCTAssertEqual(
            beforeWeight.resolvingSymlinksInPath(), firstJinenModel.resolvingSymlinksInPath())
        XCTAssertNotEqual(beforeWeight, managedSymlink)

        // 対象を変えない再読み込みはモードを変えてはならない。そのため下記で確認する差分は
        // モデルパス自体にしか由来しない。
        config.reloadZenzaiModel()
        XCTAssertEqual(config.genZenzaiMode(leftContext: ""), beforeSwitch)

        // 実行: シンボリックリンクの対象を変更（モデル切替）して再読み込みする。
        try FileManager.default.removeItem(at: managedSymlink)
        try FileManager.default.createSymbolicLink(
            at: managedSymlink, withDestinationURL: secondJinenModel)
        config.reloadZenzaiModel()
        let afterSwitch = config.genZenzaiMode(leftContext: "")

        // 検証: converterへ渡すパスが変わるためキャッシュキーも変わり、古いものではなく
        // 新しく選んだアーティファクトを読み込む。
        let afterWeight = try XCTUnwrap(
            Self.zenzaiWeightURL(of: afterSwitch), "ZenzaiMode must carry a weight URL")
        XCTAssertEqual(
            afterWeight.resolvingSymlinksInPath(), secondJinenModel.resolvingSymlinksInPath())
        XCTAssertNotEqual(afterWeight, managedSymlink)
        XCTAssertNotEqual(afterSwitch, beforeSwitch)
    }

    /// converterモジュール内で非公開の `ConvertRequestOptions.ZenzaiMode.weightURL` を読む。
    /// このスイートでは渡された値の観測だけが必要である。
    private static func zenzaiWeightURL<T>(of mode: T) -> URL? {
        Mirror(reflecting: mode).children.first { $0.label == "weightURL" }?.value as? URL
    }

    func testZenzaiModelResolverRejectsDirectoryCustomWeight() throws {
        // 前提: ディレクトリとディレクトリへのシンボリックリンクをカスタム重みに指定する。
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

        // 実行: 明示カスタムパスがどちらの形式でも通常ファイルではない。
        profile.zenzaiWeightPath = weightDirectory.path
        let resolvedDirectory = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: nil)
        profile.zenzaiWeightPath = directorySymlink.path
        let resolvedDirectorySymlink = HazkeyServerConfig.resolveZenzaiModelPath(
            for: profile, discoveredModelPath: nil)

        // 検証: どちらも欠落したカスタムパスと同じく拒否する（nil、Zenzai無効）。
        XCTAssertNil(resolvedDirectory)
        XCTAssertNil(resolvedDirectorySymlink)
    }

    func testProfileHistoryDirectoryIsSharedUnlessIsolationIsEnabled() {
        // 前提: パス要素として直接使えない識別子を持つプロファイル。
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.profileID = "work/team"
        let stateDirectory = URL(fileURLWithPath: "/tmp/hazkey-state")

        // 実行: 履歴分離を無効化し、次に有効化する。
        profile.useProfileIndependentHistory = false
        let sharedDirectory = HazkeyServerConfig.memoryDirectory(for: profile, stateDirectory: stateDirectory)
        profile.useProfileIndependentHistory = true
        let isolatedDirectory = HazkeyServerConfig.memoryDirectory(for: profile, stateDirectory: stateDirectory)

        // 検証: 共有履歴は既存の場所を保ち、分離履歴には安全なパス要素が1つ付く。
        XCTAssertEqual(sharedDirectory, stateDirectory.appendingPathComponent("memory", isDirectory: true))
        XCTAssertEqual(isolatedDirectory.deletingLastPathComponent(), sharedDirectory)
        XCTAssertFalse(isolatedDirectory.lastPathComponent.contains("/"))
        XCTAssertNotEqual(isolatedDirectory, sharedDirectory)
    }

    func testRichCandidateSelectionUsesTheRequestKind() {
        // 前提: リッチサジェストとリッチ候補を独立して有効化した設定。
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useRichSuggestion = true
        profile.useRichCandidates = false

        // 実行: サジェスト要求と手動変換要求に対するオプションを選ぶ。
        let suggestionValue = HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: true)
        let conversionValue = HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: false)

        // 検証: 各要求は対応する設定だけを読む。
        XCTAssertTrue(suggestionValue)
        XCTAssertFalse(conversionValue)

        profile.useRichSuggestion = false
        profile.useRichCandidates = true
        XCTAssertFalse(HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: true))
        XCTAssertTrue(HazkeyServerConfig.requestRichCandidates(for: profile, isSuggestion: false))
    }

    // MARK: - [community] Emoji 17直接変換（テスト先行、RED）

    func testDefaultExtendedEmojiIsEnabled() {
        // ファクトリ既定値では拡張絵文字変換を有効に保つ。
        XCTAssertTrue(HazkeyServerConfig.genDefaultConfig().specialConversionMode.extendedEmoji)
        XCTAssertTrue(HazkeyServerConfig.genDefaultConfig().extendedEmojiEffective)
    }

    func testAbsentExtendedEmojiNormalizesToEnabled() throws {
        // 前提: extended_emojiのoptionalがない旧プロファイル。
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.specialConversionMode.clearExtendedEmoji()
        XCTAssertFalse(profile.specialConversionMode.hasExtendedEmoji)

        // 実行: 設定境界を通過させる。
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // 検証: 有効な既定値が明示される。
        XCTAssertTrue(normalized.specialConversionMode.hasExtendedEmoji)
        XCTAssertTrue(normalized.specialConversionMode.extendedEmoji)
        XCTAssertTrue(normalized.extendedEmojiEffective)
    }

    func testExplicitFalseExtendedEmojiIsPreserved() throws {
        // 前提: 拡張絵文字を明示的に無効化するプロファイル。
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.specialConversionMode.extendedEmoji = false

        // 実行: 設定境界を通過させる。
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // 検証: 明示的な無効化は正規化後も保持される。
        XCTAssertTrue(normalized.specialConversionMode.hasExtendedEmoji)
        XCTAssertFalse(normalized.specialConversionMode.extendedEmoji)
        XCTAssertFalse(normalized.extendedEmojiEffective)
    }

    func testNormalizeProfileDefaultsMissingAddressDictionaryAndPreservesExplicitFalse() throws {
        // 前提: 住所辞書フィールドがない旧プロファイルと、明示的に無効化するプロファイル。
        var missing = HazkeyServerConfig.genDefaultConfig()
        missing.clearUseAddressDictionary()
        XCTAssertFalse(missing.hasUseAddressDictionary)
        var disabled = HazkeyServerConfig.genDefaultConfig()
        disabled.useAddressDictionary = false

        // 実行: それぞれを設定境界へ通す。
        let normalizedMissing = try HazkeyServerConfig.normalizeProfile(missing)
        let normalizedDisabled = try HazkeyServerConfig.normalizeProfile(disabled)

        // 検証: 欠落フィールドは無効が既定となり、明示的な無効化は保持される。
        XCTAssertTrue(normalizedMissing.hasUseAddressDictionary)
        XCTAssertFalse(normalizedMissing.useAddressDictionary)
        XCTAssertFalse(normalizedMissing.useAddressDictionaryEffective)
        XCTAssertTrue(normalizedDisabled.hasUseAddressDictionary)
        XCTAssertFalse(normalizedDisabled.useAddressDictionary)
        XCTAssertFalse(normalizedDisabled.useAddressDictionaryEffective)
    }

    func testNormalizeProfileDefaultsMissingEngineeringDictionaryAndPreservesExplicitTrue() throws {
        // 前提: 工学用語辞書フィールドがない旧プロファイルと、明示的に有効化するプロファイル。
        var missing = HazkeyServerConfig.genDefaultConfig()
        missing.clearUseEngineeringDictionary()
        XCTAssertFalse(missing.hasUseEngineeringDictionary)
        XCTAssertFalse(missing.useEngineeringDictionaryEffective)
        var enabled = HazkeyServerConfig.genDefaultConfig()
        enabled.useEngineeringDictionary = true

        // 実行: それぞれを設定境界へ通す。
        let normalizedMissing = try HazkeyServerConfig.normalizeProfile(missing)
        let normalizedEnabled = try HazkeyServerConfig.normalizeProfile(enabled)

        // 検証: 欠落フィールドは無効が既定となり、明示的な有効化は保持される。
        XCTAssertTrue(normalizedMissing.hasUseEngineeringDictionary)
        XCTAssertFalse(normalizedMissing.useEngineeringDictionary)
        XCTAssertFalse(normalizedMissing.useEngineeringDictionaryEffective)
        XCTAssertTrue(normalizedEnabled.useEngineeringDictionary)
        XCTAssertTrue(normalizedEnabled.useEngineeringDictionaryEffective)
    }
}

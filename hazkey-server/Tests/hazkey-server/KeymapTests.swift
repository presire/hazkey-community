import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 従来の全角記号キーマップと分割したキーマップの互換性を検証する
///
/// ローマ字入力での記号の組成と、有効リストの前方を優先する合成を確認する
final class KeymapTests: XCTestCase {
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case environmentUpdateFailed(String)
    }

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        temporaryDirectory = root
        let directories = [
            "XDG_CONFIG_HOME": "config",
            "XDG_DATA_HOME": "data",
            "XDG_STATE_HOME": "state",
            "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime",
        ]
        var values: [String: String] = [:]
        for (variable, directory) in directories {
            let path = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            values[variable] = path.path
        }
        values["HAZKEY_DICTIONARY"] = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true).path
        originalEnvironment = Dictionary(
            uniqueKeysWithValues: values.keys.map {
                ($0, ProcessInfo.processInfo.environment[$0])
            })
        for (variable, value) in values {
            guard setenv(variable, value, 1) == 0 else {
                throw SetupError.environmentUpdateFailed(variable)
            }
        }
    }

    override func tearDownWithError() throws {
        for (variable, value) in originalEnvironment {
            if let value {
                XCTAssertEqual(setenv(variable, value, 1), 0, "Failed to restore \(variable)")
            } else {
                XCTAssertEqual(unsetenv(variable), 0, "Failed to unset \(variable)")
            }
        }
        originalEnvironment.removeAll()
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testFullwidthSymbolMapCoversBracesAndQuotes() {
        // 前提: 組み込みの全角記号テーブル

        // 実行・確認: 波括弧と引用符が全角形式に対応付けられる
        XCTAssertEqual(fullwidthSymbolMap["{"]?.0, "｛")
        XCTAssertEqual(fullwidthSymbolMap["}"]?.0, "｝")
        XCTAssertEqual(fullwidthSymbolMap["\""]?.0, "＂")
        XCTAssertEqual(fullwidthSymbolMap["'"]?.0, "＇")
    }

    func testBraceAndQuoteInputComposesFullwidth() {
        // 前提: 新しい組成
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)

        // 実行: 両フロントエンドから渡される形式で、波括弧と引用符のキーを入力する
        for character in ["{", "}", "\"", "'"] {
            XCTAssertEqual(state.inputChar(inputString: character).status, .success)
        }

        // 期待: 組成には半角のまま通過した文字ではなく、全角記号が含まれる
        XCTAssertEqual(state.composingText.value.convertTarget, "｛｝＂＇")
    }

    func testFullwidthBasicSymbolMapHasExactContents() {
        assertKeymap(fullwidthBasicSymbolMap, matches: [
            "!": "！",
            "#": "＃",
            "$": "＄",
            "%": "％",
            "&": "＆",
            "@": "＠",
            "*": "＊",
            ":": "：",
            ";": "；",
            "?": "？",
            "^": "＾",
            "<": "＜",
            ">": "＞",
            "=": "＝",
            "+": "＋",
            "_": "＿",
            "~": "\u{301C}",
            "|": "｜",
        ])
    }

    func testFullwidthQuotationMapHasExactContents() {
        assertKeymap(fullwidthQuotationMap, matches: [
            "\"": "\u{FF02}",
            "'": "\u{FF07}",
            "`": "\u{FF40}",
        ])
    }

    func testTypographicQuotationMapHasExactContents() {
        assertKeymap(typographicQuotationMap, matches: [
            "\"": "\u{201D}",
            "'": "\u{2019}",
            "`": "\u{2018}",
        ])
    }

    func testJapaneseBracketMapHasExactContents() {
        assertKeymap(japaneseBracketMap, matches: [
            "(": "（",
            ")": "）",
            "[": "「",
            "]": "」",
            "{": "｛",
            "}": "｝",
        ])
    }

    func testFullwidthBracketMapHasExactContents() {
        assertKeymap(fullwidthBracketMap, matches: [
            "(": "（",
            ")": "）",
            "[": "\u{FF3B}",
            "]": "\u{FF3D}",
            "{": "｛",
            "}": "｝",
        ])
    }

    func testHalfwidthBracketMapHasExactContents() {
        assertKeymap(halfwidthBracketMap, matches: [
            "(": "(",
            ")": ")",
            "[": "[",
            "]": "]",
            "{": "{",
            "}": "}",
        ])
    }

    func testFullwidthBasicSymbolMapMatchesFilteredLegacyMap() {
        let excludedKeys: Set<Character> = ["(", ")", "{", "}", "\"", "'", "`"]
        let expected = fullwidthSymbolMap.filter { !excludedKeys.contains($0.key) }
            .mapValues { String($0.0) }

        XCTAssertEqual(fullwidthBasicSymbolMap.mapValues { String($0.0) }, expected)
    }

    func testBuiltInKeymapsAppendSplitMapsAfterLegacyNames() {
        let expectedNames = [
            "JIS Kana", "Japanese Symbol", "Fullwidth Period", "Fullwidth Comma",
            "Fullwidth Symbol", "Fullwidth Number", "Fullwidth Space",
            "Fullwidth Basic Symbol", "Fullwidth Quotation", "Typographic Quotation",
            "Japanese Bracket", "Fullwidth Bracket", "Halfwidth Bracket",
        ]

        XCTAssertEqual(builtInKeymaps.map(\.name), expectedNames)
        XCTAssertEqual(builtInKeymaps.map(\.filename), expectedNames)
        XCTAssertTrue(builtInKeymaps.allSatisfy { $0.isBuiltIn })
    }

    func testLoadKeymapResolvesEveryNewBuiltIn() {
        let config = HazkeyServerConfig()
        let maps: [(String, Keymap)] = [
            ("Fullwidth Basic Symbol", fullwidthBasicSymbolMap),
            ("Fullwidth Quotation", fullwidthQuotationMap),
            ("Typographic Quotation", typographicQuotationMap),
            ("Japanese Bracket", japaneseBracketMap),
            ("Fullwidth Bracket", fullwidthBracketMap),
            ("Halfwidth Bracket", halfwidthBracketMap),
        ]
        for (name, map) in maps {
            config.currentProfile.enabledKeymaps = enabledKeymaps(named: [name])

            assertKeymap(config.loadKeymap(), matches: map.mapValues { $0.0 })
        }
    }

    func testDefaultProfileUsesSplitKeymapsInBasicTabOrder() {
        let profile = HazkeyServerConfig.genDefaultConfig()
        let expectedNames = [
            "Fullwidth Number", "Fullwidth Basic Symbol", "Fullwidth Quotation",
            "Japanese Bracket", "Fullwidth Space", "Japanese Symbol",
        ]

        XCTAssertEqual(profile.enabledKeymaps.map(\.name), expectedNames)
        XCTAssertEqual(profile.enabledKeymaps.map(\.filename), expectedNames)
        XCTAssertTrue(profile.enabledKeymaps.allSatisfy { $0.isBuiltIn })
    }

    func testDefaultProfileKeymapMatchesLegacyForEveryPrintableASCIICharacter() throws {
        let config = HazkeyServerConfig()
        config.currentProfile = HazkeyServerConfig.genDefaultConfig()
        let currentMap = config.loadKeymap()
        config.currentProfile.enabledKeymaps = enabledKeymaps(named: [
            "Fullwidth Number", "Fullwidth Symbol", "Japanese Symbol", "Fullwidth Space",
        ])
        let legacyMap = config.loadKeymap()

        for value in UInt32(0x20)...UInt32(0x7E) {
            let character = Character(String(try XCTUnwrap(UnicodeScalar(value))))
            XCTAssertEqual(currentMap[character]?.0, legacyMap[character]?.0,
                "Intention differs for ASCII \(value)")
            XCTAssertEqual(currentMap[character]?.1, legacyMap[character]?.1,
                "Override differs for ASCII \(value)")
        }
    }

    func testHalfwidthBracketInputCancelsJapaneseSymbolMapping() {
        assertComposition("()[]{}",
            enabledKeymaps: ["Halfwidth Bracket", "Japanese Symbol"], equals: "()[]{}")
    }

    func testFullwidthBracketInputOverridesJapaneseSymbolMapping() {
        assertComposition("()[]{}",
            enabledKeymaps: ["Fullwidth Bracket", "Japanese Symbol"], equals: "（）［］｛｝")
    }

    func testJapaneseBracketInputComposesJapaneseBrackets() {
        assertComposition("()[]{}",
            enabledKeymaps: ["Japanese Bracket", "Japanese Symbol"], equals: "（）「」｛｝")
    }

    func testTypographicQuotationInputComposesFixedQuotations() {
        assertComposition("\"'`",
            enabledKeymaps: ["Typographic Quotation", "Japanese Symbol"], equals: "”’‘")
    }

    func testFullwidthQuotationInputComposesFullwidthQuotations() {
        assertComposition("\"'`",
            enabledKeymaps: ["Fullwidth Quotation", "Japanese Symbol"], equals: "＂＇｀")
    }

    func testQuotationInputWithoutQuotationMapStaysASCII() {
        assertComposition("\"'`", enabledKeymaps: ["Japanese Symbol"], equals: "\"'`")
    }

    func testTypographicClosingQuoteOffersOpeningQuoteCandidate() {
        // 前提: 組版の引用符で"を入力し、閉じ引用符”が組成されている
        let state = HazkeyServerState()
        defer { state.close() }
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.enabledKeymaps = enabledKeymaps(named: ["Typographic Quotation", "Japanese Symbol"])
        profile.zenzaiEnable = false
        state.serverConfig.currentProfile = profile
        state.reinitializeConfiguration()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        XCTAssertEqual(state.inputChar(inputString: "\"").status, .success)

        // 実行: 通常変換の候補を要求する
        let response = state.getCandidates(is_suggest: false)

        // 確認: 開き引用符“を変換候補から選べる
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        let texts = result.candidates.map(\.text)
        XCTAssertTrue(texts.contains("“"), "Opening quote missing: \(texts)")
    }

    func testTypographicQuotationInputResolvesPendingRomajiN() {
        assertComposition("n'",
            enabledKeymaps: ["Typographic Quotation", "Japanese Symbol"], equals: "ん’")
    }

    func testHalfwidthBracketInputTakesPriorityOverLegacyFullwidthSymbol() {
        assertComposition("([{",
            enabledKeymaps: ["Halfwidth Bracket", "Fullwidth Symbol", "Japanese Symbol"],
            equals: "([{")
    }

    private func assertKeymap(
        _ actual: Keymap, matches expected: [Character: Character],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
        for (key, value) in expected {
            XCTAssertEqual(actual[key]?.0, value, "Intention differs for \(key)",
                file: file, line: line)
            XCTAssertNil(actual[key]?.1, "Unexpected override for \(key)",
                file: file, line: line)
        }
    }

    private func enabledKeymaps(named names: [String]) -> [Hazkey_Config_Profile.EnabledKeymap] {
        names.map { name in
            Hazkey_Config_Profile.EnabledKeymap.with {
                $0.name = name
                $0.isBuiltIn = true
                $0.filename = name
            }
        }
    }

    private func assertComposition(
        _ input: String, enabledKeymaps names: [String], equals expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let state = HazkeyServerState()
        defer { state.close() }
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.enabledKeymaps = enabledKeymaps(named: names)
        profile.zenzaiEnable = false
        state.serverConfig.currentProfile = profile
        state.reinitializeConfiguration()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success, file: file, line: line)

        for character in input {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success,
                file: file, line: line)
        }

        XCTAssertEqual(state.composingText.value.convertTarget, expected, file: file, line: line)
    }
}

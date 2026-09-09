import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// Coverage for Emoji 17.0 direct conversion.
///
/// Plan: `.omo/plans/emoji-17-direct-conversion.md`. Emoji candidates carry
/// the matched normalized-query length and complete via `prefixComplete`,
/// retaining any unconsumed suffix without learning.
///
/// Fixture policy: every dictionary URL is a temporary file created in
/// `setUpWithError`. No test reads the system install path
/// (`systemResourcePath/emoji_all_E17.0.txt`); the default-URL test only
/// asserts the filename, never its contents.
final class Emoji17DirectConversionTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case setFailed(String)
        case missingPath(String)
    }

    // E17-only sentinel: とろんぼーん -> trombone 🪊 exists in
    // emoji_all_E17.0.txt and is absent from emoji_all_E16.0.txt.
    private static let sentinelReading = "とろんぼーん"
    private static let sentinelEmoji = "🪊"
    // ZWJ sequence (ballet dancer) and VS16 sequence (☺️) for preservation tests.
    private static let zwjReading = "ばれえ"
    private static let zwjEmoji = "🧑‍🩰"
    private static let vs16Emoji = "☺️"

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-emoji17-\(UUID().uuidString)", isDirectory: true)
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey"), withIntermediateDirectories: true)

        let paths = [
            "XDG_DATA_HOME": "data",
            "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime",
            "XDG_STATE_HOME": "state",
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            if variable == "HAZKEY_DICTIONARY" {
                let dictionaryPath = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
                guard setenv(variable, dictionaryPath.path, 1) == 0 else {
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

    // MARK: - Fixture helpers (temporary URLs only)

    private func writeFixture(_ contents: String, named name: String = "emoji_fixture.txt") throws -> URL {
        let root = try XCTUnwrap(temporaryDirectory)
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func validFixtureURL() throws -> URL {
        // Same TSV shape as emoji_all_E*.txt: emoji TAB comma-separated readings.
        let contents = [
            "\(Self.sentinelEmoji)\t\(Self.sentinelReading),とろんぼーんのえもじ\t",
            "\(Self.zwjEmoji)\t\(Self.zwjReading),ばれえだんさー\t",
            "\(Self.vs16Emoji)\tにっこりほほえみ\t",
        ].joined(separator: "\n") + "\n"
        return try writeFixture(contents)
    }

    private func makeState(fixtureURL: URL?, extendedEmoji: Bool = true) throws -> HazkeyServerState {
        let state = HazkeyServerState(emojiDictionaryURL: fixtureURL)
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.specialConversionMode.extendedEmoji = extendedEmoji
        state.serverConfig.currentProfile.numCandidatesPerPage = 9
        state.serverConfig.currentProfile.numSuggestions = 9
        return state
    }

    private func candidateResult(
        forReading reading: String,
        isSuggest: Bool,
        fixtureURL: URL?,
        extendedEmoji: Bool = true
    ) throws -> Hazkey_Commands_CandidatesResult {
        let state = try makeState(fixtureURL: fixtureURL, extendedEmoji: extendedEmoji)
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return Hazkey_Commands_CandidatesResult()
        }
        return result
    }

    // MARK: - E17 normal-only behavior

    func testE17SentinelAppearsInNormalConversion() throws {
        // Given: an E17 fixture containing the E17-only sentinel reading.
        let fixture = try validFixtureURL()

        // When: converting the sentinel reading as a normal conversion.
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false, fixtureURL: fixture)

        // Then: the E17 emoji surfaces as a direct candidate.
        XCTAssertTrue(
            result.candidates.map(\.text).contains(Self.sentinelEmoji),
            "E17 sentinel emoji missing: \(result.candidates.map(\.text))")
    }

    func testE17SentinelAbsentInSuggestion() throws {
        // Given: the same E17 fixture.
        let fixture = try validFixtureURL()

        // When: requesting suggestions for the sentinel reading.
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: true, fixtureURL: fixture)

        // Then: suggestion/live conversion never carries emoji candidates.
        XCTAssertFalse(
            result.candidates.map(\.text).contains(Self.sentinelEmoji),
            "Emoji must not leak into suggestion results")
    }

    // MARK: - Enabled/disabled setting

    func testDisabledExtendedEmojiSuppressesCandidates() throws {
        // Given: a valid fixture but the setting explicitly disabled.
        let fixture = try validFixtureURL()

        // When: converting with extendedEmoji = false.
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false,
            fixtureURL: fixture, extendedEmoji: false)

        // Then: no emoji candidate is injected.
        XCTAssertFalse(
            result.candidates.map(\.text).contains(Self.sentinelEmoji))
    }

    // MARK: - Exact dedupe

    func testExactDuplicateEmojiAppearsOnce() throws {
        // Given: a fixture mapping the same reading to the same emoji twice.
        // Reading is pure hiragana: `TextReplacer` indexes raw queries but
        // searches via `lowercased().toHiragana()`, so katakana never matches;
        // and `inputChar` routes ASCII through the romaji table, so ASCII in
        // the reading would not round-trip through `toHiragana()` either.
        let contents = "✅\tぴよぴよえもじ\t\n✅\tぴよぴよえもじ\t\n"
        let fixture = try writeFixture(contents)

        // When: converting that reading.
        let result = try candidateResult(
            forReading: "ぴよぴよえもじ", isSuggest: false, fixtureURL: fixture)

        // Then: exact-string dedupe keeps a single entry.
        XCTAssertEqual(result.candidates.map(\.text).filter { $0 == "✅" }.count, 1)
    }

    // MARK: - ZWJ / VS16 preservation

    func testZWJSequencePreservedByteForByte() throws {
        // Given: a fixture with a ZWJ ballet-dancer sequence.
        let fixture = try validFixtureURL()

        // When: converting its reading.
        let result = try candidateResult(
            forReading: Self.zwjReading, isSuggest: false, fixtureURL: fixture)

        // Then: the ZWJ bytes survive unnormalized.
        let match = result.candidates.map(\.text).first { $0 == Self.zwjEmoji }
        XCTAssertNotNil(match, "ZWJ emoji missing: \(result.candidates.map(\.text))")
        XCTAssertTrue(match?.unicodeScalars.contains(Unicode.Scalar(0x200D)!) ?? false)
        XCTAssertEqual(match, Self.zwjEmoji)
    }

    func testVS16PreservedByteForByte() throws {
        // Given: a fixture with a VS16 sequence.
        let fixture = try validFixtureURL()

        // When: converting its reading.
        let result = try candidateResult(
            forReading: "にっこりほほえみ", isSuggest: false, fixtureURL: fixture)

        // Then: the variation selector survives unnormalized.
        let match = result.candidates.map(\.text).first { $0 == Self.vs16Emoji }
        XCTAssertNotNil(match, "VS16 emoji missing: \(result.candidates.map(\.text))")
        XCTAssertTrue(match?.unicodeScalars.contains(Unicode.Scalar(0xFE0F)!) ?? false)
        XCTAssertEqual(match, Self.vs16Emoji)
    }

    // MARK: - Unchanged live text

    func testLiveTextUnchangedByEmojiInjection() throws {
        // Given: the same reading with emoji disabled (baseline).
        let fixture = try validFixtureURL()
        let baseline = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false,
            fixtureURL: fixture, extendedEmoji: false)

        // When: emoji injection is enabled.
        let injected = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false,
            fixtureURL: fixture, extendedEmoji: true)

        // Then: liveText/liveTextIndex are untouched by the post-process.
        XCTAssertEqual(injected.liveText, baseline.liveText)
        XCTAssertEqual(injected.liveTextIndex, baseline.liveTextIndex)
    }

    // MARK: - Prefix completion

    func testPrefixCompletionClearsComposingForEmoji() throws {
        // Given: a normal conversion with an emoji candidate listed for the
        // exact reading (no trailing suffix).
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in Self.sentinelReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        let index = try XCTUnwrap(state.currentCandidateList?.firstIndex(where: {
            if case .fromEmoji(let word, _) = $0 { return word == Self.sentinelEmoji }
            return false
        }))

        // When: the emoji candidate is prefix-completed.
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

        // Then: the exact reading is fully consumed (composing text cleared)
        // without failure and without learning.
        XCTAssertEqual(state.composingText.value.toHiragana(), "")
        XCTAssertFalse(state.learningDataNeedsCommit)
    }

    func testPrefixCompletionRetainsSuffixForEmoji() throws {
        // Given: an emoji reading followed by a suffix, with the cursor at
        // the end of the reading so the request covers only the prefix.
        let suffix = "きょう"
        let fullReading = Self.sentinelReading + suffix
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in fullReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.moveCursor(offset: -suffix.count).status, .success)
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        let index = try XCTUnwrap(state.currentCandidateList?.firstIndex(where: {
            if case .fromEmoji(let word, _) = $0 { return word == Self.sentinelEmoji }
            return false
        }))

        // Then: the candidate carries the unconsumed suffix as remaining preedit.
        XCTAssertEqual(result.candidates[index].subHiragana, suffix)

        // When: the emoji candidate is prefix-completed.
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

        // Then: only the matched prefix is consumed; the suffix remains
        // intact and nothing is learned.
        XCTAssertEqual(state.composingText.value.toHiragana(), suffix)
        XCTAssertFalse(state.learningDataNeedsCommit)
    }

    // MARK: - Non-learning behavior

    func testEmojiCandidatesAreNotLearned() throws {
        // Given: a listed emoji candidate.
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in Self.sentinelReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        let index = try XCTUnwrap(state.currentCandidateList?.firstIndex(where: {
            if case .fromEmoji(let word, _) = $0 { return word == Self.sentinelEmoji }
            return false
        }))

        // Then: no deletable annotation is attached.
        XCTAssertFalse(result.candidates[index].hasLearningEntry_p)

        // When: the emoji is completed and its learning data is deleted.
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
        XCTAssertFalse(state.learningDataNeedsCommit)
        let deleteResponse = state.deleteCandidateLearningData(candidateIndex: index)

        // Then: deletion reports nothing deleted (non-converter case).
        XCTAssertEqual(deleteResponse.status, .success)
        XCTAssertEqual(deleteResponse.deleteCandidateLearningDataResult.deletedCount, 0)
    }

    // MARK: - Cached construction

    func testEmojiProviderIsCachedAcrossRequests() throws {
        // Given: a state bound to a valid fixture.
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in Self.sentinelReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }

        // When: candidates are requested twice without recomposition.
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        let first = try XCTUnwrap(state.emojiProvider)
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        let second = try XCTUnwrap(state.emojiProvider)

        // Then: the cached provider instance is reused (no per-request parse).
        XCTAssertTrue(first === second)
    }

    func testProviderSearchIsDirectAndUnchanged() throws {
        // Given: a provider built from a temporary fixture.
        let fixture = try validFixtureURL()
        let provider = try XCTUnwrap(EmojiCandidateProvider(dictionaryURL: fixture))

        // When: searching the sentinel reading.
        let hits = provider.emojiCandidates(for: Self.sentinelReading)

        // Then: the emoji text is returned unchanged with the matched
        // normalized-query length retained for prefix completion.
        let match = hits.first(where: { $0.text == Self.sentinelEmoji })
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.query.count, Self.sentinelReading.count)
    }

    // MARK: - Missing / malformed fallback

    func testMissingAssetFallsBackToNormalConversion() throws {
        // Given: a dictionary URL that does not exist.
        let root = try XCTUnwrap(temporaryDirectory)
        let missing = root.appendingPathComponent("does-not-exist.txt")

        // When: converting with the missing asset.
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false, fixtureURL: missing)

        // Then: normal conversion still succeeds with no injected emoji.
        XCTAssertFalse(result.candidates.map(\.text).contains(Self.sentinelEmoji))
    }

    func testMalformedAssetFallsBackToNormalConversion() throws {
        // Given: an unreadable-as-emoji-dictionary fixture.
        let fixture = try writeFixture("this is not\ta valid emoji file\u{0}\u{FF}\n")

        // When: converting with the malformed asset.
        let provider = EmojiCandidateProvider(dictionaryURL: fixture)
        XCTAssertNil(provider)
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false, fixtureURL: fixture)

        // Then: normal conversion still succeeds with no injected emoji.
        XCTAssertFalse(result.candidates.map(\.text).contains(Self.sentinelEmoji))
    }

    func testDefaultDictionaryURLPointsAtE17Asset() {
        // The default provider URL must be the E17 asset; contents are never
        // read from the system path in tests.
        XCTAssertEqual(
            EmojiCandidateProvider.defaultDictionaryURL.lastPathComponent,
            "emoji_all_E17.0.txt")
    }

    // MARK: - Converter prediction stays disabled

    func testBaseConvertOptionsKeepTextReplacerEmpty() {
        // Direct injection is deliberate: converter post-composition
        // prediction must stay out of scope. An empty replacer answers no
        // emoji query (public seam; `isEmpty` itself is internal to the
        // converter package and not visible even via @testable).
        let config = HazkeyServerConfig()
        let options = config.genBaseConvertRequestOptions()
        XCTAssertTrue(
            options.textReplacer.getSearchResult(query: Self.sentinelReading, target: [.emoji]).isEmpty,
            "ConvertRequestOptions.textReplacer must remain .empty")
    }
}

import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 郵便番号変換のサーバ状態を通したテスト
///
/// 環境変数[HAZKEY_POSTAL_CODE_DICTIONARY]で小さなTSVを指し、候補の並び・確定・学習・先読み・縮退を検証する
final class PostalCodeServerTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
        "HAZKEY_POSTAL_CODE_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?
    private var fixtureURL: URL?

    private enum SetupError: Error {
        case setFailed(String)
    }

    /// 町域が1件の番号の住所
    private static let chiyodaAddress = "東京都千代田区千代田"
    /// 町域が11件以上ある番号の住所 (データの出現順)
    private static let manyTownAddresses = (1...12).map { "静岡県テスト市町域\(String(format: "%02d", $0))" }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        // 2000002 の先頭の住所は変換エンジンの候補 (半角数字の 2000002) と同じ表記で、重複として除かれる
        let rows =
            ["1000001\t\(Self.chiyodaAddress)", "not-a-row", "2000002\t2000002", "2000002\t神奈川県テスト町"]
            + Self.manyTownAddresses.map { "1234567\t\($0)" }
        let fixture = root.appendingPathComponent("postal_codes.tsv")
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: fixture)
        fixtureURL = fixture

        let paths = [
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("runtime").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "HAZKEY_DICTIONARY": Self.repositoryRoot.appendingPathComponent(
                "hazkey-server/azooKey_dictionary_storage/Dictionary", isDirectory: true
            ).path,
            "HAZKEY_POSTAL_CODE_DICTIONARY": fixture.path,
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            guard let value = paths[variable], setenv(variable, value, 1) == 0 else {
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
        fixtureURL = nil
    }

    // MARK: 補助

    /// 郵便番号変換の有効 / 無効を指定して共有リソースを作る
    ///
    /// - Parameters:
    ///   - enabled: 郵便番号変換を有効にするかどうか
    ///   - removesFullwidthNumber: キーマップ[Fullwidth Number]を外すかどうか
    /// - Returns: 設定を適用済みの共有リソース
    private func makeShared(enabled: Bool, removesFullwidthNumber: Bool = false) -> HazkeySharedResources {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = false
        shared.serverConfig.currentProfile.usePostalCodeConversion = enabled
        if removesFullwidthNumber {
            shared.serverConfig.currentProfile.enabledKeymaps.removeAll { $0.name == "Fullwidth Number" }
        }
        shared.reinitializeConfiguration()
        return shared
    }

    /// ASCIIのキー列を1文字ずつ入力して候補を得る
    ///
    /// - Parameters:
    ///   - state: 入力する接続セッション
    ///   - keys: 入力するキー列
    ///   - isSuggest: サジェストとして要求するかどうか
    /// - Returns: 候補の結果
    private func candidates(
        _ state: HazkeyServerState, keys: String, isSuggest: Bool = false
    ) -> Hazkey_Commands_CandidatesResult {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in keys {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success)
        return response.candidates
    }

    /// 期待する郵便番号の候補の表記を返す
    ///
    /// - Parameters:
    ///   - code: 区切りを含む7桁の番号 (XXX-XXXX)
    ///   - addresses: 候補に出る住所 (最大10件)
    /// - Returns: 住所・番号付きの先頭住所・〒付きの先頭住所の順の表記
    private static func expectedTexts(code: String, addresses: [String]) -> [String] {
        addresses + ["\(code)\u{3000}\(addresses[0])", "\u{3012}\(code)\u{3000}\(addresses[0])"]
    }

    /// サーバ側の候補リストにある郵便番号の候補の位置と表記を返す
    private static func postalEntries(_ state: HazkeyServerState) -> [(index: Int, word: String)] {
        (state.currentCandidateList ?? []).enumerated().compactMap { index, entry in
            guard case .fromPostalCode(let word, _) = entry else { return nil }
            return (index, word)
        }
    }

    /// 読み込み状態が読み込み済みのときにプロバイダを返す
    private static func loadedProvider(_ shared: HazkeySharedResources) -> PostalCodeProvider? {
        guard case .loaded(let provider) = shared.postalCodeProviderLoadState else { return nil }
        return provider
    }

    // MARK: 並びと対応

    func testPostalCandidatesFollowTheTopCandidateForDigitAndHyphenKeys() {
        let expected = Self.expectedTexts(code: "100-0001", addresses: [Self.chiyodaAddress])
        for removesFullwidthNumber in [false, true] {
            let disabled = makeShared(enabled: false, removesFullwidthNumber: removesFullwidthNumber)
            let enabled = makeShared(enabled: true, removesFullwidthNumber: removesFullwidthNumber)
            for keys in ["1000001", "100-0001"] {
                let baselineState = HazkeyServerState(shared: disabled)
                let baseline = candidates(baselineState, keys: keys)
                baselineState.close()
                let state = HazkeyServerState(shared: enabled)
                defer { state.close() }
                let result = candidates(state, keys: keys)
                let context = "keys=\(keys) removesFullwidthNumber=\(removesFullwidthNumber)"

                // 先頭候補は変わらず、その直後に郵便番号の候補が並び、残りは元の順を保つ
                XCTAssertEqual(result.candidates.first?.text, baseline.candidates.first?.text, context)
                XCTAssertEqual(result.candidates.dropFirst().prefix(expected.count).map(\.text), expected, context)
                XCTAssertEqual(
                    result.candidates.filter { !expected.contains($0.text) }.map(\.text),
                    baseline.candidates.map(\.text), context)
                // wireの候補とサーバ側の候補リストは同じ位置で対応する
                XCTAssertEqual(Self.postalEntries(state).map(\.index), Array(1...expected.count), context)
                for entry in Self.postalEntries(state) {
                    XCTAssertEqual(result.candidates[entry.index].text, entry.word, context)
                    XCTAssertEqual(result.candidates[entry.index].subHiragana, "", context)
                    XCTAssertFalse(result.candidates[entry.index].hasLearningEntry_p, context)
                }
                XCTAssertEqual(result.candidates.count, state.currentCandidateList?.count, context)
            }
        }
    }

    func testAddressesAreTruncatedToTenAndFollowedByFormattedCandidates() {
        let shared = makeShared(enabled: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        let result = candidates(state, keys: "1234567")
        let expected = Self.expectedTexts(
            code: "123-4567",
            addresses: Array(Self.manyTownAddresses.prefix(PostalCodeProvider.maxAddressCandidates)))
        XCTAssertEqual(result.candidates.dropFirst().prefix(expected.count).map(\.text), expected)
        XCTAssertFalse(result.candidates.contains { $0.text == Self.manyTownAddresses[10] })
    }

    func testDuplicateAddressIsSkippedAndLiveTextIndexStillPointsAtLiveText() {
        let shared = makeShared(enabled: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        let result = candidates(state, keys: "2000002")
        // 先頭の住所 2000002 は変換エンジンの候補と重複するため採用しない
        // 番号付き・〒付きの候補は、重複の有無に関わらずデータの先頭の住所を使う
        let adopted = ["神奈川県テスト町", "200-0002\u{3000}2000002", "\u{3012}200-0002\u{3000}2000002"]
        XCTAssertEqual(result.candidates.dropFirst().prefix(adopted.count).map(\.text), adopted)
        XCTAssertEqual(result.candidates.filter { $0.text == "2000002" }.count, 1)
        XCTAssertEqual(Self.postalEntries(state).map(\.word), adopted)
        XCTAssertGreaterThanOrEqual(result.liveTextIndex, 0)
        XCTAssertEqual(result.candidates[Int(result.liveTextIndex)].text, result.liveText)
    }

    func testExistingCandidatesKeepTheirLearningAnnotations() throws {
        let shared = makeShared(enabled: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        // 前提: 末尾の変換候補だけが学習メモリにあるとして照会に答える
        // 数字だけの読みは学習メモリに保存できないため、照会の差し替え口を使う
        let baseline = candidates(state, keys: "1000001")
        let learnedText = try XCTUnwrap(baseline.candidates.last?.text)
        XCTAssertGreaterThan(baseline.candidates.count, 1)
        shared.learningSurfaceKeyLookup = { readings in
            readings.map { PersistedLearningMemoryKey(reading: $0, word: learnedText, lcid: 0, rcid: 0) }
        }
        defer { shared.learningSurfaceKeyLookup = nil }

        // 実行: 同じ番号を入力し直す
        let result = candidates(state, keys: "1000001")

        // 検証: 学習済みの候補は注釈を保ち、郵便番号の候補は注釈を持たない
        XCTAssertEqual(result.candidates.filter(\.hasLearningEntry_p).map(\.text), [learnedText])
        for entry in Self.postalEntries(state) {
            XCTAssertFalse(result.candidates[entry.index].hasLearningEntry_p)
        }
    }

    // MARK: 確定と学習

    func testSelectingPostalCandidateConsumesTheCodeWithoutLearning() throws {
        let shared = makeShared(enabled: true)
        for pendingLearning in [false, true] {
            let state = HazkeyServerState(shared: shared)
            defer { state.close() }
            _ = candidates(state, keys: "100-0001")
            let index = try XCTUnwrap(Self.postalEntries(state).last?.index)

            // 学習削除は0件で、予測受入は拒否する
            let deletion = state.deleteCandidateLearningData(candidateIndex: index)
            XCTAssertEqual(deletion.status, .success)
            XCTAssertEqual(deletion.deleteCandidateLearningDataResult.deletedCount, 0)
            XCTAssertEqual(state.acceptPrediction(candidateIndex: index).status, .failed)

            state.learningDataNeedsCommit = pendingLearning
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            XCTAssertTrue(state.composingText.value.isEmpty)
            XCTAssertEqual(state.learningDataNeedsCommit, pendingLearning)
        }
    }

    // MARK: 文節境界

    func testClauseBoundaryAtTheCodeEndOffersPostalCandidates() throws {
        let shared = makeShared(enabled: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        _ = candidates(state, keys: "1000001desu")
        let adjusted = state.adjustClauseBoundary(offset: -2)
        XCTAssertEqual(adjusted.status, .success)
        let result = adjusted.clauseBoundaryResult.candidates

        let expected = Self.expectedTexts(code: "100-0001", addresses: [Self.chiyodaAddress])
        XCTAssertEqual(result.candidates.dropFirst().prefix(expected.count).map(\.text), expected)
        let entry = try XCTUnwrap(Self.postalEntries(state).first)
        XCTAssertEqual(result.candidates[entry.index].subHiragana, "です")

        XCTAssertEqual(state.completePrefix(candidateIndex: entry.index).status, .success)
        XCTAssertEqual(state.composingText.value.toHiragana(), "です")
    }

    func testTrailingRomajiOffersNoPostalCandidates() {
        let shared = makeShared(enabled: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        _ = candidates(state, keys: "1000001k")
        XCTAssertTrue(Self.postalEntries(state).isEmpty)
    }

    // MARK: 出さない条件

    func testDisabledProfileAndSuggestionOfferNoPostalCandidates() {
        let disabledState = HazkeyServerState(shared: makeShared(enabled: false))
        defer { disabledState.close() }
        let disabled = candidates(disabledState, keys: "1000001")
        XCTAssertFalse(disabled.candidates.contains { $0.text == Self.chiyodaAddress })

        let suggestState = HazkeyServerState(shared: makeShared(enabled: true))
        defer { suggestState.close() }
        let suggested = candidates(suggestState, keys: "1000001", isSuggest: true)
        XCTAssertFalse(suggested.candidates.contains { $0.text == Self.chiyodaAddress })
        XCTAssertTrue(Self.postalEntries(suggestState).isEmpty)
    }

    // MARK: 先読み

    func testEnabledProfileLoadsAtStartupAndDisabledDoesNot() throws {
        let disabled = HazkeySharedResources(emojiDictionaryURL: nil)
        guard case .notAttempted = disabled.postalCodeProviderLoadState else {
            return XCTFail("The postal code dictionary must not load while the conversion is off")
        }

        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.zenzaiEnable = false
        profile.usePostalCodeConversion = true
        try HazkeyServerConfig().saveConfig([profile])

        let enabled = HazkeySharedResources(emojiDictionaryURL: nil)
        XCTAssertNotNil(Self.loadedProvider(enabled), "Expected the dictionary to be loaded before the first request")
    }

    func testApplyingTheSettingLoadsOnceAndNeverReloads() throws {
        let shared = makeShared(enabled: false)
        guard case .notAttempted = shared.postalCodeProviderLoadState else {
            return XCTFail("The postal code dictionary must not load while the conversion is off")
        }

        shared.serverConfig.currentProfile.usePostalCodeConversion = true
        shared.reinitializeConfiguration()
        let provider = try XCTUnwrap(Self.loadedProvider(shared))

        // 有効→無効→有効と切り替えても、読み込み済みのプロバイダを使い続ける
        shared.serverConfig.currentProfile.usePostalCodeConversion = false
        shared.reinitializeConfiguration()
        shared.serverConfig.currentProfile.usePostalCodeConversion = true
        shared.reinitializeConfiguration()
        XCTAssertTrue(Self.loadedProvider(shared) === provider)
    }

    // MARK: 縮退

    func testMissingDictionaryKeepsNormalConversionAndIsNotRetried() throws {
        let fixtureURL = try XCTUnwrap(self.fixtureURL)
        try FileManager.default.removeItem(at: fixtureURL)
        let shared = makeShared(enabled: true)
        guard case .failed = shared.postalCodeProviderLoadState else {
            return XCTFail("Expected the load failure to be recorded")
        }
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        let result = candidates(state, keys: "1000001")
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertTrue(Self.postalEntries(state).isEmpty)

        // 失敗も結果として保持し、ファイルが現れても設定の適用で読み込み直さない
        try Data("1000001\t\(Self.chiyodaAddress)\n".utf8).write(to: fixtureURL)
        shared.reinitializeConfiguration()
        guard case .failed = shared.postalCodeProviderLoadState else {
            return XCTFail("A failed load must not be retried")
        }
    }

    func testMalformedDictionaryKeepsNormalConversion() throws {
        let fixtureURL = try XCTUnwrap(self.fixtureURL)
        try Data("bad\trow\n1000001\t\n".utf8).write(to: fixtureURL)
        let shared = makeShared(enabled: true)
        guard case .failed = shared.postalCodeProviderLoadState else {
            return XCTFail("Expected a dictionary without valid rows to be rejected")
        }
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        let result = candidates(state, keys: "1000001")
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertTrue(Self.postalEntries(state).isEmpty)
    }
}

import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 記号候補の繰り上げ (SymbolCandidatePromotion) と補助記号辞書のサーバ状態を通した振る舞いのテスト
final class SymbolConversionServerTests: XCTestCase {
    private enum SetupError: Error { case setEnvironmentFailed(String) }

    private var temporaryDirectory: URL?
    private var originalEnvironment: [String: String?] = [:]

    private static let environmentVariables = [
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR", "HAZKEY_DICTIONARY", "HAZKEY_SYMBOL_DICTIONARY",
        "HAZKEY_POSTAL_CODE_DICTIONARY",
    ]

    /// リポジトリのルート
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 同梱の補助記号辞書
    private static var symbolDictionaryURL: URL {
        repositoryRoot.appendingPathComponent("hazkey-server/SymbolDictionary/symbol_dictionary.tsv")
    }

    /// 郵便番号辞書 (任意)
    private static var postalCodeDictionaryURL: URL {
        repositoryRoot.appendingPathComponent(
            "hazkey-address-dictionary/PostalCode/postal_codes.tsv")
    }

    override func setUpWithError() throws {
        for key in Self.environmentVariables {
            originalEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        let root = try TestTempRoot.make()
        temporaryDirectory = root
        for key in [
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
            "XDG_RUNTIME_DIR",
        ] {
            guard setenv(key, root.appendingPathComponent(key).path, 1) == 0 else {
                throw SetupError.setEnvironmentFailed(key)
            }
        }
        guard
            setenv(
                "HAZKEY_DICTIONARY",
                Self.repositoryRoot.appendingPathComponent(
                    "hazkey-server/azooKey_dictionary_storage/Dictionary"
                ).path, 1) == 0
        else {
            throw SetupError.setEnvironmentFailed("HAZKEY_DICTIONARY")
        }
        guard setenv("HAZKEY_SYMBOL_DICTIONARY", Self.symbolDictionaryURL.path, 1) == 0 else {
            throw SetupError.setEnvironmentFailed("HAZKEY_SYMBOL_DICTIONARY")
        }
        if FileManager.default.fileExists(atPath: Self.postalCodeDictionaryURL.path) {
            _ = setenv("HAZKEY_POSTAL_CODE_DICTIONARY", Self.postalCodeDictionaryURL.path, 1)
        } else {
            unsetenv("HAZKEY_POSTAL_CODE_DICTIONARY")
        }
    }

    override func tearDownWithError() throws {
        for (key, value) in originalEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - ヘルパー

    /// 指定した記号変換の有無で共有リソースを作る
    ///
    /// - Parameter symbol: trueで有効、falseで無効、nilでフィールド欠落 (無効)
    private func makeShared(
        symbol: Bool?,
        useTypoCorrection: Bool = false,
        usePostalCodeConversion: Bool = false
    ) -> HazkeySharedResources {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = false
        shared.serverConfig.currentProfile.useTypoCorrection = useTypoCorrection
        shared.serverConfig.currentProfile.usePostalCodeConversion = usePostalCodeConversion
        if let symbol {
            shared.serverConfig.currentProfile.specialConversionMode.symbol = symbol
        } else {
            shared.serverConfig.currentProfile.specialConversionMode.clearSymbol()
        }
        shared.reinitializeConfiguration()
        return shared
    }

    /// ローマ字を1文字ずつ入力して候補を取得する
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

    /// 補助記号辞書から作られた `.fromSymbol` 候補の位置と表記
    private static func symbolEntries(_ state: HazkeyServerState) -> [(index: Int, word: String)] {
        (state.currentCandidateList ?? []).enumerated().compactMap { index, displayed in
            guard case .fromSymbol(let word, _) = displayed else { return nil }
            return (index, word)
        }
    }

    /// liveTextと候補件数の不変条件を検査する
    private func assertLiveTextInvariant(
        _ result: Hazkey_Commands_CandidatesResult, state: HazkeyServerState, context: String
    ) {
        XCTAssertEqual(
            result.candidates.count, state.currentCandidateList?.count ?? -1, context)
        guard result.liveTextIndex >= 0 else { return }
        let index = Int(result.liveTextIndex)
        XCTAssertLessThan(index, result.candidates.count, context)
        if index < result.candidates.count {
            XCTAssertEqual(result.candidates[index].text, result.liveText, context)
        }
    }

    /// 同じ入力を有効・無効で比較する
    private func assertSameCandidateList(
        keys: String, enabled: HazkeySharedResources, disabled: HazkeySharedResources,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let enabledState = HazkeyServerState(shared: enabled)
        defer { enabledState.close() }
        let disabledState = HazkeyServerState(shared: disabled)
        defer { disabledState.close() }
        let enabledResult = candidates(enabledState, keys: keys)
        let disabledResult = candidates(disabledState, keys: keys)
        XCTAssertEqual(
            enabledResult.candidates.map(\.text), disabledResult.candidates.map(\.text), keys,
            file: file, line: line)
        XCTAssertEqual(enabledResult.liveText, disabledResult.liveText, keys, file: file, line: line)
        XCTAssertEqual(
            enabledResult.liveTextIndex, disabledResult.liveTextIndex, keys, file: file, line: line)
    }

    // MARK: - 辞書の候補

    /// Aティアの読みで辞書の記号が保護された先頭3件の直後に来る
    func testTierAReadingsPromoteDictionarySymbolsRightAfterProtectedHead() {
        let cases: [(keys: String, expected: [String])] = [
            ("kigou", ["※", "☆", "★", "○", "●", "◎"]),
            ("santen", ["…", "‥", "︙", "⋮", "⋯", "⋰"]),
            ("kagikakko", ["「」", "『』"]),
            ("nijuukakko", ["『』"]),
            ("ri-da-", ["…", "‥"]),
        ]
        for testCase in cases {
            let shared = makeShared(symbol: true)
            let state = HazkeyServerState(shared: shared)
            defer { state.close() }
            let result = candidates(state, keys: testCase.keys)
            let texts = result.candidates.map(\.text)
            for symbol in testCase.expected {
                XCTAssertTrue(
                    texts.contains(symbol),
                    "reading: \(testCase.keys) の記号 \(symbol) が候補にありません")
            }
            // 先頭3件に既にある記号は保護され、繰り上げの対象にならない。
            let protectedTexts = Set(result.candidates.prefix(SymbolCandidatePromotion.protectedCount).map(\.text))
            let expectedAfterHead = testCase.expected.filter { !protectedTexts.contains($0) }
            let head = result.candidates
                .dropFirst(SymbolCandidatePromotion.protectedCount)
                .prefix(expectedAfterHead.count)
                .map(\.text)
            XCTAssertEqual(Array(head), expectedAfterHead, "reading: \(testCase.keys)")
        }
    }

    /// Bティアの読みでも先頭3件を保ち辞書の記号を候補に含む
    func testTierBReadingsKeepTheProtectedHeadAndOfferTheDictionarySymbol() {
        let cases: [(keys: String, symbol: String)] = [
            ("shita", "↓"),
            ("kara", "〜"),
            ("tasu", "＋"),
        ]
        for testCase in cases {
            let enabled = makeShared(symbol: true)
            let disabled = makeShared(symbol: false)
            let enabledState = HazkeyServerState(shared: enabled)
            defer { enabledState.close() }
            let disabledState = HazkeyServerState(shared: disabled)
            defer { disabledState.close() }
            let enabledResult = candidates(enabledState, keys: testCase.keys)
            let disabledResult = candidates(disabledState, keys: testCase.keys)

            XCTAssertEqual(
                enabledResult.candidates.prefix(3).map(\.text),
                disabledResult.candidates.prefix(3).map(\.text), testCase.keys)
            XCTAssertEqual(enabledResult.liveText, disabledResult.liveText, testCase.keys)
            XCTAssertEqual(
                enabledResult.liveTextIndex, disabledResult.liveTextIndex, testCase.keys)
            XCTAssertGreaterThanOrEqual(
                enabledResult.candidates.count, disabledResult.candidates.count, testCase.keys)
            XCTAssertTrue(
                enabledResult.candidates.contains { $0.text == testCase.symbol }
                    || Self.symbolEntries(enabledState).contains { $0.word == testCase.symbol },
                "\(testCase.keys) の記号 \(testCase.symbol) が候補にありません")
        }
    }

    // MARK: - 有効・無効の比較

    /// 先頭3件とライブ変換の対象は有効・無効で同じで、サジェストは完全に一致する
    func testEnabledAndDisabledKeepProtectedHeadLiveTextAndSuggestionsIdentical() {
        let enabled = makeShared(symbol: true)
        let disabled = makeShared(symbol: false)
        for keys in ["kigou", "kagikakko", "kyou", "nijuu"] {
            let enabledState = HazkeyServerState(shared: enabled)
            defer { enabledState.close() }
            let disabledState = HazkeyServerState(shared: disabled)
            defer { disabledState.close() }
            let enabledResult = candidates(enabledState, keys: keys)
            let disabledResult = candidates(disabledState, keys: keys)

            XCTAssertEqual(
                enabledResult.candidates.prefix(3).map(\.text),
                disabledResult.candidates.prefix(3).map(\.text), keys)
            XCTAssertEqual(enabledResult.liveText, disabledResult.liveText, keys)
            XCTAssertEqual(enabledResult.liveTextIndex, disabledResult.liveTextIndex, keys)

            let enabledSuggestState = HazkeyServerState(shared: enabled)
            defer { enabledSuggestState.close() }
            let disabledSuggestState = HazkeyServerState(shared: disabled)
            defer { disabledSuggestState.close() }
            let enabledSuggest = candidates(enabledSuggestState, keys: keys, isSuggest: true)
            let disabledSuggest = candidates(disabledSuggestState, keys: keys, isSuggest: true)
            XCTAssertEqual(
                enabledSuggest.candidates.map(\.text),
                disabledSuggest.candidates.map(\.text), "suggest: \(keys)")
        }
    }

    /// 明示的な無効とフィールド欠落は同じ候補一覧になる
    func testDisabledAndMissingSymbolFieldProduceTheSameCandidateList() {
        let explicit = makeShared(symbol: false)
        let missing = makeShared(symbol: nil)
        for keys in ["kigou", "kagikakko", "tasu"] {
            assertSameCandidateList(keys: keys, enabled: explicit, disabled: missing)
        }
    }

    // MARK: - 確定と学習

    /// 記号候補の確定はカーソルまでの読みだけを消費し学習しない
    func testSelectingSymbolCandidateConsumesReadingWithoutLearning() throws {
        for pendingLearning in [false, true] {
            let shared = makeShared(symbol: true)
            let state = HazkeyServerState(shared: shared)
            defer { state.close() }
            let result = candidates(state, keys: "kagikakko")
            let index = try XCTUnwrap(
                Self.symbolEntries(state).first?.index, "かぎかっこ の記号候補がありません")

            XCTAssertFalse(result.candidates[index].hasLearningEntry_p)
            let deletion = state.deleteCandidateLearningData(candidateIndex: index)
            XCTAssertEqual(deletion.status, .success)
            XCTAssertEqual(deletion.deleteCandidateLearningDataResult.deletedCount, 0)

            state.learningDataNeedsCommit = pendingLearning
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            XCTAssertTrue(state.composingText.value.isEmpty)
            XCTAssertEqual(state.learningDataNeedsCommit, pendingLearning)
        }
    }

    /// 繰り上げられた変換エンジン由来の記号は変換候補として確定し学習する
    func testMovedConverterSymbolCommitsAsConverterCandidate() throws {
        let shared = makeShared(symbol: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        _ = candidates(state, keys: "yajirusi")

        let entry = try XCTUnwrap(
            (state.currentCandidateList ?? []).enumerated().compactMap {
                index, displayed -> (index: Int, text: String)? in
                guard index >= SymbolCandidatePromotion.protectedCount,
                    case .fromConverter(let candidate) = displayed,
                    SymbolCandidateClassifier.isSymbol(candidate.text)
                else { return nil }
                return (index, candidate.text)
            }.first,
            "繰り上げられた変換エンジン由来の記号候補がありません")

        state.learningDataNeedsCommit = false
        XCTAssertEqual(state.completePrefix(candidateIndex: entry.index).status, .success)
        XCTAssertTrue(state.learningDataNeedsCommit)
    }

    /// 文節境界の調整後の記号確定は残りの読みを組成に残す
    func testClauseBoundarySymbolCommitLeavesTheRemainingReading() throws {
        let shared = makeShared(symbol: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        _ = candidates(state, keys: "kagikakkowo")
        let adjusted = state.adjustClauseBoundary(offset: -1)
        XCTAssertEqual(adjusted.status, .success)
        let result = adjusted.clauseBoundaryResult.candidates
        XCTAssertEqual(result.candidates.count, state.currentCandidateList?.count)

        let entries = Self.symbolEntries(state)
        XCTAssertFalse(entries.isEmpty, "文節境界の記号候補がありません")
        for entry in entries {
            XCTAssertEqual(result.candidates[entry.index].subHiragana, "を")
        }
        let index = try XCTUnwrap(entries.first?.index)
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
        XCTAssertEqual(state.composingText.value.toHiragana(), "を")
    }

    /// 組成を編集した後の古い記号候補番号は拒否される
    func testStaleSymbolCandidateIndexIsRejectedAfterEditing() throws {
        let shared = makeShared(symbol: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        _ = candidates(state, keys: "kagikakko")
        let index = try XCTUnwrap(Self.symbolEntries(state).first?.index)
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        let response = state.completePrefix(candidateIndex: index)
        XCTAssertEqual(response.status, .failed)
        XCTAssertFalse(response.errorMessage.isEmpty)
    }

    // MARK: - 不変条件の横断検査

    /// 誤字訂正・相対日付・かな数字・郵便番号・サジェスト経由でもライブ変換の不変条件を保つ
    func testLiveTextInvariantAndListParityAcrossCombinedConversions() {
        var cases: [(keys: String, typo: Bool, postal: Bool)] = [
            ("kigou", true, false),
            ("kyou", false, false),
            ("nijuu", false, false),
        ]
        if FileManager.default.fileExists(atPath: Self.postalCodeDictionaryURL.path) {
            cases.append(("1000001", false, true))
        }
        for testCase in cases {
            let shared = makeShared(
                symbol: true, useTypoCorrection: testCase.typo,
                usePostalCodeConversion: testCase.postal)

            let state = HazkeyServerState(shared: shared)
            defer { state.close() }
            let result = candidates(state, keys: testCase.keys)
            assertLiveTextInvariant(result, state: state, context: testCase.keys)

            let spaceState = HazkeyServerState(shared: shared)
            defer { spaceState.close() }
            _ = candidates(spaceState, keys: testCase.keys, isSuggest: true)
            let space = spaceState.getCandidates(is_suggest: false)
            XCTAssertEqual(space.status, .success)
            assertLiveTextInvariant(
                space.candidates, state: spaceState, context: "\(testCase.keys) suggest→space")
        }
    }

    // MARK: - 対象外の入力

    /// 1文字の読み・ASCII記号キー・直接入力を含む組成は有効・無効で同じ
    func testShortReadingAsciiKeyAndDirectInputAreIdenticalWhetherEnabled() {
        let enabled = makeShared(symbol: true)
        let disabled = makeShared(symbol: false)
        for keys in ["ya", "?"] {
            assertSameCandidateList(keys: keys, enabled: enabled, disabled: disabled)
        }

        let directEnabled = directInputCandidates(shared: enabled)
        let directDisabled = directInputCandidates(shared: disabled)
        XCTAssertEqual(
            directEnabled.candidates.map(\.text), directDisabled.candidates.map(\.text),
            "direct input")
        XCTAssertEqual(directEnabled.liveText, directDisabled.liveText)
        XCTAssertEqual(directEnabled.liveTextIndex, directDisabled.liveTextIndex)
    }

    /// [Shift]タップで直接入力を有効にしてから2文字入力する
    private func directInputCandidates(
        shared: HazkeySharedResources
    ) -> Hazkey_Commands_CandidatesResult {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(
            state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertTrue(state.isSubInputMode)
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        XCTAssertEqual(state.inputChar(inputString: "b").status, .success)
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        return response.candidates
    }

    /// 通常の読みの後ろへ直接入力し、カーソルをその手前へ戻しても有効・無効で同じ
    func testDirectInputAfterCursorFollowingNormalKanaIsIdenticalWhetherEnabled() {
        let enabled = makeShared(symbol: true)
        let disabled = makeShared(symbol: false)
        let enabledState = HazkeyServerState(shared: enabled)
        defer { enabledState.close() }
        let disabledState = HazkeyServerState(shared: disabled)
        defer { disabledState.close() }

        let enabledResult = directSuffixCandidates(enabledState)
        let disabledResult = directSuffixCandidates(disabledState)
        XCTAssertEqual(enabledResult.candidates.map(\.text), disabledResult.candidates.map(\.text))
        XCTAssertEqual(enabledResult.liveText, disabledResult.liveText)
        XCTAssertEqual(enabledResult.liveTextIndex, disabledResult.liveTextIndex)
        XCTAssertTrue(Self.symbolEntries(enabledState).isEmpty)

        let controlState = HazkeyServerState(shared: enabled)
        defer { controlState.close() }
        _ = candidates(controlState, keys: "kigou")
        XCTAssertFalse(
            Self.symbolEntries(controlState).isEmpty,
            "カーソルが末尾なら同じ読みで記号候補が繰り上がる")
    }

    /// 通常の読みの後ろに直接入力を置いてカーソルをその手前へ戻す
    private func directSuffixCandidates(
        _ state: HazkeyServerState
    ) -> Hazkey_Commands_CandidatesResult {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in "kigou" {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertTrue(state.isSubInputMode)
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        XCTAssertEqual(state.inputChar(inputString: "b").status, .success)
        XCTAssertEqual(state.moveCursor(offset: -2).status, .success)
        XCTAssertEqual(state.composingText.value.convertTargetCursorPosition, 3)
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        return response.candidates
    }

    // MARK: - 辞書の欠落

    /// 記号辞書の読込失敗でも変換は動き記号候補を合成しない
    func testFailedSymbolDictionaryLoadKeepsConversionAndAddsNoSynthesizedSymbols() throws {
        let missing = try XCTUnwrap(temporaryDirectory)
            .appendingPathComponent("missing_symbol_dictionary.tsv")
        XCTAssertEqual(setenv("HAZKEY_SYMBOL_DICTIONARY", missing.path, 1), 0)
        defer { _ = setenv("HAZKEY_SYMBOL_DICTIONARY", Self.symbolDictionaryURL.path, 1) }

        let shared = makeShared(symbol: true)
        guard case .failed = shared.symbolDictionaryLoadState else {
            return XCTFail("欠落した記号辞書が failed になっていません")
        }
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        let result = candidates(state, keys: "kigou")
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertTrue(Self.symbolEntries(state).isEmpty)
    }

    // MARK: - 応答の大きさと所要時間 (記録のみ)

    /// きごう変換の応答サイズと所要時間を記録し上限未満を検査する
    func testSymbolConversionResponseSizeAndLatencyAreRecorded() throws {
        let shared = makeShared(symbol: true)
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }

        var response: Hazkey_ResponseEnvelope?
        let elapsed = ContinuousClock().measure {
            _ = state.createComposingTextInstanse()
            for character in "kigou" {
                _ = state.inputChar(inputString: String(character))
            }
            response = state.getCandidates(is_suggest: false)
        }
        let envelope = try XCTUnwrap(response)
        XCTAssertEqual(envelope.status, .success)
        let serialized = try envelope.serializedData()
        let milliseconds =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print(
            "SYMBOL_PERF keys=kigou elapsed_ms=\(String(format: "%.2f", milliseconds))"
                + " size_bytes=\(serialized.count)"
                + " candidates=\(envelope.candidates.candidates.count)"
                + " liveTextIndex=\(envelope.candidates.liveTextIndex)")
        XCTAssertLessThan(serialized.count, SocketManager.maxResponseSize)
    }
}

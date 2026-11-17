import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 記号変換の定量評価 (オプトイン)
///
/// `HAZKEY_SYMBOL_EVAL=1` のときだけ実行する。通常の `swift test` ではskipされる。
///
/// コーパス (`Tests/hazkey-server/Fixtures/symbol-corpus.json`) を読み、同じ設定・左文脈・学習状態で
/// 記号変換OFFを基準、ONを提案として、ページサイズ `P` ごとにサーバで再変換して比較する。
///
/// 出力は標準出力と `HAZKEY_SYMBOL_EVAL_OUT` (既定 `/tmp/opencode/symconv/eval`) 配下のJSONに書く。
///
/// - Important: コーパス・製品コード・他のテストには触れない。学習は確定しないため作られない。
final class SymbolConversionEvaluationTests: XCTestCase {
    private enum SetupError: Error { case setEnvironmentFailed(String) }
    private enum CandidateRequestKind: Equatable { case suggest, nonSuggest }

    private var temporaryDirectory: URL?
    private var originalEnvironment: [String: String?] = [:]
    private var candidateCallLog: [ObjectIdentifier: [CandidateRequestKind]] = [:]

    private static let environmentVariables = [
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR", "HAZKEY_DICTIONARY", "HAZKEY_SYMBOL_DICTIONARY",
        "HAZKEY_POSTAL_CODE_DICTIONARY", "HAZKEY_ZENZAI_MODEL", "HAZKEY_ZENZAI_DEADLINE_MS",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var corpusURL: URL {
        repositoryRoot.appendingPathComponent(
            "hazkey-server/Tests/hazkey-server/Fixtures/symbol-corpus.json")
    }

    private static var symbolDictionaryURL: URL {
        repositoryRoot.appendingPathComponent(
            "hazkey-server/SymbolDictionary/symbol_dictionary.tsv")
    }

    private static var dictionaryURL: URL {
        repositoryRoot.appendingPathComponent(
            "hazkey-server/azooKey_dictionary_storage/Dictionary")
    }

    private static var postalCodeDictionaryURL: URL {
        repositoryRoot.appendingPathComponent(
            "hazkey-address-dictionary/PostalCode/postal_codes.tsv")
    }

    // MARK: - corpus

    private struct Corpus: Decodable {
        let version: Int
        let description: String
        let cases: [EvalCase]
    }

    private struct EvalCase: Decodable {
        let id: String
        let reading: String
        let context: String
        let tier: String
        let split: String
        let expectedSymbols: [String]?
        let expectedWords: [String]?
        let partialReadingConflict: Bool?
        let notes: String?
    }

    // MARK: - environment

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
        guard setenv("HAZKEY_DICTIONARY", Self.dictionaryURL.path, 1) == 0 else {
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
        // モデルは環境変数から解決する。ONのときだけzenzaiEnableを立てる。
        if let model = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"], !model.isEmpty {
            _ = setenv("HAZKEY_ZENZAI_MODEL", model, 1)
        }
        // 期限なし (0) にして品質を固定する
        _ = setenv("HAZKEY_ZENZAI_DEADLINE_MS", "0", 1)
    }

    override func tearDownWithError() throws {
        for (key, value) in originalEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - run

    func testSymbolConversionQuantitativeEvaluation() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["HAZKEY_SYMBOL_EVAL"] == "1",
            "HAZKEY_SYMBOL_EVAL=1 のときだけ実行する")

        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: Self.corpusURL))
        let splitFilter = (environment["HAZKEY_SYMBOL_EVAL_SPLIT"] ?? "holdout")
        let zenzaiFilter = (environment["HAZKEY_SYMBOL_EVAL_ZENZAI"] ?? "off")
        let pages = parsePages(environment["HAZKEY_SYMBOL_EVAL_PAGES"] ?? "1,2,3,4,9,10")
        let pagesOn = parsePages(
            environment["HAZKEY_SYMBOL_EVAL_PAGES_ON"]
                ?? environment["HAZKEY_SYMBOL_EVAL_PAGES"] ?? "1,2,3,4,9,10")
        let limit = Int(environment["HAZKEY_SYMBOL_EVAL_LIMIT"] ?? "0") ?? 0
        let outDirectory = environment["HAZKEY_SYMBOL_EVAL_OUT"]
            ?? "/tmp/opencode/symconv/eval"

        var cases = corpus.cases
        if splitFilter != "all" {
            cases = cases.filter { $0.split == splitFilter }
        }
        if limit > 0 { cases = Array(cases.prefix(limit)) }
        try XCTSkipIf(cases.isEmpty, "対象ケースがありません")

        var zenzaiModes: [String] = []
        switch zenzaiFilter {
        case "both": zenzaiModes = ["off", "on"]
        case "on": zenzaiModes = ["on"]
        default: zenzaiModes = ["off"]
        }

        var records: [[String: Any]] = []
        var caseDetails: [[String: Any]] = []
        var notes: [String] = [
            "input=server kana typing (one inputChar per hiragana char); left context via zenzaiLeftContext",
            "emoji injection disabled (emojiDictionaryURL: nil) to isolate symbol promotion",
            "rich candidates left at default (off)",
            "learning: unlearned only; no candidate is committed",
        ]

        for zenzai in zenzaiModes {
            let sharedOff = makeShared(symbol: false, zenzai: zenzai == "on")
            let sharedOn = makeShared(symbol: true, zenzai: zenzai == "on")
            let stateOff = HazkeyServerState(shared: sharedOff)
            let stateOn = HazkeyServerState(shared: sharedOn)
            defer {
                stateOff.close()
                stateOn.close()
            }
            let zenzaiAvailable = sharedOn.serverConfig.zenzaiAvailable
            if zenzai == "on" && !zenzaiAvailable {
                notes.append("Zenzai ON was not available (backend devices or model missing); ON condition unmeasured")
                continue
            }
            let effectivePages = zenzai == "on" ? pagesOn : pages
            for page in effectivePages {
                var acc = Accumulator(page: page, zenzai: zenzai, split: splitFilter)
                var n30MissingSymbolCases = 0
                var n30SymbolFound = 0
                var n30SymbolAbsent = 0
                var n30AbsentSymbols: [String] = []
                var n30MissingWordCases = 0
                var n30MissingWordLabels = 0
                var n30WordLabelsFound = 0
                for evalCase in cases {
                    let off = convert(
                        state: stateOff, shared: sharedOff, evalCase: evalCase, pageSize: page)
                    let on = convert(
                        state: stateOn, shared: sharedOn, evalCase: evalCase, pageSize: page)
                    acc.observe(evalCase: evalCase, off: off, on: on)
                    if zenzai == "off" {
                        let symbols = evalCase.expectedSymbols ?? []
                        let words = evalCase.expectedWords ?? []
                        let missingSymbols = symbols.filter {
                            !Accumulator.contains(off.firstPage, $0)
                        }
                        let missingWords = words.filter {
                            !Accumulator.contains(off.firstPage, $0)
                        }
                        if !missingSymbols.isEmpty || !missingWords.isEmpty {
                            let top30 = rawCandidateTexts(
                                state: stateOff, shared: sharedOff, nBest: 30)
                            if !missingSymbols.isEmpty {
                                n30MissingSymbolCases += 1
                                if missingSymbols.contains(where: {
                                    Accumulator.contains(top30, $0)
                                }) {
                                    n30SymbolFound += 1
                                } else {
                                    n30SymbolAbsent += 1
                                    if n30AbsentSymbols.count < 12 {
                                        n30AbsentSymbols.append(
                                            "\(evalCase.id)/\(evalCase.reading): "
                                                + missingSymbols.joined(separator: "|"))
                                    }
                                }
                            }
                            if !missingWords.isEmpty {
                                n30MissingWordCases += 1
                                n30MissingWordLabels += missingWords.count
                                n30WordLabelsFound += missingWords.filter {
                                    Accumulator.contains(top30, $0)
                                }.count
                            }
                        }
                    }
                    if acc.details.count < 40 {
                        if let detail = acc.detailIfInteresting(evalCase: evalCase, off: off, on: on) {
                            caseDetails.append(detail)
                        }
                    }
                }
                let n30: [String: Any]? = zenzai == "off"
                    ? [
                        "missingSymbolCases": n30MissingSymbolCases,
                        "missingSymbolFoundInTop30": n30SymbolFound,
                        "missingSymbolAbsentFromTop30": n30SymbolAbsent,
                        "absentSymbolExamples": n30AbsentSymbols,
                        "missingWordLabelCases": n30MissingWordCases,
                        "missingWordLabels": n30MissingWordLabels,
                        "missingWordLabelsFoundInTop30": n30WordLabelsFound,
                    ]
                    : nil
                let record = acc.record(nBest30: n30)
                records.append(record)
                print(acc.summaryLine())
                if let n30 {
                    print("  nBest30: \(n30)")
                }
            }
        }

        let payload: [String: Any] = [
            "corpusVersion": corpus.version,
            "corpusDescription": corpus.description,
            "corpusFile": Self.corpusURL.path,
            "symbolDictionary": Self.symbolDictionaryURL.path,
            "zenzaiModel": ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"] ?? "(unset)",
            "splitFilter": splitFilter,
            "zenzaiFilter": zenzaiFilter,
            "pages": pages,
            "pagesOn": pagesOn,
            "caseCount": cases.count,
            "notes": notes,
            "records": records,
            "caseDetails": caseDetails,
        ]
        try writeJSON(payload, to: outDirectory)
        print("WROTE \(outDirectory)/symbol-conversion-eval.json")
    }

    // MARK: - input path evaluation (preliminary)

    /// 入力経路 (かな / ローマ字 / 直接入力) と、サジェスト後のSpaceの比較 (オプトイン)
    ///
    /// `HAZKEY_SYMBOL_EVAL_INPUT=1` のときだけ実行する。
    /// 記号変換の製品側修正が進行中のため、この結果は予備評価であり最終検証ではない。
    func testSymbolConversionInputPathEvaluation() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["HAZKEY_SYMBOL_EVAL_INPUT"] == "1",
            "HAZKEY_SYMBOL_EVAL_INPUT=1 のときだけ実行する")

        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: Self.corpusURL))
        let splitFilter = environment["HAZKEY_SYMBOL_EVAL_INPUT_SPLIT"] ?? "holdout"
        let zenzaiFilter = environment["HAZKEY_SYMBOL_EVAL_INPUT_ZENZAI"] ?? "both"
        let pages = parsePages(environment["HAZKEY_SYMBOL_EVAL_INPUT_PAGES"] ?? "9,10")
        let limit = Int(environment["HAZKEY_SYMBOL_EVAL_INPUT_LIMIT"] ?? "24") ?? 24
        let outDirectory = environment["HAZKEY_SYMBOL_EVAL_INPUT_OUT"]
            ?? "/tmp/opencode/symconv/input-eval"

        // 層化に近づけるため、記号正解のあるケースを等間隔に抜き出す
        var symbolCases = corpus.cases.filter {
            $0.split == splitFilter && !($0.expectedSymbols ?? []).isEmpty
        }
        if limit > 0 && symbolCases.count > limit {
            let step = max(1, symbolCases.count / limit)
            var picked: [EvalCase] = []
            var index = 0
            while index < symbolCases.count && picked.count < limit {
                picked.append(symbolCases[index])
                index += step
            }
            symbolCases = picked
        }
        let partialCases = Array(
            corpus.cases.filter {
                $0.split == splitFilter && $0.partialReadingConflict == true
            }.prefix(2))
        let cases = symbolCases + partialCases
        try XCTSkipIf(cases.isEmpty, "対象ケースがありません")

        var zenzaiModes: [String] = []
        switch zenzaiFilter {
        case "both": zenzaiModes = ["off", "on"]
        case "on": zenzaiModes = ["on"]
        default: zenzaiModes = ["off"]
        }

        var records: [[String: Any]] = []
        var caseDetails: [[String: Any]] = []
        var romajiComposeFailures: [String] = []
        var notes: [String] = [
            "PRELIMINARY: product-side symbol conversion fixes are still in progress; not a final validation",
            "input paths: kana (inputChar hiragana), romaji (inputChar romaji keys), direct (insertAtCursorPosition .direct)",
            "baseline for ordinary loss is kana + Space (non-suggest) at the same page size and zenzai mode",
            "suggest_page: a composition created after the baseline is queried once with is_suggest=true",
            "suggest_then_space: a composition created after the baseline is queried with is_suggest=true then with is_suggest=false (Space)",
            "control: the per-composition candidate request log must be [suggest] or [suggest, nonSuggest]; any non-suggest before the first suggest fails the case",
            "suggest uses the default numSuggestions (3), not the page size",
            "learning: unlearned only; no candidate is committed",
            "sample: evenly spaced holdout cases with expectedSymbols, plus up to 2 partial-reading-conflict cases",
        ]

        for zenzai in zenzaiModes {
            let sharedOff = makeShared(symbol: false, zenzai: zenzai == "on")
            let sharedOn = makeShared(symbol: true, zenzai: zenzai == "on")
            let stateOff = HazkeyServerState(shared: sharedOff)
            let stateOn = HazkeyServerState(shared: sharedOn)
            defer {
                stateOff.close()
                stateOn.close()
            }
            if zenzai == "on" && !sharedOn.serverConfig.zenzaiAvailable {
                notes.append("Zenzai ON was not available; input-path ON condition unmeasured")
                continue
            }
            for page in pages {
                sharedOff.serverConfig.currentProfile.numCandidatesPerPage = Int32(page)
                sharedOn.serverConfig.currentProfile.numCandidatesPerPage = Int32(page)
                for variant in [
                    "kana_space", "romaji_space", "direct_space", "suggest_page",
                    "suggest_then_space",
                ] {
                    var acc = InputPathAccumulator(
                        page: page, zenzai: zenzai, variant: variant, split: splitFilter)
                    acc.cases = cases.count
                    for evalCase in cases {
                        // 基準: かな入力 + Space (非サジェスト)
                        composeKana(stateOff, reading: evalCase.reading)
                        stateOff.zenzaiLeftContext = evalCase.context
                        let baseOff = observeCurrent(
                            state: stateOff, isSuggest: false, pageSize: page)
                        composeKana(stateOn, reading: evalCase.reading)
                        stateOn.zenzaiLeftContext = evalCase.context
                        let baseOn = observeCurrent(
                            state: stateOn, isSuggest: false, pageSize: page)

                        var subjectOff = baseOff
                        var subjectOn = baseOn
                        var applicable = true
                        switch variant {
                        case "kana_space":
                            break
                        case "romaji_space":
                            let okOff = composeRomaji(stateOff, reading: evalCase.reading)
                            stateOff.zenzaiLeftContext = evalCase.context
                            let okOn = composeRomaji(stateOn, reading: evalCase.reading)
                            stateOn.zenzaiLeftContext = evalCase.context
                            if okOff && okOn {
                                subjectOff = observeCurrent(
                                    state: stateOff, isSuggest: false, pageSize: page)
                                subjectOn = observeCurrent(
                                    state: stateOn, isSuggest: false, pageSize: page)
                            } else {
                                applicable = false
                                if romajiComposeFailures.count < 12 {
                                    romajiComposeFailures.append(
                                        "\(evalCase.id)/\(evalCase.reading)")
                                }
                            }
                        case "direct_space":
                            composeDirect(stateOff, reading: evalCase.reading)
                            stateOff.zenzaiLeftContext = evalCase.context
                            composeDirect(stateOn, reading: evalCase.reading)
                            stateOn.zenzaiLeftContext = evalCase.context
                            subjectOff = observeCurrent(
                                state: stateOff, isSuggest: false, pageSize: page)
                            subjectOn = observeCurrent(
                                state: stateOn, isSuggest: false, pageSize: page)
                        case "suggest_page", "suggest_then_space":
                            // サジェストがsubject組成の最初の候補要求になるよう、基準 (非サジェスト) の後に作り直す
                            composeKana(stateOff, reading: evalCase.reading)
                            stateOff.zenzaiLeftContext = evalCase.context
                            composeKana(stateOn, reading: evalCase.reading)
                            stateOn.zenzaiLeftContext = evalCase.context
                            let suggestOff = observeCurrent(
                                state: stateOff, isSuggest: true, pageSize: page)
                            let suggestOn = observeCurrent(
                                state: stateOn, isSuggest: true, pageSize: page)
                            assertFirstCandidateRequestIsSuggest(
                                stateOff, variant: variant, evalCase: evalCase)
                            assertFirstCandidateRequestIsSuggest(
                                stateOn, variant: variant, evalCase: evalCase)
                            if variant == "suggest_page" {
                                assertCandidateCallSequence(
                                    stateOff, expected: [.suggest], variant: variant,
                                    evalCase: evalCase)
                                assertCandidateCallSequence(
                                    stateOn, expected: [.suggest], variant: variant,
                                    evalCase: evalCase)
                                subjectOff = suggestOff
                                subjectOn = suggestOn
                            } else {
                                subjectOff = observeCurrent(
                                    state: stateOff, isSuggest: false, pageSize: page)
                                subjectOn = observeCurrent(
                                    state: stateOn, isSuggest: false, pageSize: page)
                                assertCandidateCallSequence(
                                    stateOff, expected: [.suggest, .nonSuggest], variant: variant,
                                    evalCase: evalCase)
                                assertCandidateCallSequence(
                                    stateOn, expected: [.suggest, .nonSuggest], variant: variant,
                                    evalCase: evalCase)
                                acc.observeSuggestToSpace(
                                    evalCase: evalCase,
                                    suggest: zenzai == "on" ? suggestOn : suggestOff,
                                    space: zenzai == "on" ? subjectOn : subjectOff)
                            }
                        default:
                            break
                        }
                        if applicable {
                            acc.observe(
                                evalCase: evalCase,
                                baseline: zenzai == "on" ? baseOn : baseOff,
                                subject: zenzai == "on" ? subjectOn : subjectOff,
                                isBaseline: variant == "kana_space")
                        } else {
                            acc.unmeasured += 1
                        }
                    }
                    records.append(acc.record())
                    caseDetails.append(contentsOf: acc.details)
                    print(acc.summaryLine())
                }
            }
        }

        let payload: [String: Any] = [
            "preliminary": true,
            "inputPathSemantics":
                "suggest variants re-create the composition after the kana+Space baseline; the first candidate request on the subject composition is is_suggest=true (asserted per case)",
            "corpusVersion": corpus.version,
            "corpusFile": Self.corpusURL.path,
            "symbolDictionary": Self.symbolDictionaryURL.path,
            "zenzaiModel": ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"] ?? "(unset)",
            "splitFilter": splitFilter,
            "zenzaiFilter": zenzaiFilter,
            "pages": pages,
            "caseCount": cases.count,
            "romajiComposeFailures": romajiComposeFailures,
            "notes": notes,
            "records": records,
            "caseDetails": Array(caseDetails.prefix(80)),
        ]
        try writeInputJSON(payload, to: outDirectory)
        print("WROTE \(outDirectory)/symbol-conversion-input-eval.json")
    }

    // MARK: - shared resources

    private func makeShared(symbol: Bool, zenzai: Bool) -> HazkeySharedResources {
        let shared = HazkeySharedResources(emojiDictionaryURL: nil)
        shared.serverConfig.currentProfile.zenzaiEnable = zenzai
        shared.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        shared.serverConfig.currentProfile.useRichCandidates = false
        shared.serverConfig.currentProfile.useRichSuggestion = false
        shared.serverConfig.currentProfile.useTypoCorrection = false
        shared.serverConfig.currentProfile.usePostalCodeConversion = false
        shared.serverConfig.currentProfile.useUserDictionary = false
        shared.serverConfig.currentProfile.useInputHistory = false
        shared.serverConfig.currentProfile.specialConversionMode.symbol = symbol
        shared.reinitializeConfiguration()
        if zenzai {
            shared.serverConfig.reloadZenzaiModel()
            shared.baseConvertRequestOptions = shared.serverConfig.genBaseConvertRequestOptions()
        }
        return shared
    }

    // MARK: - conversion

    private struct Observation {
        let firstPage: [String]
        let firstPageServer: [DisplayedCandidate]
        let pageSize: Int
    }

    private func convert(
        state: HazkeyServerState, shared: HazkeySharedResources, evalCase: EvalCase, pageSize: Int
    ) -> Observation {
        shared.serverConfig.currentProfile.numCandidatesPerPage = Int32(pageSize)
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        state.zenzaiLeftContext = evalCase.context
        for character in evalCase.reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let reading = state.composingText.value.toHiragana()
        if reading != evalCase.reading {
            XCTFail(
                "composed reading mismatch for \(evalCase.id): got \(reading) expected \(evalCase.reading)"
            )
        }
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        let result = response.candidates
        let effectivePage = max(1, Int(result.pageSize))
        let texts = result.candidates.map(\.text)
        let server = state.currentCandidateList ?? []
        let n = min(effectivePage, texts.count, server.count)
        return Observation(
            firstPage: Array(texts.prefix(n)),
            firstPageServer: Array(server.prefix(n)),
            pageSize: n)
    }

    /// N_best=30の制御用: 記号ON/OFFの昇格を通さない生の変換候補。
    /// `numCandidatesPerPage` の上限は10なので、プロファイル経由では到達できない。
    private func rawCandidateTexts(
        state: HazkeyServerState, shared: HazkeySharedResources, nBest: Int
    ) -> [String] {
        var options = shared.serverConfig.genBaseConvertRequestOptions()
        options.N_best = nBest
        let id = shared.converter.createSession()
        defer { shared.converter.removeSession(id) }
        let text = state.composingText.value
        do {
            let converted = try shared.converter.withSession(id) {
                shared.converter.requestCandidates(text, options: options)
            }
            return converted.mainResults.map(\.text)
                + converted.predictionResults.map(\.text)
        } catch {
            return []
        }
    }

    // MARK: - accumulator

    private struct Accumulator {
        let page: Int
        let zenzai: String
        let split: String
        var symbolCases = 0
        var symbolWithTruth = 0
        var offHits = 0
        var onHits = 0
        var opportunityCases = 0
        var gainedCases = 0
        var lostSymbolCases = 0
        var pageCandidateTotal = 0
        var ordinaryDenom = 0
        var ordinaryLost = 0
        var casesWithOrdinaryLoss = 0
        var wordLabelsAbsentOff = 0
        var oneNodeWords = 0
        var multiNodeWords = 0
        var nonConverterWords = 0
        var partialConflictCases = 0
        var partialConflictOnHits = 0
        var partialConflictWordLabels = 0
        var partialConflictWordLabelsKeptOn = 0
        var details: [[String: Any]] = []
        var lostExamples: [String] = []
        var gainExamples: [String] = []

        init(page: Int, zenzai: String, split: String) {
            self.page = page
            self.zenzai = zenzai
            self.split = split
        }

        static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

        static func contains(_ page: [String], _ expected: String) -> Bool {
            let key = scalars(expected)
            return page.contains { scalars($0) == key }
        }

        mutating func observe(
            evalCase: EvalCase, off: Observation, on: Observation
        ) {
            pageCandidateTotal += off.firstPage.count
            let symbols = evalCase.expectedSymbols ?? []
            if !symbols.isEmpty {
                symbolCases += 1
                let offHit = symbols.contains { Self.contains(off.firstPage, $0) }
                let onHit = symbols.contains { Self.contains(on.firstPage, $0) }
                if offHit { offHits += 1 }
                if onHit { onHits += 1 }
                if !offHit {
                    opportunityCases += 1
                    if onHit {
                        gainedCases += 1
                        if gainExamples.count < 12 {
                            gainExamples.append("\(evalCase.id)/\(evalCase.reading): \(symbols.joined(separator: "|"))")
                        }
                    }
                }
                if offHit && !onHit {
                    lostSymbolCases += 1
                }
                symbolWithTruth += 1
            }
            let words = evalCase.expectedWords ?? []
            if evalCase.partialReadingConflict == true {
                partialConflictCases += 1
                if symbols.contains(where: { Self.contains(on.firstPage, $0) }) {
                    partialConflictOnHits += 1
                }
                for word in words where Self.contains(off.firstPage, word) {
                    partialConflictWordLabels += 1
                    if Self.contains(on.firstPage, word) {
                        partialConflictWordLabelsKeptOn += 1
                    }
                }
            }

            if !words.isEmpty {
                var lostInCase = false
                for word in words {
                    guard Self.contains(off.firstPage, word) else {
                        wordLabelsAbsentOff += 1
                        continue
                    }
                    ordinaryDenom += 1
                    // data.countの集計 (対応するサーバ候補)
                    if let index = off.firstPage.firstIndex(where: { Self.scalars($0) == Self.scalars(word) }) {
                        switch off.firstPageServer[index] {
                        case .fromConverter(let candidate):
                            if candidate.data.count == 1 { oneNodeWords += 1 } else { multiNodeWords += 1 }
                        default:
                            nonConverterWords += 1
                        }
                    }
                    if !Self.contains(on.firstPage, word) {
                        ordinaryLost += 1
                        lostInCase = true
                        if lostExamples.count < 12 {
                            lostExamples.append("\(evalCase.id)/\(evalCase.reading): \(word)")
                        }
                    }
                }
                if lostInCase { casesWithOrdinaryLoss += 1 }
            }
        }

        func detailIfInteresting(
            evalCase: EvalCase, off: Observation, on: Observation
        ) -> [String: Any]? {
            let symbols = evalCase.expectedSymbols ?? []
            let words = evalCase.expectedWords ?? []
            let offSym = symbols.filter { Self.contains(off.firstPage, $0) }
            let onSym = symbols.filter { Self.contains(on.firstPage, $0) }
            let lostWords = words.filter {
                Self.contains(off.firstPage, $0) && !Self.contains(on.firstPage, $0)
            }
            guard !lostWords.isEmpty || (onSym.count > offSym.count) else { return nil }
            return [
                "page": page,
                "zenzai": zenzai,
                "id": evalCase.id,
                "reading": evalCase.reading,
                "tier": evalCase.tier,
                "context": evalCase.context,
                "offFirstPage": off.firstPage,
                "onFirstPage": on.firstPage,
                "expectedSymbols": symbols,
                "expectedWords": words,
                "lostWords": lostWords,
                "offSymbols": offSym,
                "onSymbols": onSym,
            ]
        }

        func record(nBest30: [String: Any]?) -> [String: Any] {
            let offRecall = symbolWithTruth > 0 ? Double(offHits) / Double(symbolWithTruth) : 0
            let onRecall = symbolWithTruth > 0 ? Double(onHits) / Double(symbolWithTruth) : 0
            let lossRate = ordinaryDenom > 0 ? Double(ordinaryLost) / Double(ordinaryDenom) : 0
            var dict: [String: Any] = [
                "page": page,
                "zenzai": zenzai,
                "split": split,
                "symbolCases": symbolCases,
                "symbolCasesWithTruth": symbolWithTruth,
                "offSymbolHits": offHits,
                "onSymbolHits": onHits,
                "offRecall": offRecall,
                "onRecall": onRecall,
                "recallDeltaPoints": (onRecall - offRecall) * 100.0,
                "opportunityCases": opportunityCases,
                "gainedCases": gainedCases,
                "lostSymbolCases": lostSymbolCases,
                "ordinaryDenominator": ordinaryDenom,
                "ordinaryLost": ordinaryLost,
                "ordinaryLossRate": lossRate,
                "casesWithOrdinaryLoss": casesWithOrdinaryLoss,
                "wordLabelsAbsentFromOffPage": wordLabelsAbsentOff,
                "oneNodeWords": oneNodeWords,
                "multiNodeWords": multiNodeWords,
                "nonConverterWords": nonConverterWords,
                "partialConflictCases": partialConflictCases,
                "partialConflictOnHits": partialConflictOnHits,
                "partialConflictWordLabels": partialConflictWordLabels,
                "partialConflictWordLabelsKeptOn": partialConflictWordLabelsKeptOn,
                "pageCandidateTotal": pageCandidateTotal,
                "lostExamples": lostExamples,
                "gainExamples": gainExamples,
            ]
            if let nBest30 { dict["nBest30"] = nBest30 }
            return dict
        }

        func summaryLine() -> String {
            let offRecall = symbolWithTruth > 0 ? Double(offHits) / Double(symbolWithTruth) : 0
            let onRecall = symbolWithTruth > 0 ? Double(onHits) / Double(symbolWithTruth) : 0
            let lossRate = ordinaryDenom > 0 ? Double(ordinaryLost) / Double(ordinaryDenom) : 0
            return String(
                format:
                    "P=%d zenzai=%@: symbol %d/%d OFF %.3f ON %.3f (delta %+.1fpt) | ordinary lost %d/%d (%.3f%%) | opportunities %d gained %d | partialConflict %d (ON hit %d)",
                page, zenzai, onHits, symbolWithTruth, offRecall, onRecall,
                (onRecall - offRecall) * 100.0, ordinaryLost, ordinaryDenom, lossRate * 100.0,
                opportunityCases, gainedCases, partialConflictCases, partialConflictOnHits)
        }
    }

    // MARK: - input path helpers

    private struct InputPathAccumulator {
        let page: Int
        let zenzai: String
        let variant: String
        let split: String
        var cases = 0
        var unmeasured = 0
        var symbolCases = 0
        var symbolHits = 0
        var baselineSymbolHits = 0
        var ordinaryDenominator = 0
        var ordinaryLost = 0
        var ordinaryGained = 0
        var pageDiffCases = 0
        var suggestVsSpaceDiffCases = 0
        var spaceOnlySymbolCases = 0
        var suggestOnlySymbolCases = 0
        var details: [[String: Any]] = []

        mutating func observe(
            evalCase: EvalCase, baseline: Observation, subject: Observation,
            isBaseline: Bool
        ) {
            let symbols = evalCase.expectedSymbols ?? []
            if !symbols.isEmpty {
                symbolCases += 1
                if symbols.contains(where: { Accumulator.contains(subject.firstPage, $0) }) {
                    symbolHits += 1
                }
                if symbols.contains(where: { Accumulator.contains(baseline.firstPage, $0) }) {
                    baselineSymbolHits += 1
                }
            }
            let words = evalCase.expectedWords ?? []
            for word in words where Accumulator.contains(baseline.firstPage, word) {
                ordinaryDenominator += 1
                if !Accumulator.contains(subject.firstPage, word) {
                    ordinaryLost += 1
                }
            }
            for word in words
            where Accumulator.contains(subject.firstPage, word)
                && !Accumulator.contains(baseline.firstPage, word) {
                ordinaryGained += 1
            }
            if !isBaseline && subject.firstPage != baseline.firstPage {
                pageDiffCases += 1
                if details.count < 8 {
                    details.append([
                        "page": page,
                        "zenzai": zenzai,
                        "variant": variant,
                        "id": evalCase.id,
                        "reading": evalCase.reading,
                        "tier": evalCase.tier,
                        "baselineFirstPage": baseline.firstPage,
                        "subjectFirstPage": subject.firstPage,
                        "expectedSymbols": symbols,
                        "expectedWords": words,
                    ])
                }
            }
        }

        mutating func observeSuggestToSpace(
            evalCase: EvalCase, suggest: Observation, space: Observation
        ) {
            let symbols = evalCase.expectedSymbols ?? []
            if !symbols.isEmpty {
                let suggestHit = symbols.contains {
                    Accumulator.contains(suggest.firstPage, $0)
                }
                let spaceHit = symbols.contains { Accumulator.contains(space.firstPage, $0) }
                if spaceHit && !suggestHit { spaceOnlySymbolCases += 1 }
                if suggestHit && !spaceHit { suggestOnlySymbolCases += 1 }
            }
            if suggest.firstPage != space.firstPage {
                suggestVsSpaceDiffCases += 1
                if details.count < 8 {
                    details.append([
                        "page": page,
                        "zenzai": zenzai,
                        "variant": "suggest_vs_space",
                        "id": evalCase.id,
                        "reading": evalCase.reading,
                        "tier": evalCase.tier,
                        "suggestFirstPage": suggest.firstPage,
                        "spaceFirstPage": space.firstPage,
                        "expectedSymbols": symbols,
                        "expectedWords": evalCase.expectedWords ?? [],
                    ])
                }
            }
        }

        func record() -> [String: Any] {
            let recall = symbolCases > 0 ? Double(symbolHits) / Double(symbolCases) : 0
            let baselineRecall = symbolCases > 0
                ? Double(baselineSymbolHits) / Double(symbolCases) : 0
            let lossRate = ordinaryDenominator > 0
                ? Double(ordinaryLost) / Double(ordinaryDenominator) : 0
            return [
                "page": page,
                "zenzai": zenzai,
                "variant": variant,
                "split": split,
                "preliminary": true,
                "cases": cases,
                "unmeasured": unmeasured,
                "symbolCases": symbolCases,
                "symbolHits": symbolHits,
                "recall": recall,
                "baselineSymbolHits": baselineSymbolHits,
                "baselineRecall": baselineRecall,
                "recallDeltaPoints": (recall - baselineRecall) * 100.0,
                "ordinaryDenominator": ordinaryDenominator,
                "ordinaryLost": ordinaryLost,
                "ordinaryGained": ordinaryGained,
                "ordinaryLossRate": lossRate,
                "pageDiffCases": pageDiffCases,
                "suggestVsSpaceDiffCases": suggestVsSpaceDiffCases,
                "spaceOnlySymbolCases": spaceOnlySymbolCases,
                "suggestOnlySymbolCases": suggestOnlySymbolCases,
            ]
        }

        func summaryLine() -> String {
            let recall = symbolCases > 0 ? Double(symbolHits) / Double(symbolCases) : 0
            let baseRecall = symbolCases > 0
                ? Double(baselineSymbolHits) / Double(symbolCases) : 0
            let lossRate = ordinaryDenominator > 0
                ? Double(ordinaryLost) / Double(ordinaryDenominator) : 0
            return String(
                format:
                    "INPUT P=%d zenzai=%@ %@: symbol %d/%d (base %d, delta %+.1fpt) | ordinary lost %d/%d (%.3f%%) gained %d | pageDiff %d | suggestVsSpaceDiff %d (spaceOnly %d / suggestOnly %d) | unmeasured %d",
                page, zenzai, variant, symbolHits, symbolCases, baselineSymbolHits,
                (recall - baseRecall) * 100.0, ordinaryLost, ordinaryDenominator,
                lossRate * 100.0, ordinaryGained, pageDiffCases, suggestVsSpaceDiffCases,
                spaceOnlySymbolCases, suggestOnlySymbolCases, unmeasured)
        }
    }

    private func composeKana(_ state: HazkeyServerState, reading: String) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        resetCandidateCallLog(for: state)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.composingText.value.toHiragana(), reading)
    }

    private func composeRomaji(_ state: HazkeyServerState, reading: String) -> Bool {
        guard let romaji = Self.kanaToRomaji(reading) else { return false }
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        resetCandidateCallLog(for: state)
        for character in romaji {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        return state.composingText.value.toHiragana() == reading
    }

    private func composeDirect(_ state: HazkeyServerState, reading: String) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        resetCandidateCallLog(for: state)
        state.composingText.value.insertAtCursorPosition(reading, inputStyle: .direct)
        XCTAssertEqual(state.composingText.value.toHiragana(), reading)
    }

    private func resetCandidateCallLog(for state: HazkeyServerState) {
        candidateCallLog[ObjectIdentifier(state)] = []
    }

    private func assertFirstCandidateRequestIsSuggest(
        _ state: HazkeyServerState, variant: String, evalCase: EvalCase,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let calls = candidateCallLog[ObjectIdentifier(state)] ?? []
        guard let first = calls.first else {
            XCTFail(
                "\(variant) \(evalCase.id): no candidate request was recorded",
                file: file, line: line)
            return
        }
        XCTAssertEqual(
            first, .suggest,
            "\(variant) \(evalCase.id): first candidate request was \(first), not suggest (\(calls))",
            file: file, line: line)
    }

    private func assertCandidateCallSequence(
        _ state: HazkeyServerState, expected: [CandidateRequestKind], variant: String,
        evalCase: EvalCase, file: StaticString = #filePath, line: UInt = #line
    ) {
        let calls = candidateCallLog[ObjectIdentifier(state)] ?? []
        XCTAssertEqual(
            calls, expected,
            "\(variant) \(evalCase.id): candidate request sequence \(calls) != \(expected)",
            file: file, line: line)
    }

    private func observeCurrent(
        state: HazkeyServerState, isSuggest: Bool, pageSize: Int
    ) -> Observation {
        if !isSuggest {
            state.serverConfig.currentProfile.numCandidatesPerPage = Int32(pageSize)
        }
        candidateCallLog[ObjectIdentifier(state), default: []]
            .append(isSuggest ? .suggest : .nonSuggest)
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success)
        let result = response.candidates
        let texts = result.candidates.map(\.text)
        let server = state.currentCandidateList ?? []
        let effectivePage = isSuggest ? max(1, texts.count) : max(1, Int(result.pageSize))
        let n = min(effectivePage, texts.count, server.count)
        return Observation(
            firstPage: Array(texts.prefix(n)),
            firstPageServer: Array(server.prefix(n)),
            pageSize: n)
    }

    private static let romajiDigraphs: [String: String] = [
        "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
        "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
        "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
        "じゃ": "ja", "じゅ": "ju", "じょ": "jo",
        "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho",
        "ぢゃ": "dya", "ぢゅ": "dyu", "ぢょ": "dyo",
        "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
        "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
        "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
        "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
        "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
        "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
    ]

    private static let romajiSingles: [String: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "ぁ": "xa", "ぃ": "xi", "ぅ": "xu", "ぇ": "xe", "ぉ": "xo",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "だ": "da", "ぢ": "di", "づ": "du", "で": "de", "ど": "do",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ゃ": "xya", "ゅ": "xyu", "ょ": "xyo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "を": "wo", "ん": "nn", "ゔ": "vu",
        "っ": "xtu", "ー": "-",
    ]

    private static func kanaToRomaji(_ reading: String) -> String? {
        let characters = Array(reading)
        var result = ""
        var index = 0
        while index < characters.count {
            if index + 1 < characters.count {
                let pair = String(characters[index...index + 1])
                if let romaji = romajiDigraphs[pair] {
                    result += romaji
                    index += 2
                    continue
                }
            }
            let single = String(characters[index])
            guard let romaji = romajiSingles[single] else { return nil }
            result += romaji
            index += 1
        }
        return result
    }

    private func writeInputJSON(_ payload: [String: Any], to directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url.appendingPathComponent("symbol-conversion-input-eval.json"))
    }

    // MARK: - helpers

    private func parsePages(_ raw: String) -> [Int] {
        raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
    }

    private func writeJSON(_ payload: [String: Any], to directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url.appendingPathComponent("symbol-conversion-eval.json"))
    }
}

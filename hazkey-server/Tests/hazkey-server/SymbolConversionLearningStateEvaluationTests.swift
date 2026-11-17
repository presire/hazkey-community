import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 記号変換の学習状態別評価 (オプトイン、独立テスト)
///
/// HAZKEY_SYMBOL_EVAL_LEARNING=1の場合のみ実行する
/// 通常の`swift test`ではskipされる
///
/// 既存のSymbolConversionEvaluationTests.swiftとは別ファイル・別クラスであり、製品コードと既存評価ファイルを変更しない
/// 未学習 (対照)・一時学習 (確定直後、保存前)・永続学習 (保存後に変換エンジンを再構築)・ユーザ辞書登録の各条件で、
/// 同じ左文脈・同じ設定のまま、記号変換OFFとONを比較する
///
/// 学習語・登録語が実際に候補へ存在することを確認してから比較する
///
/// 出力は標準出力の要約とHAZKEY_SYMBOL_EVAL_LEARNING_OUT (既定: /tmp/opencode/symconv/learning-eval) 配下のJSON
///
/// - Note: 記号変換以外の特殊変換と絵文字注入は無効化して、学習・ユーザ辞書と記号の繰り上げだけを比較できるようにする
///         これは、既存評価の設定とは異なる (明示的に記録する)
/// - Note: ユーザ辞書の表記は、変換エンジン由来との区別を明確にするための合成語であり、自然言語としての品質を主張しない
/// - Important: ユーザデータは使用しない
///              XDGディレクトリは、テストごとの一時ディレクトリに隔離する
final class SymbolConversionLearningStateEvaluationTests: XCTestCase {
    private enum SetupError: Error { case setEnvironmentFailed(String) }

    private var temporaryDirectory: URL?
    private var originalEnvironment: [String: String?] = [:]

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

    /// 絵文字注入を確実に無効化するための存在しないパス
    private static var disabledEmojiDictionaryURL: URL {
        URL(fileURLWithPath: "/nonexistent/hazkey-learning-eval-emoji-disabled.txt")
    }

    /// 計画 (サーバ経由で記録する代表読み) のうち、コーパスに存在するケース
    /// あけるはコーパスに存在しないため未測定として別記する。
    private static let representativeIDs = [
        "shita-2", "kara-2", "maru-2", "kakeru-2",
        "hoshi-2", "kome-1", "yajirushi-1", "kagikakko-1",
        "kakko-1", "kakko-2",
    ]

    /// ユーザ辞書登録用の合成表記 (変換エンジン由来との区別を明確にするため)
    private static let userDictionarySurfaces: [String: String] = [
        "した": "思多",
        "から": "加羅",
        "まる": "円流",
        "かける": "駆流",
        "ほし": "星井",
        "こめ": "米惠",
        "やじるし": "矢路",
        "かぎかっこ": "鍵括子",
    ]

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
        unsetenv("HAZKEY_POSTAL_CODE_DICTIONARY")
        // 品質を固定するため期限なし (0)。モデルは環境変数から解決する。
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

    // MARK: - test

    func testSymbolConversionLearningStateEvaluation() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["HAZKEY_SYMBOL_EVAL_LEARNING"] == "1",
            "HAZKEY_SYMBOL_EVAL_LEARNING=1 のときだけ実行する")

        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: Self.corpusURL))
        let byID = Dictionary(uniqueKeysWithValues: corpus.cases.map { ($0.id, $0) })
        let cases = Self.representativeIDs.compactMap { byID[$0] }
        try XCTSkipIf(cases.isEmpty, "対象ケースがありません")

        let zenzaiFilter = environment["HAZKEY_SYMBOL_EVAL_LEARNING_ZENZAI"] ?? "off"
        let zenzaiModes: [Bool]
        switch zenzaiFilter {
        case "both": zenzaiModes = [false, true]
        case "on": zenzaiModes = [true]
        default: zenzaiModes = [false]
        }
        let pageSize = Int(environment["HAZKEY_SYMBOL_EVAL_LEARNING_PAGE"] ?? "9") ?? 9
        let outDirectory = environment["HAZKEY_SYMBOL_EVAL_LEARNING_OUT"]
            ?? "/tmp/opencode/symconv/learning-eval"

        var records: [[String: Any]] = []
        var notes: [String] = [
            "opt-in separate test; existing SymbolConversionEvaluationTests and product code are unchanged",
            "input=server kana typing (one inputChar per hiragana character); same left context via zenzaiLeftContext",
            "page size \(pageSize); non-suggest conversion only",
            "symbol promotion is the only special conversion enabled; emoji injection disabled (nonexistent emoji dictionary URL); relative date/calendar/time/number/mail/typography/unicode/version/halfwidth disabled",
            "learning enabled for all conditions (use_input_history=true, stop_store_new_history=false) so OFF/ON within a condition share the same learning setting",
            "OFF and ON are measured on the SAME shared converter and same established learning state; only special_conversion_mode.symbol is flipped, then loadSymbolDictionaryIfNeeded() is called",
            "UNLEARNED is a control measured in the same run (no commit, no user dictionary)",
            "TEMPORARY = commit a converter candidate, do not save; learning_data_needs_commit must be true",
            "PERSISTED = commit then saveLearningData(), then build fresh shared resources from the same isolated XDG_STATE_HOME; the learned word must be present and annotated (has_learning_entry)",
            "USER_DICT = write an isolated user_dictionary.tsv and enable use_user_dictionary; the registered synthetic surface must appear as a converter candidate with isFromUserDictionary metadata",
            "target word selection: first expectedWord at rank >= 3 (vulnerable to promotion), else any expectedWord, else the first full-reading non-symbol converter candidate at rank >= 3, else rank 0",
            "exact scalar comparison only (no normalization); 'wordLost' = word in OFF first page and absent from ON first page",
            "not measured: あける (absent from corpus); Zenzai ON when no model; natural-language quality of synthetic user-dict surfaces",
        ]

        for zenzai in zenzaiModes {
            // Zenzai可否は1回だけ確認する
            let probe = makeShared(symbol: false, zenzai: zenzai, useUserDictionary: false)
            let zenzaiAvailable = probe.serverConfig.zenzaiAvailable
            if zenzai && !zenzaiAvailable {
                notes.append("Zenzai ON was not available (backend devices or model missing); ON condition unmeasured")
                continue
            }

            for evalCase in cases {
                let tag = "\(evalCase.id)-z\(zenzai ? "on" : "off")"
                do {
                    let target = try selectTarget(
                        evalCase: evalCase, zenzai: zenzai, tag: tag, pageSize: pageSize)

                    records.append(
                        record(
                            condition: "unlearned", evalCase: evalCase, zenzai: zenzai,
                            target: target, off: target.unlearnedOff, on: target.unlearnedOn,
                            established: true, establishNote: "no commit; control",
                            extra: [:]))

                    // 一時学習
                    let temporary = try runTemporary(
                        evalCase: evalCase, target: target, zenzai: zenzai,
                        tag: "temporary-\(tag)", pageSize: pageSize)
                    records.append(
                        record(
                            condition: "temporary", evalCase: evalCase, zenzai: zenzai,
                            target: target, off: temporary.off, on: temporary.on,
                            established: temporary.established,
                            establishNote: temporary.note,
                            extra: [
                                "learningDirtyBeforeSave": temporary.dirtyBeforeSave,
                                "learningDirtyAfterMeasurement": temporary.dirtyAfterMeasurement,
                            ]))

                    // 永続学習
                    let persisted = try runPersisted(
                        evalCase: evalCase, target: target, zenzai: zenzai,
                        tag: "persisted-\(tag)", pageSize: pageSize)
                    records.append(
                        record(
                            condition: "persisted", evalCase: evalCase, zenzai: zenzai,
                            target: target, off: persisted.off, on: persisted.on,
                            established: persisted.established,
                            establishNote: persisted.note,
                            extra: [
                                "learningDirtyBeforeSave": persisted.dirtyBeforeSave,
                                "saveStatus": persisted.saveStatus,
                                "persistedHasLearningEntry": persisted.persistedAnnotation as Any,
                            ]))

                    // ユーザ辞書登録
                    let userDict = try runUserDictionary(
                        evalCase: evalCase, zenzai: zenzai, tag: "userdict-\(tag)",
                        pageSize: pageSize)
                    records.append(
                        record(
                            condition: "user_dictionary", evalCase: evalCase, zenzai: zenzai,
                            target: target, off: userDict.off, on: userDict.on,
                            established: userDict.established,
                            establishNote: userDict.note,
                            extra: [
                                "registeredWord": userDict.registeredWord,
                                "registeredProvenanceOff": userDict.infoOff.provenance,
                                "registeredProvenanceOn": userDict.infoOn.provenance,
                                "registeredPresentOff": userDict.infoOff.present,
                                "registeredPresentOn": userDict.infoOn.present,
                                "registeredIndexOff": userDict.infoOff.index ?? -1,
                                "registeredIndexOn": userDict.infoOn.index ?? -1,
                                "registeredInFirstPageOff": userDict.infoOff.inFirstPage,
                                "registeredInFirstPageOn": userDict.infoOn.inFirstPage,
                                "registeredIsUserDictOff": userDict.infoOff.isUserDict ?? false,
                                "registeredIsUserDictOn": userDict.infoOn.isUserDict ?? false,
                                "registeredHasLearningOff": userDict.infoOff.hasLearning ?? false,
                                "registeredHasLearningOn": userDict.infoOn.hasLearning ?? false,
                                "registeredDataCountOff": userDict.infoOff.dataCount ?? -1,
                                "registeredDataCountOn": userDict.infoOn.dataCount ?? -1,
                            ]))
                } catch {
                    records.append([
                        "condition": "error",
                        "caseID": evalCase.id,
                        "reading": evalCase.reading,
                        "context": evalCase.context,
                        "zenzai": zenzai ? "on" : "off",
                        "error": String(describing: error),
                    ])
                }
            }
        }

        let summary = summarize(records: records)
        for line in summary.lines { print(line) }

        let payload: [String: Any] = [
            "corpusVersion": corpus.version,
            "corpusDescription": corpus.description,
            "corpusFile": Self.corpusURL.path,
            "symbolDictionary": Self.symbolDictionaryURL.path,
            "zenzaiModel": ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"] ?? "(unset)",
            "zenzaiFilter": zenzaiFilter,
            "pageSize": pageSize,
            "representativeCases": cases.map { $0.id },
            "notes": notes,
            "summary": summary.dictionary,
            "records": records,
        ]
        try writeJSON(payload, to: outDirectory)
        print("WROTE \(outDirectory)/symbol-conversion-learning-eval.json")
    }

    // MARK: - shared resources

    /// 条件ごとにXDG状態・設定・キャッシュを分離する
    private func isolate(tag: String) throws {
        guard let root = temporaryDirectory else { throw SetupError.setEnvironmentFailed("root") }
        let safe = tag.replacingOccurrences(of: "/", with: "_")
        let state = root.appendingPathComponent("states/\(safe)")
        let config = root.appendingPathComponent("configs/\(safe)")
        let cache = root.appendingPathComponent("caches/\(safe)")
        for (key, url) in [
            ("XDG_STATE_HOME", state), ("XDG_CONFIG_HOME", config), ("XDG_CACHE_HOME", cache),
        ] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard setenv(key, url.path, 1) == 0 else {
                throw SetupError.setEnvironmentFailed(key)
            }
        }
    }

    private func makeShared(
        symbol: Bool, zenzai: Bool, useUserDictionary: Bool
    ) -> HazkeySharedResources {
        let shared = HazkeySharedResources(
            emojiDictionaryURL: Self.disabledEmojiDictionaryURL)
        shared.serverConfig.currentProfile.zenzaiEnable = zenzai
        shared.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        shared.serverConfig.currentProfile.useRichCandidates = false
        shared.serverConfig.currentProfile.useRichSuggestion = false
        shared.serverConfig.currentProfile.useTypoCorrection = false
        shared.serverConfig.currentProfile.usePostalCodeConversion = false
        shared.serverConfig.currentProfile.useUserDictionary = useUserDictionary
        shared.serverConfig.currentProfile.useInputHistory = true
        shared.serverConfig.currentProfile.stopStoreNewHistory = false
        shared.serverConfig.currentProfile.numCandidatesPerPage = 9
        // 記号以外の特殊変換を無効化して、学習・ユーザ辞書と記号の繰り上げだけを比較する
        shared.serverConfig.currentProfile.specialConversionMode.commaSeparatedNumber = false
        shared.serverConfig.currentProfile.specialConversionMode.mailDomain = false
        shared.serverConfig.currentProfile.specialConversionMode.calendar = false
        shared.serverConfig.currentProfile.specialConversionMode.time = false
        shared.serverConfig.currentProfile.specialConversionMode.romanTypography = false
        shared.serverConfig.currentProfile.specialConversionMode.unicodeCodepoint = false
        shared.serverConfig.currentProfile.specialConversionMode.hazkeyVersion = false
        shared.serverConfig.currentProfile.specialConversionMode.relativeDate = false
        shared.serverConfig.currentProfile.specialConversionMode.halfwidthKatakana = false
        shared.serverConfig.currentProfile.specialConversionMode.extendedEmoji = false
        shared.serverConfig.currentProfile.specialConversionMode.symbol = symbol
        shared.reinitializeConfiguration()
        if zenzai {
            shared.serverConfig.reloadZenzaiModel()
            shared.baseConvertRequestOptions = shared.serverConfig.genBaseConvertRequestOptions()
        }
        return shared
    }

    /// 記号だけを切り替える (同一shared・同一学習状態を保つ)
    private func enableSymbol(_ shared: HazkeySharedResources) {
        shared.serverConfig.currentProfile.specialConversionMode.symbol = true
        shared.loadSymbolDictionaryIfNeeded()
    }

    // MARK: - composition / observation

    private struct Observed {
        let texts: [String]
        let server: [DisplayedCandidate]
        let hasLearning: [Bool]
        let firstPage: ArraySlice<String>
        let firstPageIndices: Range<Int>
    }

    private func compose(_ state: HazkeyServerState, reading: String, context: String) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        state.zenzaiLeftContext = context
        for character in reading {
            XCTAssertEqual(
                state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.composingText.value.toHiragana(), reading)
    }

    private func observe(
        _ state: HazkeyServerState, pageSize: Int
    ) -> Observed {
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        let result = response.candidates
        let texts = result.candidates.map(\.text)
        let server = state.currentCandidateList ?? []
        XCTAssertEqual(texts.count, server.count)
        let effectivePage = max(1, Int(result.pageSize))
        XCTAssertEqual(effectivePage, pageSize)
        let n = min(pageSize, texts.count)
        return Observed(
            texts: texts,
            server: server,
            hasLearning: result.candidates.map(\.hasLearningEntry_p),
            firstPage: texts.prefix(n),
            firstPageIndices: 0..<n)
    }

    private func measure(
        shared: HazkeySharedResources, reading: String, context: String, pageSize: Int
    ) -> Observed {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        compose(state, reading: reading, context: context)
        return observe(state, pageSize: pageSize)
    }

    // MARK: - word lookup

    private static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    private static func sameScalars(_ lhs: String, _ rhs: String) -> Bool {
        scalars(lhs) == scalars(rhs)
    }

    private static func indexOf(_ observed: Observed, _ word: String) -> Int? {
        let key = scalars(word)
        return observed.texts.firstIndex { scalars($0) == key }
    }

    private static func inFirstPage(_ observed: Observed, _ word: String) -> Bool {
        observed.firstPage.contains { sameScalars($0, word) }
    }

    private struct WordInfo {
        let present: Bool
        let inFirstPage: Bool
        let index: Int?
        let hasLearning: Bool?
        let dataCount: Int?
        let rubyCount: Int?
        let provenance: String
        let isUserDict: Bool?
    }

    private static func wordInfo(_ observed: Observed, _ word: String) -> WordInfo {
        guard let index = indexOf(observed, word), observed.server.indices.contains(index) else {
            return WordInfo(
                present: false, inFirstPage: false, index: nil, hasLearning: nil,
                dataCount: nil, rubyCount: nil, provenance: "absent", isUserDict: nil)
        }
        let entry = observed.server[index]
        let hasLearning = observed.hasLearning.indices.contains(index)
            ? observed.hasLearning[index] : nil
        switch entry {
        case .fromConverter(let candidate):
            return WordInfo(
                present: true, inFirstPage: inFirstPage(observed, word), index: index,
                hasLearning: hasLearning, dataCount: candidate.data.count,
                rubyCount: candidate.rubyCount, provenance: "converter",
                isUserDict: candidate.data.contains {
                    $0.metadata.contains(.isFromUserDictionary)
                })
        case .fromTypoCorrection(let candidate, _, _):
            return WordInfo(
                present: true, inFirstPage: inFirstPage(observed, word), index: index,
                hasLearning: hasLearning, dataCount: candidate.data.count,
                rubyCount: candidate.rubyCount, provenance: "typoCorrection",
                isUserDict: candidate.data.contains {
                    $0.metadata.contains(.isFromUserDictionary)
                })
        case .fromUserDict:
            return WordInfo(
                present: true, inFirstPage: inFirstPage(observed, word), index: index,
                hasLearning: hasLearning, dataCount: nil, rubyCount: nil,
                provenance: "userDictLegacy", isUserDict: nil)
        case .fromDateProvider:
            return injected(observed, word, index, hasLearning, "date")
        case .fromKanaNumberProvider:
            return injected(observed, word, index, hasLearning, "kanaNumber")
        case .fromEmoji:
            return injected(observed, word, index, hasLearning, "emoji")
        case .fromPostalCode:
            return injected(observed, word, index, hasLearning, "postalCode")
        case .fromSymbol:
            return injected(observed, word, index, hasLearning, "symbol")
        }
    }

    private static func injected(
        _ observed: Observed, _ word: String, _ index: Int, _ hasLearning: Bool?, _ name: String
    ) -> WordInfo {
        WordInfo(
            present: true, inFirstPage: inFirstPage(observed, word), index: index,
            hasLearning: hasLearning, dataCount: nil, rubyCount: nil,
            provenance: name, isUserDict: nil)
    }

    // MARK: - target selection

    private struct Target {
        let word: String
        let reason: String
        let unlearnedOff: Observed
        let unlearnedOn: Observed
        let selectionIndex: Int?
    }

    private func selectTarget(
        evalCase: EvalCase, zenzai: Bool, tag: String, pageSize: Int
    ) throws -> Target {
        try isolate(tag: "select-\(tag)")
        let shared = makeShared(symbol: false, zenzai: zenzai, useUserDictionary: false)
        let off = measure(
            shared: shared, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)
        enableSymbol(shared)
        let on = measure(
            shared: shared, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)

        let expectedWords = evalCase.expectedWords ?? []
        // 1) rank >= 3のexpectedWord (繰り上げで押し出され得る位置)
        if let found = expectedWords.compactMap({ word -> (String, Int)? in
            guard let idx = Self.indexOf(off, word), off.server.indices.contains(idx),
                case .fromConverter = off.server[idx], idx >= 3
            else { return nil }
            return (word, idx)
        }).first {
            return Target(
                word: found.0, reason: "expectedWord at rank >= 3",
                unlearnedOff: off, unlearnedOn: on, selectionIndex: found.1)
        }
        // 2) 任意のexpectedWord
        if let found = expectedWords.compactMap({ word -> (String, Int)? in
            guard let idx = Self.indexOf(off, word), off.server.indices.contains(idx),
                case .fromConverter = off.server[idx]
            else { return nil }
            return (word, idx)
        }).first {
            return Target(
                word: found.0, reason: "expectedWord at rank < 3",
                unlearnedOff: off, unlearnedOn: on, selectionIndex: found.1)
        }
        // 3) rank >= 3の全読み・非記号のコンバータ候補
        let readingLength = evalCase.reading.count
        if let found = off.texts.indices.compactMap({ idx -> (String, Int)? in
            guard idx >= 3, idx < off.server.count,
                case .fromConverter(let candidate) = off.server[idx]
            else { return nil }
            guard candidate.rubyCount == readingLength,
                !SymbolCandidateClassifier.isSymbol(candidate.text)
            else { return nil }
            return (candidate.text, idx)
        }).first {
            return Target(
                word: found.0, reason: "fallback non-symbol full-reading converter at rank >= 3",
                unlearnedOff: off, unlearnedOn: on, selectionIndex: found.1)
        }
        // 4) rank 0
        let word = off.texts.first ?? evalCase.reading
        return Target(
            word: word, reason: "fallback rank 0",
            unlearnedOff: off, unlearnedOn: on, selectionIndex: 0)
    }

    // MARK: - conditions

    private struct TemporaryResult {
        let off: Observed
        let on: Observed
        let established: Bool
        let note: String
        let dirtyBeforeSave: Bool
        let dirtyAfterMeasurement: Bool
    }

    @discardableResult
    private func commit(
        word: String, evalCase: EvalCase, on shared: HazkeySharedResources
    ) -> Bool {
        let state = HazkeyServerState(shared: shared)
        defer { state.close() }
        compose(state, reading: evalCase.reading, context: evalCase.context)
        let observed = observe(state, pageSize: 9)
        guard let index = Self.indexOf(observed, word),
            observed.server.indices.contains(index),
            case .fromConverter = observed.server[index]
        else { return false }
        let response = state.completePrefix(candidateIndex: index)
        guard response.status == .success, state.learningDataNeedsCommit else { return false }
        return true
    }

    private func runTemporary(
        evalCase: EvalCase, target: Target, zenzai: Bool, tag: String, pageSize: Int
    ) throws -> TemporaryResult {
        try isolate(tag: tag)
        let shared = makeShared(symbol: false, zenzai: zenzai, useUserDictionary: false)
        let committed = commit(word: target.word, evalCase: evalCase, on: shared)
        let dirtyBefore = shared.learningDataNeedsCommit
        guard committed && dirtyBefore else {
            let off = measure(
                shared: shared, reading: evalCase.reading, context: evalCase.context,
                pageSize: pageSize)
            return TemporaryResult(
                off: off, on: off, established: false,
                note: "temporary learning not established (commit failed or dirty flag false)",
                dirtyBeforeSave: dirtyBefore, dirtyAfterMeasurement: dirtyBefore)
        }
        let off = measure(
            shared: shared, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)
        let info = Self.wordInfo(off, target.word)
        enableSymbol(shared)
        let on = measure(
            shared: shared, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)
        let established = info.present
        return TemporaryResult(
            off: off, on: on, established: established,
            note: established
                ? "committed converter candidate; learning_data_needs_commit=true; word present after commit"
                : "committed but word absent from post-commit candidate list",
            dirtyBeforeSave: dirtyBefore, dirtyAfterMeasurement: shared.learningDataNeedsCommit)
    }

    private struct PersistedResult {
        let off: Observed
        let on: Observed
        let established: Bool
        let note: String
        let dirtyBeforeSave: Bool
        let saveStatus: String
        let persistedAnnotation: Bool?
    }

    private func runPersisted(
        evalCase: EvalCase, target: Target, zenzai: Bool, tag: String, pageSize: Int
    ) throws -> PersistedResult {
        try isolate(tag: "\(tag)-build")
        let builder = makeShared(symbol: false, zenzai: zenzai, useUserDictionary: false)
        let committed = commit(word: target.word, evalCase: evalCase, on: builder)
        let dirtyBefore = builder.learningDataNeedsCommit
        guard committed && dirtyBefore else {
            let off = measure(
                shared: builder, reading: evalCase.reading, context: evalCase.context,
                pageSize: pageSize)
            return PersistedResult(
                off: off, on: off, established: false,
                note: "persistent learning not established (commit failed or dirty flag false)",
                dirtyBeforeSave: dirtyBefore, saveStatus: "not attempted",
                persistedAnnotation: nil)
        }
        let save = builder.saveLearningData()
        let saveStatus = save.status == .success ? "success" : "failed: \(save.errorMessage)"

        // 同じ隔離XDG_STATE_HOMEから独立した変換エンジンを再構築する
        let off = measure(
            shared: makeShared(symbol: false, zenzai: zenzai, useUserDictionary: false),
            reading: evalCase.reading, context: evalCase.context, pageSize: pageSize)
        let info = Self.wordInfo(off, target.word)
        let sharedOn = makeShared(symbol: false, zenzai: zenzai, useUserDictionary: false)
        enableSymbol(sharedOn)
        let on = measure(
            shared: sharedOn, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)
        let annotated = info.hasLearning
        let established = info.present && save.status == .success
        return PersistedResult(
            off: off, on: on, established: established,
            note: established
                ? "saved and rebuilt from disk; word present (has_learning_entry=\(String(describing: annotated)))"
                : "save or reload did not establish the persisted word",
            dirtyBeforeSave: dirtyBefore, saveStatus: saveStatus,
            persistedAnnotation: annotated)
    }

    private struct UserDictionaryResult {
        let off: Observed
        let on: Observed
        let established: Bool
        let note: String
        let registeredWord: String
        let infoOff: WordInfo
        let infoOn: WordInfo
    }

    private func runUserDictionary(
        evalCase: EvalCase, zenzai: Bool, tag: String, pageSize: Int
    ) throws -> UserDictionaryResult {
        try isolate(tag: tag)
        let registered = Self.userDictionarySurfaces[evalCase.reading]
            ?? (evalCase.reading + "語")
        let path = UserDictionary.defaultPath()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tsv = "# isolated synthetic registration for learning-state evaluation\n"
            + "\(evalCase.reading)\t\(registered)\n"
        try tsv.write(to: path, atomically: false, encoding: .utf8)

        let shared = makeShared(symbol: false, zenzai: zenzai, useUserDictionary: true)
        let off = measure(
            shared: shared, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)
        let infoOff = Self.wordInfo(off, registered)
        enableSymbol(shared)
        let on = measure(
            shared: shared, reading: evalCase.reading, context: evalCase.context,
            pageSize: pageSize)
        let infoOn = Self.wordInfo(on, registered)
        let established = infoOff.present && infoOff.provenance == "converter"
            && (infoOff.isUserDict ?? false)
        return UserDictionaryResult(
            off: off, on: on, established: established,
            note: established
                ? "registered synthetic surface appears as a converter candidate with isFromUserDictionary"
                : "registered surface not established (present=\(infoOff.present), provenance=\(infoOff.provenance), isUserDict=\(String(describing: infoOff.isUserDict)))",
            registeredWord: registered,
            infoOff: infoOff,
            infoOn: infoOn)
    }

    // MARK: - records

    private func record(
        condition: String, evalCase: EvalCase, zenzai: Bool, target: Target,
        off: Observed, on: Observed, established: Bool, establishNote: String,
        extra: [String: Any]
    ) -> [String: Any] {
        let expectedSymbols = evalCase.expectedSymbols ?? []
        let word = target.word
        let offInfo = Self.wordInfo(off, word)
        let onInfo = Self.wordInfo(on, word)
        let offSymbolHits = expectedSymbols.filter { Self.inFirstPage(off, $0) }
        let onSymbolHits = expectedSymbols.filter { Self.inFirstPage(on, $0) }
        let wordLost = offInfo.inFirstPage && !onInfo.inFirstPage
        let wordGained = !offInfo.inFirstPage && onInfo.inFirstPage
        let symbolGained = offSymbolHits.isEmpty && !onSymbolHits.isEmpty
        let symbolLost = !offSymbolHits.isEmpty && onSymbolHits.isEmpty
        var record: [String: Any] = [
            "condition": condition,
            "caseID": evalCase.id,
            "reading": evalCase.reading,
            "context": evalCase.context,
            "tier": evalCase.tier,
            "split": evalCase.split,
            "zenzai": zenzai ? "on" : "off",
            "targetWord": word,
            "targetReason": target.reason,
            "targetSelectionIndex": target.selectionIndex ?? -1,
            "expectedSymbols": expectedSymbols,
            "expectedWords": evalCase.expectedWords ?? [],
            "unlearnedOffTexts": Array(target.unlearnedOff.texts),
            "unlearnedOnTexts": Array(target.unlearnedOn.texts),
            "offTexts": Array(off.texts),
            "onTexts": Array(on.texts),
            "offFirstPage": Array(off.firstPage),
            "onFirstPage": Array(on.firstPage),
            "offWordPresent": offInfo.present,
            "onWordPresent": onInfo.present,
            "offWordInFirstPage": offInfo.inFirstPage,
            "onWordInFirstPage": onInfo.inFirstPage,
            "offWordIndex": offInfo.index ?? -1,
            "onWordIndex": onInfo.index ?? -1,
            "offWordHasLearning": offInfo.hasLearning ?? false,
            "onWordHasLearning": onInfo.hasLearning ?? false,
            "offWordDataCount": offInfo.dataCount ?? -1,
            "onWordDataCount": onInfo.dataCount ?? -1,
            "offWordRubyCount": offInfo.rubyCount ?? -1,
            "onWordRubyCount": onInfo.rubyCount ?? -1,
            "offWordProvenance": offInfo.provenance,
            "onWordProvenance": onInfo.provenance,
            "offWordIsUserDict": offInfo.isUserDict ?? false,
            "onWordIsUserDict": onInfo.isUserDict ?? false,
            "offSymbolHits": offSymbolHits,
            "onSymbolHits": onSymbolHits,
            "wordLost": wordLost,
            "wordGained": wordGained,
            "symbolGained": symbolGained,
            "symbolLost": symbolLost,
            "established": established,
            "establishNote": establishNote,
        ]
        for (key, value) in extra { record[key] = value }
        return record
    }

    // MARK: - summary

    private struct Summary {
        let dictionary: [[String: Any]]
        let lines: [String]
    }

    private func summarize(records: [[String: Any]]) -> Summary {
        struct Key: Hashable { let condition: String; let zenzai: String }
        struct Acc {
            var cases = 0
            var established = 0
            var offWordFirstPage = 0
            var onWordFirstPage = 0
            var wordLost = 0
            var wordGained = 0
            var offSymbolHit = 0
            var onSymbolHit = 0
            var symbolGained = 0
            var symbolLost = 0
            var offAnnotated = 0
            var onAnnotated = 0
            var targetIsUserDict = 0
            var registeredUserDict = 0
            var persistedAnnotated = 0
        }
        var accs: [Key: Acc] = [:]
        var lines: [String] = []
        for record in records {
            guard let condition = record["condition"] as? String,
                let zenzai = record["zenzai"] as? String,
                condition != "error"
            else { continue }
            let key = Key(condition: condition, zenzai: zenzai)
            var acc = accs[key] ?? Acc()
            acc.cases += 1
            if record["established"] as? Bool == true { acc.established += 1 }
            let offIn = record["offWordInFirstPage"] as? Bool == true
            let onIn = record["onWordInFirstPage"] as? Bool == true
            if offIn { acc.offWordFirstPage += 1 }
            if onIn { acc.onWordFirstPage += 1 }
            if record["wordLost"] as? Bool == true { acc.wordLost += 1 }
            if record["wordGained"] as? Bool == true { acc.wordGained += 1 }
            let offSymbols = record["offSymbolHits"] as? [String] ?? []
            let onSymbols = record["onSymbolHits"] as? [String] ?? []
            if !offSymbols.isEmpty { acc.offSymbolHit += 1 }
            if !onSymbols.isEmpty { acc.onSymbolHit += 1 }
            if record["symbolGained"] as? Bool == true { acc.symbolGained += 1 }
            if record["symbolLost"] as? Bool == true { acc.symbolLost += 1 }
            if record["offWordHasLearning"] as? Bool == true { acc.offAnnotated += 1 }
            if record["onWordHasLearning"] as? Bool == true { acc.onAnnotated += 1 }
            if record["offWordIsUserDict"] as? Bool == true { acc.targetIsUserDict += 1 }
            if record["registeredIsUserDictOff"] as? Bool == true,
                record["registeredIsUserDictOn"] as? Bool == true
            {
                acc.registeredUserDict += 1
            }
            if record["persistedHasLearningEntry"] as? Bool == true {
                acc.persistedAnnotated += 1
            }
            if condition != "error" {
                let offFP = (record["offFirstPage"] as? [String] ?? []).joined(separator: "|")
                let onFP = (record["onFirstPage"] as? [String] ?? []).joined(separator: "|")
                lines.append(
                    "CASE cond=\(condition) zenzai=\(zenzai) case=\(record["caseID"] ?? "?") "
                        + "target=\(record["targetWord"] ?? "?") "
                        + "offIdx=\(record["offWordIndex"] ?? -1) onIdx=\(record["onWordIndex"] ?? -1) "
                        + "offFP=\(offFP) onFP=\(onFP) "
                        + "wordLost=\(record["wordLost"] ?? false) "
                        + "symGained=\(record["symbolGained"] ?? false) "
                        + "offSym=\((record["offSymbolHits"] as? [String] ?? []).joined(separator: ",")) "
                        + "onSym=\((record["onSymbolHits"] as? [String] ?? []).joined(separator: ","))")
            }
            accs[key] = acc
        }
        let order = ["unlearned", "temporary", "persisted", "user_dictionary"]
        var dictionaries: [[String: Any]] = []
        for condition in order {
            for zenzai in ["off", "on"] {
                let key = Key(condition: condition, zenzai: zenzai)
                guard let acc = accs[key] else { continue }
                let dict: [String: Any] = [
                    "condition": condition,
                    "zenzai": zenzai,
                    "cases": acc.cases,
                    "established": acc.established,
                    "offWordFirstPage": acc.offWordFirstPage,
                    "onWordFirstPage": acc.onWordFirstPage,
                    "wordLost": acc.wordLost,
                    "wordGained": acc.wordGained,
                    "offSymbolHit": acc.offSymbolHit,
                    "onSymbolHit": acc.onSymbolHit,
                    "symbolGained": acc.symbolGained,
                    "symbolLost": acc.symbolLost,
                    "offWordAnnotated": acc.offAnnotated,
                    "onWordAnnotated": acc.onAnnotated,
                    "targetIsUserDict": acc.targetIsUserDict,
                    "registeredIsUserDict": acc.registeredUserDict,
                    "persistedAnnotated": acc.persistedAnnotated,
                ]
                dictionaries.append(dict)
                lines.append(
                    "LEARNING cond=\(condition) zenzai=\(zenzai) cases=\(acc.cases) "
                        + "established=\(acc.established) "
                        + "wordFirstPageOff=\(acc.offWordFirstPage) "
                        + "wordFirstPageOn=\(acc.onWordFirstPage) "
                        + "wordLost=\(acc.wordLost) wordGained=\(acc.wordGained) "
                        + "symbolHitOff=\(acc.offSymbolHit) symbolHitOn=\(acc.onSymbolHit) "
                        + "symbolGained=\(acc.symbolGained) symbolLost=\(acc.symbolLost) "
                        + "annotatedOff=\(acc.offAnnotated) annotatedOn=\(acc.onAnnotated) "
                        + "targetIsUserDict=\(acc.targetIsUserDict) "
                        + "registeredIsUserDict=\(acc.registeredUserDict) "
                        + "persistedAnnotated=\(acc.persistedAnnotated)")
            }
        }
        let errorCount = records.filter { ($0["condition"] as? String) == "error" }.count
        lines.append("LEARNING errors=\(errorCount)")
        return Summary(dictionary: dictionaries, lines: lines)
    }

    // MARK: - json

    private func writeJSON(_ payload: [String: Any], to directory: String) throws {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("symbol-conversion-learning-eval.json")
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

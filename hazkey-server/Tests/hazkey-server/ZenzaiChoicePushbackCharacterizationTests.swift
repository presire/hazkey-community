import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 選び直して確定した候補をZenzaiが押し戻すかを実モデルで計測する特性テスト
///
/// [HAZKEY_CHOICE_PUSHBACK_CHARACTERIZATION]が[1]のときだけ実行されるオプトインのテスト
///
/// fixtureごとに先頭でない候補を読み全体で確定し、学習なし・確定直後・学習の保存と変換エンジンの作り直し後の3時点で、
/// 確定時と同じ左文脈と対照の左文脈 (元の先頭候補が自然な文脈) の変換結果を観測する
///
/// 表示される候補が確定した表記でないか、候補一覧に残るか、対照の文脈で確定した表記へ変わるかを記録するだけで、
/// 正しさとしては主張しない
///
/// 入力条件は一発変換・予測サジェスト・通常サジェスト・間引きサジェスト・サジェスト後スペース確定・
/// 保留サジェスト取消後スペース確定の11条件である
/// 間引きサジェストは3打鍵ごとと最終打鍵だけ要求する、疎な要求列での感度試験である
/// Fcitx 5の要求間引き ([candidate_refresh_coalescer.h] の [hazkey::frontend::CandidateRefreshCoalescer]) は
/// 最初の要求を即時に通して30ms以内の連続要求を1つの後続要求へまとめるため、要求列は一致しない (最初の要求が3打鍵目になる)
/// サジェスト後スペース確定は、全打鍵のサジェスト (ライブ変換) の後に非サジェストを1回だけ要求する
/// 最後の打鍵のサジェストが実行済みの経路である
/// 保留サジェスト取消後スペース確定は、最後の打鍵を除く全打鍵のサジェストの後に非サジェストを1回だけ要求する
/// Fcitx 5 / IBus のスペースは、保留中のサジェスト (直前の変換中または完了後30ms以内に届いた打鍵の分) を実行せずに取り消してから
/// 非サジェストを要求する ([showNonPredictCandidateList] 内の [cancelPendingRefresh]) ため、最後の打鍵のサジェストは送られない
/// 取り消される打鍵は、最小の1打鍵だけを再現する (遅い変換の間に複数の打鍵が届いた場合は、さらに多くの打鍵の分が送られない)
///
/// 同音異義語と固有名詞では、学習の代わりにユーザ辞書へ目標表記を登録した比較も行う
/// ユーザ辞書の比較は確定なしでU (確定時文脈) とUc (対照文脈) だけを観測する
///
/// - Note: 対象モデルは[HAZKEY_ZENZAI_MODEL]で受け取る。Zenzai OFF の比較も同じ確定対象で計測する
/// - Note: [HAZKEY_PERF_EVIDENCE]を設定して実行した場合だけ、最後の要求のZenzaiの再下書き・再試行の回数も記録する
/// - Note: 作り直し後もZenzaiのモデルとKVキャッシュはプロセス内で共有されるため、真のプロセス再起動ではない
/// - Note: DEBUGビルドでは、変換エンジンが学習を無視して再試行した時に出すログを、直前の[MARK]行で観測条件と対応付けられる
final class ZenzaiChoicePushbackCharacterizationTests: XCTestCase {
    /// 確定する表記と、確定時と対照の左文脈
    private struct Option {
        /// 確定する表記 (空の場合は、確定時の文脈で先頭でない最上位の読み全体の候補を選ぶ)
        let target: String
        /// 確定時の左文脈 (確定済みの表記)
        let chooseLeft: String
        /// 確定した表記が不自然になる左文脈 (確定済みの表記)
        let contrastLeft: String
        /// 先頭でない最上位の候補を代わりに選んだ場合はtrue (対照の文脈との意味の対応が無い)
        var isFallback = false
        /// ユーザ辞書の比較計測で使う品詞 (userDictionary.swift の既知トークン)
        var userDictionaryPos = "noun"
    }

    /// 1つの読みと確定対象の候補群
    private struct Fixture {
        /// 分類 (同音異義語・固有名詞・複数文節)
        let category: String
        /// 入力するローマ字の打鍵列
        let keystrokes: String
        /// 打鍵列が生成する読み (読み全体の候補の判定に使う)
        let reading: String
        /// 確定対象の候補 (確定時の文脈で先頭でない最初の候補を使う)
        let options: [Option]
    }

    /// 観測する入力条件
    private enum Condition: String, CaseIterable {
        case oneshot = "oneshot"
        case oneshotRich = "oneshot_rich"
        case suggestPrediction = "suggest_pred"
        case suggestPredictionRich = "suggest_pred_rich"
        case suggestNormal = "suggest_normal"
        case suggestNormalRich = "suggest_normal_rich"
        /// 3打鍵ごとと最終打鍵だけ要求する間引きサジェスト (疎な要求列での感度試験)
        ///
        /// [hazkey-frontend-common/candidate_refresh_coalescer.h]の[CandidateRefreshCoalescer]は最初の要求を即時に実行し、30ms以内の打鍵を1回の遅延要求へまとめるため、要求列はFcitx 5と一致しない
        case suggestNormalSparse = "suggest_normal_sparse"
        case suggestThenSpace = "suggest_then_space"
        case suggestThenSpaceRich = "suggest_then_space_rich"
        /// 最後の打鍵のサジェストを送らずに非サジェストを1回だけ要求する (保留中のライブ変換をスペースが取り消す経路)
        case suggestCancelSpace = "suggest_cancel_space"
        case suggestCancelSpaceRich = "suggest_cancel_space_rich"

        /// サジェストを送らない末尾の打鍵数 (スペースが取り消す保留中のサジェストの分)
        var cancelledTrailingKeys: Int {
            switch self {
            case .suggestCancelSpace, .suggestCancelSpaceRich: 1
            default: 0
            }
        }

        /// 打鍵ごとのサジェスト要求の間隔 (nilの場合は打鍵ごとに要求しない)
        var suggestionStride: Int? {
            switch self {
            case .oneshot, .oneshotRich: nil
            case .suggestNormalSparse: 3
            default: 1
            }
        }

        /// 最後に非サジェストを1回だけ要求する (スペース確定) 場合はtrue
        var endsWithSpace: Bool {
            switch self {
            case .suggestThenSpace, .suggestThenSpaceRich, .suggestCancelSpace, .suggestCancelSpaceRich: true
            default: false
            }
        }

        /// ライブ変換の表示を観測結果にする (サジェスト条件) 場合はtrue
        var displaysLiveText: Bool {
            switch self {
            case .oneshot, .oneshotRich, .suggestThenSpace, .suggestThenSpaceRich, .suggestCancelSpace,
                .suggestCancelSpaceRich:
                false
            default: true
            }
        }

        /// rich 候補 (非サジェスト) または rich サジェストを使う場合はtrue
        var rich: Bool {
            switch self {
            case .oneshotRich, .suggestPredictionRich, .suggestNormalRich, .suggestThenSpaceRich,
                .suggestCancelSpaceRich:
                true
            default: false
            }
        }

        /// 予測変換の結果を含めて表示する場合はtrue (サジェストのみ)
        var prediction: Bool {
            switch self {
            case .suggestPrediction, .suggestPredictionRich: true
            default: false
            }
        }
    }

    /// 1条件の観測結果
    private struct Observation {
        /// 利用者に表示される変換結果 (非サジェストは先頭候補、サジェストはライブ変換、ライブ変換が無ければ生かな)
        var displayed: String
        /// 候補一覧の先頭
        var first: String
        /// 確定した表記 (読み全体) の、表示される候補一覧での位置 (無い場合は-1)
        var clientRank: Int
        /// 確定した表記 (読み全体) の、確定用に保持する候補 (ライブ変換用の非表示分を含む) での位置 (無い場合は-1)
        var serverRank: Int
        /// 表示される候補一覧の件数
        var listed: Int
        /// 読み全体の最上位候補が学習由来の単語を含む場合はtrue
        var learnedTop: Bool
        /// 確定した表記の候補が学習由来の単語を含む場合はtrue
        var targetLearned: Bool
        /// 最後の要求の再下書き・再試行・候補評価の回数 (計測無効時はnil)
        var lastRedraft: Int?
        var lastRetry: Int?
        var lastEvaluation: Int?
        /// 条件全体の壁時間 [ms]
        var ms: Double
    }

    /// 観測する時点と文脈
    private enum Phase: String, CaseIterable {
        case baseline = "P0"
        case baselineContrast = "P0c"
        case afterChoice = "P1"
        case afterChoiceContrast = "P1c"
        case afterRecreation = "P2"
        case afterRecreationContrast = "P2c"
        /// ユーザ辞書の比較計測の確定時文脈 (確定は行わない)
        case userDict = "U"
        /// ユーザ辞書の比較計測の対照文脈 (確定は行わない)
        case userDictContrast = "Uc"

        /// 対照の左文脈で観測する場合はtrue
        var isContrast: Bool { rawValue.hasSuffix("c") }
    }

    /// 1つのfixture・Zenzaiの動作・入力条件の結果
    private struct ConditionResult {
        var baseline: String
        var afterChoice: String
        var afterRecreation: String
        var clientRankAfterChoice: Int
        var clientRankAfterRecreation: Int
        var baselineContrast: String
        var afterChoiceContrast: String
        var afterRecreationContrast: String
        /// ユーザ辞書の比較計測での確定時文脈 (U) の表示 (学習計測の結果ではnil)
        var userDict: String? = nil
        /// ユーザ辞書の比較計測での対照文脈 (Uc) の表示 (学習計測の結果ではnil)
        var userDictContrast: String? = nil
        /// ユーザ辞書の比較計測での確定時文脈 (U) の、表示される候補一覧での位置 (無い場合は-1。学習計測の結果ではnil)
        var userDictClientRank: Int? = nil
    }

    /// 1つのfixture・Zenzaiの動作の計測結果
    private struct FixtureResult {
        var option: Option
        var conditions: [Condition: ConditionResult]
    }

    /// 条件別の集計 (Zenzai ON / OFF の両方で計測を終えたfixtureだけを数える)
    private struct Tally {
        var fixtures = 0
        var notShownAfterChoice = 0
        var notShownAfterRecreation = 0
        var notListedAfterChoice = 0
        var notListedAfterRecreation = 0
        var contrastCases = 0
        var changedInContrastAfterChoice = 0
        var changedInContrastAfterRecreation = 0
        /// Zenzai ONで表示されずOFFで表示された件数 (Zenzai特有の押し戻しの候補。ONの集計にだけ数える)
        var onlyWithZenzaiAfterChoice = 0
        var onlyWithZenzaiAfterRecreation = 0
    }

    /// ユーザ辞書の比較計測の条件別の集計 (確定は行わない)
    private struct UserDictTally {
        /// 計測を終えたfixture数
        var fixtures = 0
        /// 確定時文脈 (U) で目標表記が表示されなかった件数
        var notShown = 0
        /// 確定時文脈 (U) で目標表記が表示される候補一覧に無かった件数
        var notListed = 0
        /// 対照文脈の学習計測 (P0c) が目標表記でなかったもののうち、対照文脈 (Uc) で目標表記が表示された件数
        var contrastPinned = 0
        /// 対照文脈の学習計測 (P0c) が目標表記でなかった件数 (対照文脈でユーザ辞書が効く余地がある件数)
        var baselineContrastDiffers = 0
    }

    /// 計測が中止された理由
    private struct MeasurementError: Error, CustomStringConvertible {
        let description: String
    }

    private let fixtures: [Fixture] = [
        Fixture(category: "homophone", keystrokes: "kouenn", reading: "こうえん", options: [
            Option(target: "講演", chooseLeft: "明日の午後に", contrastLeft: "子供と近くの"),
            Option(target: "公園", chooseLeft: "明日の午後に", contrastLeft: "大学教授の"),
        ]),
        Fixture(category: "homophone", keystrokes: "kikai", reading: "きかい", options: [
            Option(target: "機械", chooseLeft: "これは良い", contrastLeft: "またとない"),
            Option(target: "機会", chooseLeft: "これは良い", contrastLeft: "工場の"),
        ]),
        Fixture(category: "homophone", keystrokes: "kannshinn", reading: "かんしん", options: [
            Option(target: "感心", chooseLeft: "彼には", contrastLeft: "政治への"),
            Option(target: "関心", chooseLeft: "彼には", contrastLeft: "その努力には本当に"),
        ]),
        Fixture(category: "homophone", keystrokes: "seikaku", reading: "せいかく", options: [
            Option(target: "正確", chooseLeft: "彼女は", contrastLeft: "明るい"),
            Option(target: "性格", chooseLeft: "彼女は", contrastLeft: "時計がとても"),
        ]),
        Fixture(category: "homophone", keystrokes: "hoshou", reading: "ほしょう", options: [
            Option(target: "保障", chooseLeft: "その", contrastLeft: "商品の"),
            Option(target: "保証", chooseLeft: "その", contrastLeft: "社会"),
        ]),
        Fixture(category: "homophone", keystrokes: "katei", reading: "かてい", options: [
            Option(target: "過程", chooseLeft: "その", contrastLeft: "温かい"),
            Option(target: "家庭", chooseLeft: "その", contrastLeft: "生産の"),
        ]),
        Fixture(category: "proper", keystrokes: "yuuki", reading: "ゆうき", options: [
            Option(target: "結城", chooseLeft: "昨日", contrastLeft: "頑張るための", userDictionaryPos: "person"),
            Option(target: "優希", chooseLeft: "昨日", contrastLeft: "頑張るための", userDictionaryPos: "person"),
        ]),
        Fixture(category: "proper", keystrokes: "satou", reading: "さとう", options: [
            Option(target: "砂糖", chooseLeft: "これは", contrastLeft: "山田さんと"),
            Option(target: "佐藤", chooseLeft: "これは", contrastLeft: "紅茶に", userDictionaryPos: "person"),
        ]),
        Fixture(category: "proper", keystrokes: "aoi", reading: "あおい", options: [
            Option(target: "葵", chooseLeft: "私は", contrastLeft: "空が", userDictionaryPos: "person"),
            Option(target: "蒼井", chooseLeft: "私は", contrastLeft: "空が", userDictionaryPos: "person"),
        ]),
        Fixture(category: "proper", keystrokes: "kaoru", reading: "かおる", options: [
            Option(target: "薫", chooseLeft: "明日は", contrastLeft: "花が", userDictionaryPos: "person"),
            Option(target: "馨", chooseLeft: "明日は", contrastLeft: "花が", userDictionaryPos: "person"),
        ]),
        Fixture(category: "multi", keystrokes: "ashitakouennniiku", reading: "あしたこうえんにいく", options: [
            Option(target: "明日講演に行く", chooseLeft: "", contrastLeft: "天気が良いので子供と"),
            Option(target: "明日公園に行く", chooseLeft: "", contrastLeft: "学会で"),
        ]),
        Fixture(category: "multi", keystrokes: "koukaishitakunai", reading: "こうかいしたくない", options: [
            Option(target: "公開したくない", chooseLeft: "絶対に", contrastLeft: "人生で"),
            Option(target: "後悔したくない", chooseLeft: "絶対に", contrastLeft: "この動画は"),
        ]),
        Fixture(category: "multi", keystrokes: "ishiwotsutaeru", reading: "いしをつたえる", options: [
            Option(target: "遺志を伝える", chooseLeft: "彼に", contrastLeft: "自分の"),
            Option(target: "意思を伝える", chooseLeft: "彼に", contrastLeft: "亡くなった父の"),
            Option(target: "意志を伝える", chooseLeft: "彼に", contrastLeft: "亡くなった父の"),
        ]),
        Fixture(category: "multi", keystrokes: "kishagakishadekishashita", reading: "きしゃがきしゃできしゃした", options: [
            Option(target: "", chooseLeft: "", contrastLeft: "新聞社の"),
        ]),
    ]

    /// 性能記録ファイルの読み取り済み位置
    private var perfOffset: UInt64 = 0

    /// 一時ディレクトリ上に、学習・設定・辞書の保存先を隔離した環境を作って渡す
    ///
    /// 同じ環境で接続状態を作り直すと、保存済みの学習を新しい変換エンジンが読み込んだ状態になる
    ///
    /// - Parameter body: 隔離した環境で実行する処理
    /// - Throws: 一時領域の作成失敗や[body]が投げるエラー
    private func withIsolatedRoot(_ body: () throws -> Void) throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment: [String: String] = [:]
        for (variable, directory) in [
            "XDG_DATA_HOME": "data", "XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime", "XDG_STATE_HOME": "state",
        ] {
            let path = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            environment[variable] = path.path
        }
        environment["HAZKEY_DICTIONARY"] = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        let original = ProcessInfo.processInfo.environment
        defer {
            for variable in environment.keys {
                if let value = original[variable] { setenv(variable, value, 1) }
                else { unsetenv(variable) }
            }
        }
        for (variable, value) in environment { XCTAssertEqual(setenv(variable, value, 1), 0) }
        try body()
    }

    /// 学習を有効にした接続状態を作る
    ///
    /// Zenzai ON の場合は、モデルの読み込みと実際の変換まで成功したことを確かめる (失敗時は計測を中止する)
    ///
    /// - Parameters:
    ///   - zenzaiOn: Zenzaiを使う場合はtrue (モデルは[CPU]固定で読み込む)
    ///   - modelURL: 実体へ解決済みの検証対象モデル
    ///   - useUserDictionary: ユーザ辞書を有効にする場合はtrue (比較計測用。TSVは呼び出し側で隔離rootへ先に書く)
    /// - Returns: 作成した接続状態
    /// - Throws: Zenzaiのモデルを読み込めなかった場合
    private func makeState(zenzaiOn: Bool, modelURL: URL, useUserDictionary: Bool = false) throws -> HazkeyServerState {
        let state = HazkeyServerState()
        state.serverConfig.currentProfile.zenzaiEnable = zenzaiOn
        state.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        state.serverConfig.currentProfile.zenzaiContextualMode = true
        state.serverConfig.currentProfile.useInputHistory = true
        state.serverConfig.currentProfile.stopStoreNewHistory = false
        state.serverConfig.currentProfile.useUserDictionary = useUserDictionary
        state.serverConfig.currentProfile.useTypoCorrection = false
        state.serverConfig.currentProfile.useZenzaiCustomWeight = true
        state.serverConfig.currentProfile.zenzaiWeightPath = modelURL.path
        state.baseConvertRequestOptions = state.serverConfig.genBaseConvertRequestOptions()
        if zenzaiOn {
            let reload = state.reloadZenzaiModel()
            guard reload.status == .success, state.serverConfig.zenzaiAvailable else {
                state.close()
                throw MeasurementError(description: "zenzai model failed to load: \(reload.errorMessage)")
            }
        }
        return state
    }

    /// 候補を要求し、性能記録が有効なら要求の回数を読み取る
    ///
    /// - Parameters:
    ///   - isSuggest: サジェスト (ライブ変換) の場合はtrue
    ///   - state: 処理を受け持つ接続状態
    /// - Returns: 応答と回数 (性能記録が無効な場合はnil)
    private func requestCandidates(
        isSuggest: Bool, in state: HazkeyServerState
    ) -> (Hazkey_ResponseEnvelope, [String: Int]?) {
        guard let probe = PerfProbe.shared else { return (state.getCandidates(is_suggest: isSuggest), nil) }
        let measurement = probe.begin(type: "get_candidates")
        let response = state.getCandidates(is_suggest: isSuggest)
        probe.finish(measurement)
        return (response, latestPerfCounters())
    }

    /// 性能記録ファイルの未読部分から最後の行の回数を読み取る
    ///
    /// - Returns: 最後の行の回数 (読めない場合はnil)
    private func latestPerfCounters() -> [String: Int]? {
        guard let path = ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"],
            let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: perfOffset)) != nil, let data = try? handle.readToEnd() else {
            return nil
        }
        perfOffset += UInt64(data.count)
        guard let line = data.split(separator: 0x0A).last,
            let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else { return nil }
        return object["counters"] as? [String: Int]
    }

    /// 読み全体の変換エンジン由来の候補を探す
    ///
    /// - Parameters:
    ///   - reading: 入力した読み
    ///   - limit: 探す件数 (nilの場合は確定用に保持する全候補)
    ///   - state: 処理を受け持つ接続状態
    ///   - predicate: 候補の条件
    /// - Returns: 候補一覧での位置
    private func wholeReadingIndex(
        _ reading: String, limit: Int? = nil, in state: HazkeyServerState, where predicate: (Candidate) -> Bool
    ) -> Int? {
        let list = state.currentCandidateList ?? []
        return list.prefix(limit ?? list.count).firstIndex { entry in
            if case .fromConverter(let candidate) = entry {
                return candidate.rubyCount == reading.count && predicate(candidate)
            }
            return false
        }
    }

    /// 候補が学習由来の単語を含む場合はtrue
    private func isLearned(_ candidate: Candidate) -> Bool {
        candidate.data.contains { $0.metadata.contains(.isLearned) }
    }

    /// 組成を作り直し、左文脈を設定してから打鍵列を入力する
    ///
    /// 組成の作り直しは左文脈を消去するため、左文脈は作り直しの直後かつ打鍵の前に設定する
    ///
    /// - Parameters:
    ///   - fixture: 入力する打鍵列と読み
    ///   - left: 左文脈
    ///   - state: 処理を受け持つ接続状態
    ///   - afterEachKey: 打鍵ごとに実行する処理
    private func type(
        _ fixture: Fixture, left: String, in state: HazkeyServerState, afterEachKey: () -> Void = {}
    ) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        state.zenzaiLeftContext = left
        for key in fixture.keystrokes {
            XCTAssertEqual(state.inputChar(inputString: String(key)).status, .success)
            afterEachKey()
        }
        XCTAssertEqual(
            state.composingText.value.convertTarget, fixture.reading,
            "keystrokes must produce the reading")
    }

    /// 1条件を入力して観測する
    ///
    /// - Parameters:
    ///   - fixture: 入力する打鍵列と読み
    ///   - left: 左文脈
    ///   - target: 確定した (する) 表記
    ///   - condition: 入力条件
    ///   - state: 処理を受け持つ接続状態
    /// - Returns: 観測結果
    private func observe(
        _ fixture: Fixture, left: String, target: String, condition: Condition, in state: HazkeyServerState
    ) -> Observation {
        state.serverConfig.currentProfile.useRichCandidates = condition.rich
        state.serverConfig.currentProfile.useRichSuggestion = condition.rich
        state.serverConfig.currentProfile.suggestionListMode =
            condition.prediction ? .suggestionListShowPredictiveResults : .suggestionListShowNormalResults
        let started = Date()
        var last: (Hazkey_ResponseEnvelope, [String: Int]?)?
        var keyIndex = 0
        let totalKeys = fixture.keystrokes.count
        type(fixture, left: left, in: state) {
            keyIndex += 1
            if let stride = condition.suggestionStride, keyIndex % stride == 0 || keyIndex == totalKeys,
                keyIndex <= totalKeys - condition.cancelledTrailingKeys
            {
                last = requestCandidates(isSuggest: true, in: state)
            }
        }
        if condition.endsWithSpace || condition.suggestionStride == nil {
            last = requestCandidates(isSuggest: false, in: state)
        }
        let ms = Date().timeIntervalSince(started) * 1000
        let response = last?.0 ?? Hazkey_ResponseEnvelope()
        let counters = last?.1
        XCTAssertEqual(response.status, .success)
        let result = response.candidates
        XCTAssertGreaterThanOrEqual(result.candidates.count, 1, "every condition must yield >=1 candidate")
        let first = result.candidates.first?.text ?? ""
        // Fcitx 5 はライブ変換が無い場合に生かなを表示する
        let live = result.liveTextIndex >= 0 && !result.liveText.isEmpty ? result.liveText : fixture.reading
        let list = state.currentCandidateList ?? []
        let clientRank = target.isEmpty
            ? nil : wholeReadingIndex(fixture.reading, limit: result.candidates.count, in: state) { $0.text == target }
        let serverRank = target.isEmpty ? nil : wholeReadingIndex(fixture.reading, in: state) { $0.text == target }
        var learnedTop = false
        var targetLearned = false
        if let topIndex = wholeReadingIndex(fixture.reading, in: state, where: { _ in true }),
            case .fromConverter(let candidate) = list[topIndex]
        {
            learnedTop = isLearned(candidate)
        }
        if let serverRank, case .fromConverter(let candidate) = list[serverRank] {
            targetLearned = isLearned(candidate)
        }
        return Observation(
            displayed: condition.displaysLiveText ? live : first,
            first: first,
            clientRank: clientRank ?? -1,
            serverRank: serverRank ?? -1,
            listed: result.candidates.count,
            learnedTop: learnedTop,
            targetLearned: targetLearned,
            lastRedraft: counters?["zenzai_redraft_count"],
            lastRetry: counters?["zenzai_retry_count"],
            lastEvaluation: counters?["zenzai_evaluation_count"],
            ms: ms)
    }

    /// 確定対象を決める
    ///
    /// 確定時の文脈で表示される先頭でない最初の候補を選び、無ければ先頭でない最上位の読み全体の候補を選ぶ
    ///
    /// - Parameters:
    ///   - fixture: 対象の読みと確定対象の候補群
    ///   - state: 処理を受け持つ接続状態
    /// - Returns: 確定対象 (読み全体の候補が先頭しか無い場合はnil)
    private func selectOption(for fixture: Fixture, in state: HazkeyServerState) -> Option? {
        for option in fixture.options where !option.target.isEmpty {
            let observation = observe(
                fixture, left: option.chooseLeft, target: option.target, condition: .oneshot, in: state)
            if observation.clientRank >= 0 && observation.displayed != option.target { return option }
        }
        guard let template = fixture.options.first else { return nil }
        let observation = observe(fixture, left: template.chooseLeft, target: "", condition: .oneshot, in: state)
        guard
            let index = wholeReadingIndex(
                fixture.reading, limit: observation.listed, in: state, where: { $0.text != observation.displayed }),
            case .fromConverter(let candidate) = (state.currentCandidateList ?? [])[index]
        else { return nil }
        return Option(
            target: candidate.text, chooseLeft: template.chooseLeft, contrastLeft: template.contrastLeft,
            isFallback: true)
    }

    /// 確定した候補の各単語が保存済みの学習に含まれる数を数える
    ///
    /// - Parameters:
    ///   - words: 確定した候補の単語 (カタカナの読みと表記)
    ///   - state: 処理を受け持つ接続状態
    /// - Returns: 保存済みの単語数 (照会に失敗した場合は-1)
    private func persistedWordCount(_ words: [LearningSurfaceKey], in state: HazkeyServerState) -> Int {
        guard let keys = try? state.shared.learningSurfaceKeys(forReadings: words.map(\.reading)) else { return -1 }
        return words.filter { keys.contains($0) }.count
    }

    /// 1つのfixtureを、学習なし・確定直後・変換エンジンの作り直し後の3時点で計測する
    ///
    /// - Parameters:
    ///   - fixture: 対象の読み
    ///   - zenzaiOn: Zenzaiを使う場合はtrue
    ///   - forced: 確定対象 (nilの場合はこの計測で決める)
    ///   - modelURL: 実体へ解決済みの検証対象モデル
    /// - Returns: 計測結果 (確定対象が無い・確定できなかった場合はnil)
    /// - Throws: 隔離環境の作成失敗やZenzaiのモデルの読み込み失敗
    private func measure(_ fixture: Fixture, zenzaiOn: Bool, forced: Option?, modelURL: URL) throws -> FixtureResult? {
        let mode = zenzaiOn ? "on" : "off"
        var fixtureResult: FixtureResult?
        try withIsolatedRoot {
            var state = try makeState(zenzaiOn: zenzaiOn, modelURL: modelURL)
            defer { state.close() }
            guard let option = forced ?? selectOption(for: fixture, in: state) else {
                print("SKIP zenzai=\(mode) fixture=\(fixture.reading) reason=no-non-top-whole-reading-candidate")
                return
            }
            var observations: [Phase: [Condition: Observation]] = [:]
            func record(_ phase: Phase) {
                let left = phase.isContrast ? option.contrastLeft : option.chooseLeft
                for condition in Condition.allCases {
                    print("MARK zenzai=\(mode) fixture=\(fixture.reading) phase=\(phase.rawValue) cond=\(condition.rawValue)")
                    let o = observe(fixture, left: left, target: option.target, condition: condition, in: state)
                    observations[phase, default: [:]][condition] = o
                    print(
                        "ROW zenzai=\(mode) cat=\(fixture.category) fixture=\(fixture.reading) target=\(option.target)"
                            + " fallback=\(option.isFallback ? 1 : 0) phase=\(phase.rawValue)"
                            + " left=\(left.isEmpty ? "-" : left) cond=\(condition.rawValue)"
                            + " displayed=\(o.displayed) first=\(o.first)"
                            + " clientRank=\(o.clientRank) serverRank=\(o.serverRank) listed=\(o.listed)"
                            + " learnedTop=\(o.learnedTop ? 1 : 0) targetLearned=\(o.targetLearned ? 1 : 0)"
                            + " lastRedraft=\(o.lastRedraft.map(String.init) ?? "-")"
                            + " lastRetry=\(o.lastRetry.map(String.init) ?? "-")"
                            + " lastEval=\(o.lastEvaluation.map(String.init) ?? "-") ms=\(Int(o.ms))")
                }
            }

            record(.baseline)
            record(.baselineContrast)

            // 利用者の操作と同じく、確定時の文脈で非サジェストの候補一覧から読み全体の候補を選んで確定する
            state.serverConfig.currentProfile.useRichCandidates = false
            type(fixture, left: option.chooseLeft, in: state)
            let listed = state.getCandidates(is_suggest: false).candidates.candidates.count
            guard
                let index = wholeReadingIndex(
                    fixture.reading, limit: listed, in: state, where: { $0.text == option.target }),
                case .fromConverter(let committed) = (state.currentCandidateList ?? [])[index]
            else {
                print("SKIP zenzai=\(mode) fixture=\(fixture.reading) reason=target-not-listed-at-commit")
                return
            }
            let words = committed.data.map { LearningSurfaceKey(reading: $0.ruby, word: $0.word) }
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            print(
                "COMMIT zenzai=\(mode) fixture=\(fixture.reading) target=\(option.target) index=\(index)"
                    + " words=\(words.map { "\($0.word)/\($0.reading)" })")

            record(.afterChoice)
            record(.afterChoiceContrast)

            XCTAssertEqual(state.saveLearningData().status, .success)
            let savedCount = persistedWordCount(words, in: state)
            state.close()
            state = try makeState(zenzaiOn: zenzaiOn, modelURL: modelURL)
            let reloadedCount = persistedWordCount(words, in: state)
            XCTAssertGreaterThan(reloadedCount, 0, "the committed words must be persisted and reloaded")
            print(
                "SAVED zenzai=\(mode) fixture=\(fixture.reading) persistedWords=\(savedCount)/\(words.count)"
                    + " reloadedWords=\(reloadedCount)/\(words.count)")

            record(.afterRecreation)
            record(.afterRecreationContrast)

            var conditions: [Condition: ConditionResult] = [:]
            for condition in Condition.allCases {
                func value(_ phase: Phase) -> Observation? { observations[phase]?[condition] }
                guard let p0 = value(.baseline), let p0c = value(.baselineContrast),
                    let p1 = value(.afterChoice), let p1c = value(.afterChoiceContrast),
                    let p2 = value(.afterRecreation), let p2c = value(.afterRecreationContrast)
                else { continue }
                conditions[condition] = ConditionResult(
                    baseline: p0.displayed, afterChoice: p1.displayed, afterRecreation: p2.displayed,
                    clientRankAfterChoice: p1.clientRank, clientRankAfterRecreation: p2.clientRank,
                    baselineContrast: p0c.displayed, afterChoiceContrast: p1c.displayed,
                    afterRecreationContrast: p2c.displayed)
                print(
                    "SUMMARY zenzai=\(mode) cat=\(fixture.category) fixture=\(fixture.reading) target=\(option.target)"
                        + " fallback=\(option.isFallback ? 1 : 0) cond=\(condition.rawValue)"
                        + " P0=\(p0.displayed) P1=\(p1.displayed) P2=\(p2.displayed)"
                        + " clientRank=\(p0.clientRank)/\(p1.clientRank)/\(p2.clientRank)"
                        + " P0c=\(p0c.displayed) P1c=\(p1c.displayed) P2c=\(p2c.displayed)")
            }
            fixtureResult = FixtureResult(option: option, conditions: conditions)
        }
        return fixtureResult
    }

    /// 目標表記をユーザ辞書へ登録した比較計測を、1つのfixture・Zenzaiの動作で行う
    ///
    /// 学習計測と同じ確定対象を使い、確定は行わない (学習を起こさない)
    /// 目標表記は隔離した root の [XDG_CONFIG_HOME]/hazkey-community/[user_dictionary.tsv] へ書いてから状態を作るため、
    /// [UserDictionary.defaultPath()] と [HazkeyServerConfig.getConfigDirectory()] の規則で読み込まれる
    ///
    /// - Parameters:
    ///   - fixture: 対象の読み
    ///   - zenzaiOn: Zenzaiを使う場合はtrue
    ///   - option: 確定対象 (学習計測と同じ対象)
    ///   - baseline: 同じfixture・Zenzaiの動作の学習計測の結果 (P0・P0cの比較元)
    ///   - modelURL: 実体へ解決済みの検証対象モデル
    /// - Returns: U・Ucの観測結果 (全ての条件を観測できなかった場合はnil)
    /// - Throws: 隔離環境の作成失敗やユーザ辞書TSVの書き込み失敗やZenzaiのモデルの読み込み失敗
    private func measureUserDictionary(
        _ fixture: Fixture, zenzaiOn: Bool, option: Option, baseline: FixtureResult, modelURL: URL
    ) throws -> FixtureResult? {
        let mode = zenzaiOn ? "on" : "off"
        var fixtureResult: FixtureResult?
        try withIsolatedRoot {
            let dictionaryDirectory = HazkeyServerConfig.getConfigDirectory()
            try FileManager.default.createDirectory(at: dictionaryDirectory, withIntermediateDirectories: true)
            let dictionaryURL = dictionaryDirectory.appendingPathComponent("user_dictionary.tsv", isDirectory: false)
            try "\(fixture.reading)\t\(option.target)\t\t\(option.userDictionaryPos)\n"
                .write(to: dictionaryURL, atomically: true, encoding: .utf8)
            var state = try makeState(zenzaiOn: zenzaiOn, modelURL: modelURL, useUserDictionary: true)
            defer { state.close() }
            var observations: [Phase: [Condition: Observation]] = [:]
            for phase in [Phase.userDict, .userDictContrast] {
                let left = phase.isContrast ? option.contrastLeft : option.chooseLeft
                for condition in Condition.allCases {
                    print("MARK zenzai=\(mode) fixture=\(fixture.reading) phase=\(phase.rawValue) cond=\(condition.rawValue)")
                    let o = observe(fixture, left: left, target: option.target, condition: condition, in: state)
                    observations[phase, default: [:]][condition] = o
                    print(
                        "ROW zenzai=\(mode) cat=\(fixture.category) fixture=\(fixture.reading) target=\(option.target)"
                            + " fallback=\(option.isFallback ? 1 : 0) phase=\(phase.rawValue)"
                            + " left=\(left.isEmpty ? "-" : left) cond=\(condition.rawValue)"
                            + " displayed=\(o.displayed) first=\(o.first)"
                            + " clientRank=\(o.clientRank) serverRank=\(o.serverRank) listed=\(o.listed)"
                            + " learnedTop=\(o.learnedTop ? 1 : 0) targetLearned=\(o.targetLearned ? 1 : 0)"
                            + " lastRedraft=\(o.lastRedraft.map(String.init) ?? "-")"
                            + " lastRetry=\(o.lastRetry.map(String.init) ?? "-")"
                            + " lastEval=\(o.lastEvaluation.map(String.init) ?? "-") ms=\(Int(o.ms))")
                }
            }
            var conditions: [Condition: ConditionResult] = [:]
            for condition in Condition.allCases {
                guard let u = observations[.userDict]?[condition],
                    let uc = observations[.userDictContrast]?[condition],
                    let base = baseline.conditions[condition]
                else { continue }
                conditions[condition] = ConditionResult(
                    baseline: base.baseline, afterChoice: base.afterChoice, afterRecreation: base.afterRecreation,
                    clientRankAfterChoice: base.clientRankAfterChoice,
                    clientRankAfterRecreation: base.clientRankAfterRecreation,
                    baselineContrast: base.baselineContrast, afterChoiceContrast: base.afterChoiceContrast,
                    afterRecreationContrast: base.afterRecreationContrast,
                    userDict: u.displayed, userDictContrast: uc.displayed, userDictClientRank: u.clientRank)
                print(
                    "USUMMARY zenzai=\(mode) cat=\(fixture.category) fixture=\(fixture.reading) target=\(option.target)"
                        + " cond=\(condition.rawValue) U=\(u.displayed) Uc=\(uc.displayed)"
                        + " P0=\(base.baseline) P0c=\(base.baselineContrast) clientRank=\(u.clientRank)")
            }
            let userObservations = observations[.userDict] ?? [:]
            if !userObservations.isEmpty && userObservations.values.allSatisfy({ $0.serverRank < 0 }) {
                print("UWARN zenzai=\(mode) fixture=\(fixture.reading) reason=user-dictionary-word-not-found")
            }
            fixtureResult = FixtureResult(option: option, conditions: conditions)
        }
        return fixtureResult
    }

    /// ユーザ辞書の比較計測の1つのfixtureを条件別の集計へ足す
    ///
    /// - Parameters:
    ///   - result: 1つのfixture・Zenzaiの動作のユーザ辞書比較計測の結果
    ///   - mode: Zenzaiの動作 ([on]または[off])
    ///   - tallies: 集計先 (条件別)
    private func accumulateUserDict(
        _ result: FixtureResult, mode: String, into tallies: inout [String: UserDictTally]
    ) {
        let target = result.option.target
        for condition in Condition.allCases {
            guard let r = result.conditions[condition],
                let u = r.userDict, let uc = r.userDictContrast, let rank = r.userDictClientRank
            else { continue }
            var tally = tallies["\(mode)|\(condition.rawValue)", default: UserDictTally()]
            tally.fixtures += 1
            if u != target { tally.notShown += 1 }
            if rank < 0 { tally.notListed += 1 }
            if r.baselineContrast != target {
                tally.baselineContrastDiffers += 1
                if uc == target { tally.contrastPinned += 1 }
            }
            tallies["\(mode)|\(condition.rawValue)"] = tally
        }
    }

    /// 選び直して確定した候補の押し戻しを、Zenzai ON / OFF と全入力条件で計測する
    ///
    /// - Throws: 環境変数未設定や隔離環境の作成失敗やZenzaiのモデルの読み込み失敗
    /// - Note: [HAZKEY_CHOICE_PUSHBACK_CHARACTERIZATION]が[1]でない場合はスキップする
    /// - Note: 対象モデルは[HAZKEY_ZENZAI_MODEL]で受け取る。推論期限を無効にするため、
    ///   [HAZKEY_ZENZAI_DEADLINE_MS]=0 をプロセスの起動時から設定して実行すること
    func testOptInChoicePushbackCharacterization() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["HAZKEY_CHOICE_PUSHBACK_CHARACTERIZATION"] == "1",
            "Set HAZKEY_CHOICE_PUSHBACK_CHARACTERIZATION=1 to run the real-model characterization.")
        let modelPath = try XCTUnwrap(environment["HAZKEY_ZENZAI_MODEL"])
        let modelURL = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))
        XCTAssertEqual(environment["HAZKEY_ZENZAI_DEADLINE_MS"], "0", "launch with HAZKEY_ZENZAI_DEADLINE_MS=0")
        if let path = environment["HAZKEY_PERF_EVIDENCE"],
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
        {
            perfOffset = size
        }
        print("MODEL \(modelURL.path) CPU perf=\(PerfProbe.shared == nil ? "off" : "on")")

        var tallies: [String: Tally] = [:]
        var userDictTallies: [String: UserDictTally] = [:]
        for fixture in fixtures {
            guard let on = try measure(fixture, zenzaiOn: true, forced: nil, modelURL: modelURL) else { continue }
            guard let off = try measure(fixture, zenzaiOn: false, forced: on.option, modelURL: modelURL) else {
                print("UNPAIRED fixture=\(fixture.reading) reason=zenzai-off-measurement-incomplete")
                continue
            }
            let target = on.option.target
            for condition in Condition.allCases {
                guard let onResult = on.conditions[condition], let offResult = off.conditions[condition] else {
                    continue
                }
                for (mode, result) in [("on", onResult), ("off", offResult)] {
                    var tally = tallies["\(mode)|\(condition.rawValue)", default: Tally()]
                    tally.fixtures += 1
                    if result.afterChoice != target { tally.notShownAfterChoice += 1 }
                    if result.afterRecreation != target { tally.notShownAfterRecreation += 1 }
                    if result.clientRankAfterChoice < 0 { tally.notListedAfterChoice += 1 }
                    if result.clientRankAfterRecreation < 0 { tally.notListedAfterRecreation += 1 }
                    // 先頭でない最上位の候補を代わりに選んだ場合は、対照の文脈との意味の対応が無いため数えない
                    if !on.option.isFallback && result.baselineContrast != target {
                        tally.contrastCases += 1
                        if result.afterChoiceContrast == target { tally.changedInContrastAfterChoice += 1 }
                        if result.afterRecreationContrast == target { tally.changedInContrastAfterRecreation += 1 }
                    }
                    if mode == "on" {
                        if onResult.afterChoice != target && offResult.afterChoice == target {
                            tally.onlyWithZenzaiAfterChoice += 1
                        }
                        if onResult.afterRecreation != target && offResult.afterRecreation == target {
                            tally.onlyWithZenzaiAfterRecreation += 1
                        }
                    }
                    tallies["\(mode)|\(condition.rawValue)"] = tally
                }
            }
            guard (fixture.category == "homophone" || fixture.category == "proper") && !on.option.isFallback else {
                continue
            }
            for mode in ["on", "off"] {
                let base = mode == "on" ? on : off
                guard
                    let comparison = try measureUserDictionary(
                        fixture, zenzaiOn: mode == "on", option: on.option, baseline: base, modelURL: modelURL)
                else { continue }
                accumulateUserDict(comparison, mode: mode, into: &userDictTallies)
            }
        }
        for mode in ["on", "off"] {
            for condition in Condition.allCases {
                guard let t = tallies["\(mode)|\(condition.rawValue)"] else { continue }
                print(
                    "TOTAL zenzai=\(mode) cond=\(condition.rawValue) fixtures=\(t.fixtures)"
                        + " notShown=\(t.notShownAfterChoice)/\(t.notShownAfterRecreation)"
                        + " notListed=\(t.notListedAfterChoice)/\(t.notListedAfterRecreation)"
                        + " changedInContrast=\(t.changedInContrastAfterChoice)/\(t.changedInContrastAfterRecreation)"
                        + " of \(t.contrastCases)"
                        + (mode == "on"
                            ? " onlyWithZenzai=\(t.onlyWithZenzaiAfterChoice)/\(t.onlyWithZenzaiAfterRecreation)" : ""))
            }
        }
        for mode in ["on", "off"] {
            for condition in Condition.allCases {
                guard let t = userDictTallies["\(mode)|\(condition.rawValue)"] else { continue }
                print(
                    "UTOTAL zenzai=\(mode) cond=\(condition.rawValue) fixtures=\(t.fixtures)"
                        + " notShown=\(t.notShown) notListed=\(t.notListed)"
                        + " contrastPinned=\(t.contrastPinned) of \(t.baselineContrastDiffers)")
            }
        }
    }
}

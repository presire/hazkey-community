import Foundation
import Glibc
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// jinen-v2ペルソナ畳み込みの実モデル特性テスト
///
/// [HAZKEY_JINEN_PERSONA_CHARACTERIZATION]が[1]のときだけ実行されるオプトインのテスト群
///
/// AzooKeyConverterフォークのZenzCandidateEvaluator.jinenEvaluationMode(_:)が
/// 候補評価プロンプトの左文脈の先頭へ"ペルソナ + 区切り"を畳み込む振る舞いを、実モデルで不変条件だけ検証する
///
/// 品質の良し悪しや推論時間の速さは記録のみで正しさとして主張しない
///
/// - Note: 対象モデルは[HAZKEY_ZENZAI_MODEL]で受け取る
/// - Note: 判定の本体は `ZenzCandidateEvaluator.jinenEvaluationMode(_:)` と
///   `HazkeyServerConfig.makeZenzaiV3DependentMode(...)` にある
final class JinenPersonaCharacterizationTests: XCTestCase {
    /// 変換する固定の読み群
    ///
    /// 固定プリフェックス、.wholeResult、.fixRequired、richの代替制約の各分岐を発生させるため、短い読みと長い読みを混ぜる
    private let readings = ["こうせい", "きかん", "かいせき", "しんさつ", "へんかん", "きしゃがきしゃできしゃした", "あ", "き", "さくら", "ありがとう", "ん", "を", "し"]

    /// 往復させるプロファイル列
    ///
    /// 最初と最後の空プロファイルの結果が同一であることを不変条件として検証する
    private let profiles = ["", "医師", "プログラマ", "新聞記者", ""]

    /// 文脈変換 ON かつ左文脈ありの条件で使う左文脈
    private let leftContextText = "きのうのつづきです。"

    /// 1条件の観測結果
    private struct Observation {
        /// 先頭5件の変換エンジン由来の表記
        var top: [String]
        /// 変換エンジン由来の候補総数
        var count: Int
        /// 条件全体の壁時間 [ms]
        var ms: Double
    }

    /// 一時ディレクトリ上に隔離した接続状態を作成して渡す
    ///
    /// 学習や設定や辞書の保存先が本番環境へ漏れないようにする
    ///
    /// モデルは[CPU]固定で読み込み直し学習は使わない
    ///
    /// - Parameters:
    ///   - modelURL: 実体へ解決済みの検証対象モデル
    ///   - body: 隔離した接続状態で実行する処理
    /// - Throws: 一時領域の作成失敗や[body]が投げるエラー
    private func withIsolatedState(
        modelURL: URL,
        _ body: (HazkeyServerState) throws -> Void
    ) throws {
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
        environment["HAZKEY_ZENZAI_DEADLINE_MS"] = "0"
        let original = ProcessInfo.processInfo.environment
        defer {
            for variable in environment.keys {
                if let value = original[variable] { setenv(variable, value, 1) }
                else { unsetenv(variable) }
            }
        }
        for (variable, value) in environment { XCTAssertEqual(setenv(variable, value, 1), 0) }
        let state = HazkeyServerState()
        defer { state.close() }
        state.serverConfig.currentProfile.zenzaiEnable = true
        state.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        state.serverConfig.currentProfile.useInputHistory = false
        state.serverConfig.currentProfile.useUserDictionary = false
        state.serverConfig.currentProfile.useTypoCorrection = false
        state.serverConfig.currentProfile.useZenzaiCustomWeight = true
        state.serverConfig.currentProfile.zenzaiWeightPath = modelURL.path
        state.serverConfig.reloadZenzaiModel()
        XCTAssertTrue(state.serverConfig.zenzaiAvailable, "zenzai must be available")
        state.baseConvertRequestOptions = state.serverConfig.genBaseConvertRequestOptions()
        try body(state)
    }

    /// 現在の候補リストから変換エンジン由来の表記の先頭5件を抜き出す
    ///
    /// 絵文字や日付等の注入候補を除いて比較するため
    ///
    /// - Parameter state: 処理を受け持つ接続状態
    /// - Returns: 先頭5件の表記と変換エンジン由来の候補総数
    private func top5(in state: HazkeyServerState) -> (top: [String], count: Int) {
        let texts = (state.currentCandidateList ?? []).compactMap { entry -> String? in
            if case .fromConverter(let candidate) = entry { return candidate.text }
            return nil
        }
        return (Array(texts.prefix(5)), texts.count)
    }

    /// 読みを1文字ずつ入力する
    ///
    /// 組成の作り直しから始めるため呼び出し前の組成内容に依存しない
    ///
    /// 組成の作り直しは左文脈を消去するため、左文脈は作り直しの直後かつ文字の入力前に設定する
    ///
    /// - Parameters:
    ///   - reading: 入力する読み
    ///   - left: 左文脈 (空の場合は左文脈なし)
    ///   - state: 処理を受け持つ接続状態
    private func typeReading(_ reading: String, left: String, to state: HazkeyServerState) {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        state.zenzaiLeftContext = left
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
    }

    /// 1条件を変換して観測する
    ///
    /// - Parameters:
    ///   - reading: 入力する読み
    ///   - profile: 設定するユーザープロファイル
    ///   - contextual: 文脈変換のON/OFF
    ///   - left: 左文脈 (空の場合は設定しない)
    ///   - rich: rich 候補のON/OFF
    ///   - isSuggest: サジェスト (ライブ変換) の場合はtrue
    ///   - state: 処理を受け持つ接続状態
    /// - Returns: 観測結果
    private func convert(
        reading: String, profile: String, contextual: Bool, left: String, rich: Bool, isSuggest: Bool,
        in state: HazkeyServerState
    ) -> Observation {
        state.serverConfig.currentProfile.zenzaiProfile = profile
        state.serverConfig.currentProfile.zenzaiContextualMode = contextual
        state.serverConfig.currentProfile.useRichCandidates = rich
        let started = Date()
        typeReading(reading, left: left, to: state)
        XCTAssertEqual(state.getCandidates(is_suggest: isSuggest).status, .success)
        let ms = Date().timeIntervalSince(started) * 1000
        let (top, count) = top5(in: state)
        XCTAssertGreaterThanOrEqual(count, 1, "every condition must yield >=1 candidate")
        return Observation(top: top, count: count, ms: ms)
    }

    /// ペルソナあり / なしの変換を全条件で観測し不変条件を検証する
    ///
    /// 条件: 非サジェスト (文脈OFF / 文脈ON 左文脈なし / 文脈ON 左文脈あり / rich ON 左文脈あり)、
    /// サジェスト (文脈ON 左文脈あり)、文節境界調整、固定プリフェックス付き評価
    ///
    /// - Throws: 環境変数未設定や隔離状態の作成失敗
    /// - Note: [HAZKEY_JINEN_PERSONA_CHARACTERIZATION]が[1]でない場合はスキップする
    /// - Note: 対象モデルは[HAZKEY_ZENZAI_MODEL]で受け取る
    func testOptInJinenPersonaCharacterization() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HAZKEY_JINEN_PERSONA_CHARACTERIZATION"] == "1",
            "Set HAZKEY_JINEN_PERSONA_CHARACTERIZATION=1 to run the real-model characterization.")
        let modelPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"])
        let modelURL = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))

        try withIsolatedState(modelURL: modelURL) { state in
            print("MODEL \(modelURL.path) CPU")
            // プロファイル往復の最初と最後の空結果の同一性を検証するため、空の結果を保持する
            var firstEmptyTop: [[String]] = []
            var lastEmptyTop: [[String]] = []
            for (profileIndex, profile) in profiles.enumerated() {
                let label = profile.isEmpty ? "(empty)" : profile
                for reading in readings {
                    let plain = convert(
                        reading: reading, profile: profile, contextual: false,
                        left: "", rich: false, isSuggest: false, in: state)
                    let ctxBare = convert(
                        reading: reading, profile: profile, contextual: true,
                        left: "", rich: false, isSuggest: false, in: state)
                    let ctxLeft = convert(
                        reading: reading, profile: profile, contextual: true,
                        left: leftContextText, rich: false, isSuggest: false, in: state)
                    let live = convert(
                        reading: reading, profile: profile, contextual: true,
                        left: leftContextText, rich: false, isSuggest: true, in: state)
                    let richObs = convert(
                        reading: reading, profile: profile, contextual: true,
                        left: leftContextText, rich: true, isSuggest: false, in: state)
                    print(
                        "COND profile=\(label) reading=\(reading)"
                            + " plain=\(plain.top) plain_ms=\(Int(plain.ms))"
                            + " ctxBare=\(ctxBare.top) ctxBare_ms=\(Int(ctxBare.ms))"
                            + " ctxLeft=\(ctxLeft.top) ctxLeft_ms=\(Int(ctxLeft.ms))"
                            + " live=\(live.top) live_ms=\(Int(live.ms))"
                            + " rich=\(richObs.top) rich_ms=\(Int(richObs.ms))")
                    if profileIndex == 0 && profile.isEmpty { firstEmptyTop.append(plain.top) }
                    if profileIndex == profiles.count - 1 && profile.isEmpty { lastEmptyTop.append(plain.top) }
                }

                // 文節境界調整: カーソルより前だけを変換して再変換する
                do {
                    let reading = "きしゃがきしゃできしゃした"
                    state.serverConfig.currentProfile.zenzaiProfile = profile
                    state.serverConfig.currentProfile.zenzaiContextualMode = true
                    state.serverConfig.currentProfile.useRichCandidates = false
                    let started = Date()
                    typeReading(reading, left: leftContextText, to: state)
                    let resp = state.adjustClauseBoundary(offset: -5)
                    XCTAssertEqual(resp.status, .success)
                    let ms = Date().timeIntervalSince(started) * 1000
                    let (top, count) = top5(in: state)
                    XCTAssertGreaterThanOrEqual(count, 1, "boundary condition must yield >=1 candidate")
                    print("BOUNDARY profile=\(label) top=\(top) count=\(count) ms=\(Int(ms))")
                }

                // 固定プリフェックス付き評価: 予測候補を受け入れて読みを足して再変換する
                do {
                    let reading = "きしゃがきしゃできしゃした"
                    state.serverConfig.currentProfile.zenzaiProfile = profile
                    state.serverConfig.currentProfile.zenzaiContextualMode = true
                    state.serverConfig.currentProfile.useRichCandidates = false
                    typeReading(reading, left: leftContextText, to: state)
                    XCTAssertEqual(state.getCandidates(is_suggest: true).status, .success)
                    let predictionIndex = (state.currentCandidateList ?? []).firstIndex {
                        if case .fromConverter(let candidate) = $0 {
                            return candidate.rubyCount > reading.count
                        }
                        return false
                    }
                    guard let index = predictionIndex else {
                        print("FIXEDPREFIX profile=\(label) skipped (no prediction candidate)")
                        continue
                    }
                    XCTAssertEqual(state.acceptPrediction(candidateIndex: index).status, .success)
                    for character in "です" {
                        XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
                    }
                    let started = Date()
                    XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
                    let ms = Date().timeIntervalSince(started) * 1000
                    let (top, count) = top5(in: state)
                    XCTAssertGreaterThanOrEqual(count, 1, "fixed-prefix condition must yield >=1 candidate")
                    print("FIXEDPREFIX profile=\(label) top=\(top) count=\(count) ms=\(Int(ms))")
                }
            }
            XCTAssertEqual(
                firstEmptyTop, lastEmptyTop,
                "first and last empty-profile results must be identical")
            print("INVARIANT emptyRoundTrip=\(firstEmptyTop == lastEmptyTop ? "PASS" : "FAIL")")
        }
    }
}

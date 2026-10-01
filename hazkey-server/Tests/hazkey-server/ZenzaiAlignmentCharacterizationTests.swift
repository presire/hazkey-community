import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// 実モデルを使用するアラインメント区切りの特性テスト
///
/// [HAZKEY_ALIGNMENT_CHARACTERIZATION]が[1]のときだけ実行されるオプトインのテスト群
///
/// 単体テストは、[ZenzaiAlignmentRequestTests]が純関数として固定して、本ファイルは実モデルを読み込んで不変条件だけを検証する
///
/// 品質の良し悪しや推論時間の速さは記録のみで正しさとして主張しない
///
/// - Note: 実モデル・レポート・性能証跡は[HAZKEY_ZENZAI_MODEL]と[HAZKEY_ALIGNMENT_REPORT]と[HAZKEY_PERF_EVIDENCE]で受け取る
/// - Note: 判定の本体は、下記にある
///      - [HazkeyServerConfig/alignmentSeparatorApplies]
///      - [HazkeyServerState/shouldSendFullReadingForAlignment]
///      - [HazkeyServerState/candidatesWithinReading]
/// - Note: 設定項目は、[protocol/config.proto]の[zenzai_alignment_separator]で既定は無効
final class ZenzaiAlignmentCharacterizationTests: XCTestCase {
    /// 境界調整の前後で比較する固定入力
    ///
    /// カーソルを文節境界へ動かしたときに全文評価と接頭辞評価の差を観測する
    private struct Case {
        /// カーソルより前の読み
        let prefix: String
        /// カーソルより後ろの読み
        let suffix: String
        /// 全文の読み
        ///
        /// [prefix]と[suffix]を連結したもの
        var reading: String { prefix + suffix }
    }

    /// 比較に使用する9件の固定入力
    ///
    /// 先頭7件は自然な文節境界での変化を観測する
    /// 残り2件は語中の境界での振る舞いを観測する
    ///
    /// 添え字は、[H4]と[H6]と[H8]と[H9]の対象選択に使用するため順序を変えないこと
    private let cases: [Case] = [
        .init(prefix: "きょうは", suffix: "いいてんき"),
        .init(prefix: "ここでは", suffix: "きものをぬぐ"),
        .init(prefix: "ここで", suffix: "はきものをぬぐ"),
        .init(prefix: "にわには", suffix: "にわとりがいる"),
        .init(prefix: "かれは", suffix: "はしをわたった"),
        .init(prefix: "わたしは", suffix: "がっこうへいく"),
        .init(prefix: "すもももももも", suffix: "もものうち"),
        .init(prefix: "にほ", suffix: "んご"),
        .init(prefix: "きょうはいいて", suffix: "んき"),
    ]

    // MARK: - Shared helpers

    /// 性能証跡ファイルから空でない行のみを読み出す
    ///
    /// 存在しない場合や読み出せない場合や空の場合は空配列を返す
    ///
    /// - Parameter path: [HAZKEY_PERF_EVIDENCE]が指す証跡ファイルのパス
    /// - Returns: 空行を除いた行の一覧
    private func readPerfLines(_ path: String) -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        if content.isEmpty { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
    }

    /// 性能証跡の1行をJSON辞書として解釈する
    ///
    /// 変換できない行は無効として扱う
    ///
    /// - Parameter line: 証跡ファイルの1行
    /// - Returns: 解釈できた場合は辞書、できない場合はnil
    private func parsePerfLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    /// 性能記録から推論モードを取り出す
    ///
    /// 記録に値がない場合は欠落扱いにする
    ///
    /// - Parameter perf: 証跡1行分の辞書
    /// - Returns: 推論モード文字列、なければ"missing"
    private func perfZenzai(_ perf: [String: Any]) -> String {
        return perf["zenzai"] as? String ?? "missing"
    }

    /// 性能記録から推論時間をミリ秒で取り出す
    ///
    /// 段階記録がない場合や値がない場合は0を返す
    ///
    /// - Parameter perf: 証跡1行分の辞書
    /// - Returns: [zenzai_inference_ms]の値、なければ0
    private func perfInferenceMs(_ perf: [String: Any]) -> Double {
        guard let stages = perf["stages"] as? [String: Any] else { return 0 }
        if let value = stages["zenzai_inference_ms"] as? Double { return value }
        if let value = stages["zenzai_inference_ms"] as? NSNumber { return value.doubleValue }
        return 0
    }

    /// 要求を変換処理へ通して応答と性能記録を1対で返す
    ///
    /// 呼び出し前後の証跡行数を数えてちょうど1行増えることを確認する
    ///
    /// 性能記録は、[ZenzInferencePerf]と[PerfProbe]が有効なことを前提にする
    ///
    /// - Parameters:
    ///   - request: 送る要求エンベロープ
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Returns: 応答エンベロープと今回分の性能記録
    /// - Throws: [HAZKEY_PERF_EVIDENCE]未設定や要求直列化失敗や応答解析失敗や証跡行数不一致
    private func rpc(
        _ request: Hazkey_RequestEnvelope,
        to state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Hazkey_ResponseEnvelope, [String: Any]) {
        let perfPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"],
            "runner must set HAZKEY_PERF_EVIDENCE", file: file, line: line)
        XCTAssertTrue(ZenzInferencePerf.shared.enabled, "ZenzInferencePerf must be enabled", file: file, line: line)
        XCTAssertNotNil(PerfProbe.shared, "PerfProbe.shared must exist", file: file, line: line)
        let before = readPerfLines(perfPath)
        let requestData: Data
        do {
            requestData = try request.serializedData()
        } catch {
            XCTFail("request serialization failed: \(error)", file: file, line: line)
            throw error
        }
        let responseData = ProtocolHandler(state: state).processProto(data: requestData)
        let response: Hazkey_ResponseEnvelope
        do {
            response = try Hazkey_ResponseEnvelope(serializedBytes: responseData)
        } catch {
            XCTFail("response parse failed: \(error)", file: file, line: line)
            throw error
        }
        let after = readPerfLines(perfPath)
        XCTAssertEqual(after.count, before.count + 1, "exactly one new perf line per RPC", file: file, line: line)
        guard after.count == before.count + 1 else {
            XCTFail("perf line count mismatch before=\(before.count) after=\(after.count)", file: file, line: line)
            throw NSError(domain: "hazkey-test", code: 1)
        }
        guard let last = after.last else {
            XCTFail("missing perf line", file: file, line: line)
            throw NSError(domain: "hazkey-test", code: 2)
        }
        guard let perf = parsePerfLine(last) else {
            XCTFail("perf line is not JSON: \(last)", file: file, line: line)
            throw NSError(domain: "hazkey-test", code: 3)
        }
        return (response, perf)
    }

    /// 読みを1文字ずつ入力して非サジェストの候補取得まで進める
    ///
    /// 組成の作り直しから始めるため呼び出し前の組成内容に依存しない
    ///
    /// - Parameters:
    ///   - reading: 入力する全文の読み
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Throws: [rpc]が投げるエラー
    private func inputViaRPC(
        _ reading: String,
        to state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var fresh = Hazkey_RequestEnvelope()
        fresh.newComposingText = Hazkey_Commands_NewComposingText()
        let (newResp, _) = try rpc(fresh, to: state, file: file, line: line)
        XCTAssertEqual(newResp.status, .success, "newComposingText", file: file, line: line)
        for character in reading {
            var req = Hazkey_RequestEnvelope()
            req.inputChar = Hazkey_Commands_InputChar.with { $0.text = String(character) }
            let (resp, _) = try rpc(req, to: state, file: file, line: line)
            XCTAssertEqual(resp.status, .success, "inputChar \(character)", file: file, line: line)
        }
        var get = Hazkey_RequestEnvelope()
        get.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = false }
        let (getResp, _) = try rpc(get, to: state, file: file, line: line)
        XCTAssertEqual(getResp.status, .success, "getCandidates(is_suggest:false)", file: file, line: line)
    }

    /// 文節境界の調整要求を送る
    ///
    /// 負の移動量でカーソルを左へ動かし右側の読みを残す
    ///
    /// - Parameters:
    ///   - offset: 境界の移動量
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Returns: 応答エンベロープと今回分の性能記録
    /// - Throws: [rpc]が投げるエラー
    private func adjustViaRPC(
        offset: Int,
        to state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Hazkey_ResponseEnvelope, [String: Any]) {
        var req = Hazkey_RequestEnvelope()
        req.adjustClauseBoundary = Hazkey_Commands_AdjustClauseBoundary.with { $0.offset = Int32(offset) }
        let (resp, perf) = try rpc(req, to: state, file: file, line: line)
        XCTAssertEqual(resp.status, .success, "adjustClauseBoundary(\(offset))", file: file, line: line)
        return (resp, perf)
    }

    /// 先頭候補で接頭辞確定する
    ///
    /// [H4]で確定後の組成が右側の読みだけ残ることを確認するために使用する
    ///
    /// - Parameters:
    ///   - index: 確定する候補位置
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Returns: 応答エンベロープと今回分の性能記録
    /// - Throws: [rpc]が投げるエラー
    private func prefixCompleteViaRPC(
        index: Int,
        to state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Hazkey_ResponseEnvelope, [String: Any]) {
        var req = Hazkey_RequestEnvelope()
        req.prefixComplete = Hazkey_Commands_PrefixComplete.with { $0.index = Int32(index) }
        let (resp, perf) = try rpc(req, to: state, file: file, line: line)
        XCTAssertEqual(resp.status, .success, "prefixComplete(\(index))", file: file, line: line)
        return (resp, perf)
    }

    /// 未保存の学習データを保存する
    ///
    /// [H9]で学習エントリを永続化するために使用する
    ///
    /// - Parameters:
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Returns: 応答エンベロープと今回分の性能記録
    /// - Throws: [rpc]が投げるエラー
    private func saveLearningViaRPC(
        to state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Hazkey_ResponseEnvelope, [String: Any]) {
        var req = Hazkey_RequestEnvelope()
        req.saveLearningData = Hazkey_Commands_SaveLearningData()
        return try rpc(req, to: state, file: file, line: line)
    }

    /// 候補位置を指定して学習データを削除する
    ///
    /// [H9]で削除後の作り直しを検証するために使用する
    ///
    /// - Parameters:
    ///   - index: 候補リスト内の対象候補の位置
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Returns: 応答エンベロープと今回分の性能記録
    /// - Throws: [rpc]が投げるエラー
    private func deleteLearningViaRPC(
        index: Int,
        to state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Hazkey_ResponseEnvelope, [String: Any]) {
        var req = Hazkey_RequestEnvelope()
        req.deleteCandidateLearningData = Hazkey_Commands_DeleteCandidateLearningData.with { $0.index = Int32(index) }
        return try rpc(req, to: state, file: file, line: line)
    }

    /// 同じ接頭辞組成に対する新規セッションの変換結果を求める
    ///
    /// 同一セッションの応答と比較して差分更新の正しさを検証する
    ///
    /// - Parameters:
    ///   - prefix: 要求用の接頭辞組成テキスト
    ///   - state: 処理を受け持つ接続状態
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Returns: 新規セッションでの変換候補の表記一覧
    /// - Throws: 変換要求が失敗した場合のエラー
    private func fresh(
        _ prefix: ComposingText,
        in state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        var options = state.baseConvertRequestOptions
        options.N_best = Int(state.serverConfig.currentProfile.numCandidatesPerPage)
        options.requireJapanesePrediction = .disabled
        options.zenzaiMode = state.serverConfig.genZenzaiMode(
            leftContext: state.zenzaiLeftContext,
            rightContext: state.zenzaiRightContext,
            requestRichCandidates: HazkeyServerConfig.requestRichCandidates(
                for: state.serverConfig.currentProfile, isSuggestion: false))
        let session = state.converter.createSession()
        defer { state.converter.removeSession(session) }
        do {
            return try state.converter.withSession(session) {
                state.converter.requestCandidates(prefix, options: options).mainResults.map(\.text)
            }
        } catch {
            XCTFail("fresh requestCandidates failed: \(error)", file: file, line: line)
            throw error
        }
    }

    /// 現在の候補リストから変換エンジン由来の表記だけを抜き出す
    ///
    /// 絵文字や日付などの注入候補を除いて比較するため先頭5件の観測に使用する
    ///
    /// - Parameter state: 処理を受け持つ接続状態
    /// - Returns: 変換エンジン由来の候補の表記一覧
    private func converterTexts(in state: HazkeyServerState) -> [String] {
        (state.currentCandidateList ?? []).compactMap {
            if case .fromConverter(let candidate) = $0 { return candidate.text }
            return nil
        }
    }

    /// 現在の候補リストから変換エンジン由来の候補だけを抜き出す
    ///
    /// 読み文字数や組成文字数の検査に使用する
    ///
    /// - Parameter state: 処理を受け持つ接続状態
    /// - Returns: 変換エンジン由来の候補の一覧
    private func converterEntries(in state: HazkeyServerState) -> [Candidate] {
        (state.currentCandidateList ?? []).compactMap {
            if case .fromConverter(let candidate) = $0 { return candidate }
            return nil
        }
    }

    /// レポートファイルへ見出し付きの区画を追記する
    ///
    /// 存在しない場合は新規作成しある場合は末尾へ足す
    ///
    /// 品質観測の記録は検証の合否とは別に残す
    ///
    /// - Parameters:
    ///   - name: 区画の見出し名
    ///   - lines: 追記する行の一覧
    ///   - reportPath: [HAZKEY_ALIGNMENT_REPORT]が指す出力先
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    private func appendReportSection(
        _ name: String, lines: [String], to reportPath: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let section = "## \(name)\n" + lines.joined(separator: "\n") + "\n"
        do {
            var contents = ""
            if FileManager.default.fileExists(atPath: reportPath) {
                contents = try String(contentsOfFile: reportPath, encoding: .utf8)
            }
            try (contents + section).write(toFile: reportPath, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to append alignment report \(reportPath): \(error)", file: file, line: line)
        }
    }

    /// 一時ディレクトリ上に隔離した接続状態を作成して渡す
    ///
    /// 学習や設定や辞書の保存先が本番環境へ漏れないようにする
    ///
    /// モデルは[CPU]固定で読み込み直し学習設定だけを切り替える
    ///
    /// - Parameters:
    ///   - modelURL: 実体へ解決済みの検証対象モデル
    ///   - useInputHistory: 学習を使用する場合はtrue
    ///   - body: 隔離した接続状態で実行する処理
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    /// - Throws: 一時領域の作成失敗や[body]が投げるエラー
    private func withIsolatedState(
        modelURL: URL,
        useInputHistory: Bool,
        _ body: (HazkeyServerState, URL) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
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
        for (variable, value) in environment { XCTAssertEqual(setenv(variable, value, 1), 0, file: file, line: line) }
        let state = HazkeyServerState()
        defer { state.close() }
        state.serverConfig.currentProfile.zenzaiEnable = true
        state.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        state.serverConfig.currentProfile.useInputHistory = useInputHistory
        state.serverConfig.currentProfile.useUserDictionary = false
        state.serverConfig.currentProfile.useRichCandidates = false
        state.serverConfig.currentProfile.useTypoCorrection = false
        state.serverConfig.currentProfile.specialConversionMode = .init()
        state.serverConfig.currentProfile.useZenzaiCustomWeight = true
        state.serverConfig.currentProfile.zenzaiWeightPath = modelURL.path
        state.serverConfig.reloadZenzaiModel()
        XCTAssertTrue(state.serverConfig.zenzaiAvailable, "zenzai must be available", file: file, line: line)
        state.baseConvertRequestOptions = state.serverConfig.genBaseConvertRequestOptions()
        if useInputHistory {
            state.shared.syncConverterLearningConfig()
            XCTAssertTrue(
                state.baseConvertRequestOptions.learningType != .nothing,
                "learningType must not be .nothing when useInputHistory is true",
                file: file, line: line)
        }
        try body(state, root)
    }

    // MARK: - H1b contract

    /// [H1b]の残り読み契約を検証する
    ///
    /// 各候補の確定済み文字数で接頭辞確定した残りが全文から読み文字数を引いた残りと一致すること
    ///
    /// 応答側の[ subHiragana]も同じ残りと一致し右側の読みを末尾に含むこと
    ///
    /// 読み文字数と等しい候補を全文対応として数えそれ以外は部分対応として数える
    ///
    /// - Parameters:
    ///   - fullText: 調整後の全文組成テキスト
    ///   - fullReading: 全文組成のひらがな
    ///   - rightReading: カーソルより後ろの読み
    ///   - prefixLen: カーソルまでの読みの文字数
    ///   - displayed: サーバ側の候補リスト
    ///   - wire: 応答側の候補リスト
    ///   - context: 報告用の入力名
    ///   - record: 報告行の追記処理
    ///   - file: 失敗報告に使用する呼び出し元ファイル
    ///   - line: 失敗報告に使用する呼び出し元行
    private func checkH1b(
        fullText: ComposingText,
        fullReading: String,
        rightReading: String,
        prefixLen: Int,
        displayed: [DisplayedCandidate],
        wire: [Hazkey_Commands_CandidatesResult.Candidate],
        context: String,
        record: (String) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(wire.count, displayed.count, "H1b \(context): wire/displayed count", file: file, line: line)
        if wire.count != displayed.count {
            record("H1b FAIL \(context) wire=\(wire.count) displayed=\(displayed.count)")
            XCTFail("H1b count mismatch", file: file, line: line)
            return
        }
        var fullPrefixCount = 0
        var partialCount = 0
        var partialExamples: [String] = []
        var failed = false
        for (index, entry) in displayed.enumerated() {
            guard case .fromConverter(let candidate) = entry else { continue }
            guard index < wire.count else {
                record("H1b FAIL \(context) index \(index) out of wire range")
                XCTFail("H1b index out of range", file: file, line: line)
                failed = true
                continue
            }
            let expected = String(fullReading.dropFirst(candidate.rubyCount))
            var remaining = fullText
            remaining.prefixComplete(composingCount: candidate.composingCount)
            let remainingHiragana = remaining.toHiragana()
            if remainingHiragana != expected {
                record("H1b FAIL \(context) candidate=\(candidate.text) ruby=\(candidate.rubyCount) remaining=\(remainingHiragana) expected=\(expected)")
                XCTFail("H1b remaining mismatch for \(candidate.text)", file: file, line: line)
                failed = true
            }
            if wire[index].subHiragana != expected {
                record("H1b FAIL \(context) candidate=\(candidate.text) wire subHiragana=\(wire[index].subHiragana) expected=\(expected)")
                XCTFail("H1b subHiragana mismatch for \(candidate.text)", file: file, line: line)
                failed = true
            }
            if !expected.hasSuffix(rightReading) {
                record("H1b FAIL \(context) candidate=\(candidate.text) expected=\(expected) missing suffix=\(rightReading)")
                XCTFail("H1b suffix mismatch for \(candidate.text)", file: file, line: line)
                failed = true
            }
            if candidate.rubyCount == prefixLen {
                fullPrefixCount += 1
            } else {
                partialCount += 1
                if partialExamples.count < 3 {
                    partialExamples.append("\(candidate.text)/ruby=\(candidate.rubyCount)/remaining=\(expected)")
                }
            }
        }
        if failed {
            record("H1b FAIL \(context) full=\(fullPrefixCount) partial=\(partialCount)")
        } else {
            record("H1b PASS \(context) full=\(fullPrefixCount) partial=\(partialCount) examples=\(partialExamples)")
        }
    }

    // MARK: - A) main characterization

    /// 区切り有効と無効の振る舞いと不変条件を9件の固定入力で記録する
    ///
    /// フラグ無効と有効の先頭5件や推論モードや推論時間を比較する
    ///
    /// [H3]は全文送信判定が真になることを確認する
    ///
    /// [H1]は読み文字数以内の候補だけが残り除外件数が0であることを確認する
    ///
    /// [H1b]は[checkH1b]で残り読み契約を確認する
    ///
    /// [H2]は推論有効と正の推論時間と読み込み中状態の一致を確認する
    ///
    /// [H4]は先頭候補の接頭辞確定で右側の読みだけが残ることを確認する
    ///
    /// [H6]は区切り無効時の同一セッションと新規セッションの一致を確認する
    ///
    /// [H8]はZenzai無効時の同一セッションと新規セッションの一致を確認する
    ///
    /// [H7]は右側だけが違う読みでも推論が走り結果を共有しないことを確認する
    ///
    /// 自然な境界での先頭変化数は観測のみで正しさとして主張しない
    ///
    /// - Throws: 環境変数未設定や隔離状態の作成失敗やRPC失敗
    /// - Note: [HAZKEY_ALIGNMENT_CHARACTERIZATION]が[1]でない場合は、スキップする
    /// - Note: 対象モデルは[HAZKEY_ZENZAI_MODEL]で受け取る
    func testOptInAlignmentCharacterization() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HAZKEY_ALIGNMENT_CHARACTERIZATION"] == "1",
            "Set HAZKEY_ALIGNMENT_CHARACTERIZATION=1 to run the real-model characterization.")
        let modelPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"])
        let reportPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ALIGNMENT_REPORT"])
        let modelURL = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))
        let perfPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"])
        XCTAssertTrue(ZenzInferencePerf.shared.enabled)
        XCTAssertNotNil(PerfProbe.shared)
        _ = perfPath

        var report: [String] = []
        /// 報告行を蓄積して標準出力へも出す
        ///
        /// - Parameter message: 追記する報告行
        func record(_ message: String) { report.append(message); print(message) }
        defer { appendReportSection("testOptInAlignmentCharacterization", lines: report, to: reportPath) }

        try withIsolatedState(modelURL: modelURL, useInputHistory: false) { state, _ in
            record("MODEL \(modelURL.path) CPU")
            var naturalTopChanges = 0
            for (index, item) in cases.enumerated() {
                let prefixLen = item.prefix.count
                // Flag OFF pass
                state.serverConfig.currentProfile.zenzaiAlignmentSeparator = false
                try inputViaRPC(item.reading, to: state)
                let (offResp, offPerf) = try adjustViaRPC(offset: -item.suffix.count, to: state)
                XCTAssertEqual(offResp.status, .success)
                let offTop = converterTexts(in: state).prefix(5).map { $0 }
                let offZenzai = perfZenzai(offPerf)
                let offMs = perfInferenceMs(offPerf)
                // Flag ON pass
                state.serverConfig.currentProfile.zenzaiAlignmentSeparator = true
                try inputViaRPC(item.reading, to: state)
                let (onResp, onPerf) = try adjustViaRPC(offset: -item.suffix.count, to: state)
                XCTAssertEqual(onResp.status, .success)
                let onTop = converterTexts(in: state).prefix(5).map { $0 }
                let onZenzai = perfZenzai(onPerf)
                let onMs = perfInferenceMs(onPerf)
                let changed = offTop.first != onTop.first
                record("CASE \(item.prefix)|\(item.suffix) OFF=\(Array(offTop)) ON=\(Array(onTop)) changed=\(changed) off_zenzai=\(offZenzai) off_ms=\(offMs) on_zenzai=\(onZenzai) on_ms=\(onMs)")

                // H3
                let applies = HazkeyServerConfig.alignmentSeparatorApplies(
                    profile: state.serverConfig.currentProfile, modelURL: modelURL)
                let zenzaiOn = (onZenzai == "on")
                let shouldSend = HazkeyServerState.shouldSendFullReadingForAlignment(
                    fullText: state.composingText.value, isSuggest: false,
                    zenzaiOn: zenzaiOn, alignmentApplies: applies)
                if applies && shouldSend {
                    record("H3 PASS \(item.reading) applies=true shouldSend=true zenzai=\(onZenzai)")
                } else {
                    record("H3 FAIL \(item.reading) applies=\(applies) shouldSend=\(shouldSend) zenzai=\(onZenzai)")
                    XCTFail("H3 full-reading decision failed for \(item.reading)")
                }

                // H1
                let onEntries = converterEntries(in: state)
                if !onEntries.isEmpty && onEntries.allSatisfy({ $0.rubyCount <= prefixLen })
                    && state.droppedAlignmentCandidateCount == 0
                {
                    record("H1 PASS \(item.reading) count=\(onEntries.count) ruby<=\(prefixLen) dropped=0")
                } else {
                    record("H1 FAIL \(item.reading) count=\(onEntries.count) dropped=\(state.droppedAlignmentCandidateCount)")
                    XCTFail("H1 candidate bound failed for \(item.reading)")
                }

                // H1b
                let fullText = state.composingText.value
                let fullReading = fullText.toHiragana()
                let wire = Array(onResp.clauseBoundaryResult.candidates.candidates)
                let displayed = state.currentCandidateList ?? []
                checkH1b(
                    fullText: fullText, fullReading: fullReading, rightReading: item.suffix,
                    prefixLen: prefixLen, displayed: displayed, wire: wire,
                    context: item.reading, record: record)

                // H1b count parity
                XCTAssertEqual(
                    wire.count, displayed.count,
                    "H1b count parity for \(item.reading)")

                // H2.
                let expectedStatus = "load \(modelURL.absoluteString)"
                let actualStatus = state.converter.zenzStatus
                if onZenzai == "on" && onMs > 0 && actualStatus == expectedStatus {
                    record("H2 PASS \(item.reading) zenzai=on ms=\(onMs) status=\(actualStatus)")
                } else {
                    record("H2 FAIL \(item.reading) zenzai=\(onZenzai) ms=\(onMs) status=\(actualStatus) expected=\(expectedStatus)")
                    XCTAssertEqual(onZenzai, "on", "H2 zenzai mode for \(item.reading)")
                    XCTAssertGreaterThan(onMs, 0, "H2 inference ms for \(item.reading)")
                    XCTAssertEqual(actualStatus, expectedStatus, "H2 model status for \(item.reading)")
                }

                if index < 7, changed { naturalTopChanges += 1 }

                // H4 (case 0 only)
                if index == 0 {
                    if let first = displayed.first {
                        if case .fromConverter(let firstCandidate) = first {
                            let isFull = (firstCandidate.rubyCount == prefixLen)
                            record("H4 INFO first=\(firstCandidate.text) ruby=\(firstCandidate.rubyCount) prefixLen=\(prefixLen) isFull=\(isFull)")
                        } else {
                            record("H4 INFO first entry is not .fromConverter")
                        }
                    } else {
                        record("H4 FAIL empty candidate list")
                        XCTFail("H4 empty list")
                    }
                    let (_, _) = try prefixCompleteViaRPC(index: 0, to: state)
                    let afterHiragana = state.composingText.value.toHiragana()
                    if afterHiragana == item.suffix {
                        record("H4 PASS composing=\(afterHiragana) suffix=\(item.suffix)")
                    } else {
                        record("H4 FAIL composing=\(afterHiragana) suffix=\(item.suffix)")
                    }
                    XCTAssertEqual(afterHiragana, item.suffix, "H4 prefixComplete preserves suffix")
                }

                // H6 (case 2 only)
                if index == 2 {
                    let prefix = state.candidateRequestText(is_suggest: false)
                    state.serverConfig.currentProfile.zenzaiAlignmentSeparator = false
                    let expected = try fresh(prefix, in: state)
                    let (fallbackResp, _) = try adjustViaRPC(offset: 0, to: state)
                    XCTAssertEqual(fallbackResp.status, .success)
                    let actual = converterTexts(in: state)
                    if actual == expected {
                        record("H6 PASS same=\(actual.count) fresh=\(expected.count)")
                    } else {
                        record("H6 FAIL same=\(actual.count) fresh=\(expected.count) actual=\(actual.prefix(5)) expected=\(expected.prefix(5))")
                    }
                    XCTAssertEqual(actual, expected, "H6 alignment OFF same-session parity")
                    state.serverConfig.currentProfile.zenzaiAlignmentSeparator = true
                }

                // H8 (case 3 only)
                if index == 3 {
                    let prefix = state.candidateRequestText(is_suggest: false)
                    state.serverConfig.currentProfile.zenzaiEnable = false
                    let expected = try fresh(prefix, in: state)
                    let (fallbackResp, _) = try adjustViaRPC(offset: 0, to: state)
                    XCTAssertEqual(fallbackResp.status, .success)
                    let actual = converterTexts(in: state)
                    if actual == expected {
                        record("H8 PASS same=\(actual.count) fresh=\(expected.count)")
                    } else {
                        record("H8 FAIL same=\(actual.count) fresh=\(expected.count) actual=\(actual.prefix(5)) expected=\(expected.prefix(5))")
                    }
                    XCTAssertEqual(actual, expected, "H8 Zenzai OFF same-session parity")
                    state.serverConfig.currentProfile.zenzaiEnable = true
                }
            }

            // H7
            state.serverConfig.currentProfile.zenzaiAlignmentSeparator = true
            try inputViaRPC("きょうはいいてんき", to: state)
            let (_, firstPerf) = try adjustViaRPC(offset: -3, to: state)
            let firstZenzai = perfZenzai(firstPerf)
            let firstMs = perfInferenceMs(firstPerf)
            let firstApplies = HazkeyServerConfig.alignmentSeparatorApplies(
                profile: state.serverConfig.currentProfile, modelURL: modelURL)
            let firstShould = HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: state.composingText.value, isSuggest: false,
                zenzaiOn: (firstZenzai == "on"), alignmentApplies: firstApplies)
            try inputViaRPC("きょうはいいてんぷら", to: state)
            let (_, secondPerf) = try adjustViaRPC(offset: -4, to: state)
            let secondZenzai = perfZenzai(secondPerf)
            let secondMs = perfInferenceMs(secondPerf)
            let secondApplies = HazkeyServerConfig.alignmentSeparatorApplies(
                profile: state.serverConfig.currentProfile, modelURL: modelURL)
            let secondShould = HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: state.composingText.value, isSuggest: false,
                zenzaiOn: (secondZenzai == "on"), alignmentApplies: secondApplies)
            if firstApplies && firstShould {
                record("H7 PASS first applies=true shouldSend=true zenzai=\(firstZenzai) ms=\(firstMs)")
            } else {
                record("H7 FAIL first applies=\(firstApplies) shouldSend=\(firstShould) zenzai=\(firstZenzai) ms=\(firstMs)")
                XCTFail("H7 first reading H3 predicate failed")
            }
            if secondApplies && secondShould && secondZenzai == "on" && secondMs > 0 {
                record("H7 PASS second applies=true shouldSend=true zenzai=on ms=\(secondMs)")
            } else {
                record("H7 FAIL second applies=\(secondApplies) shouldSend=\(secondShould) zenzai=\(secondZenzai) ms=\(secondMs)")
                XCTFail("H7 second reading failed")
            }
            XCTAssertTrue(secondApplies && secondShould, "H7 second H3 predicate")
            XCTAssertEqual(secondZenzai, "on", "H7 second zenzai mode")
            XCTAssertGreaterThan(secondMs, 0, "H7 second inference ms")
            record("SUMMARY natural_top1_changed=\(naturalTopChanges)/7; quality is observational, not asserted")
        }
    }

    // MARK: - B) 読込失敗時の一致確認 ([H5])

    /// 不正な重みでの読込失敗時に同一セッションと新規セッションが一致することを検証する
    ///
    /// 先に正規モデルで区切り有効の応答を得て[H3]の前提を確認する
    ///
    /// 次に存在しない重みへ差し替えて接頭辞組成の新規変換と境界調整の再要求を比較する
    ///
    /// 推論モードは有効のまま残り異常な重みを読込中として扱わないことを確認する
    ///
    /// - Throws: 環境変数未設定や隔離状態の作成失敗やRPC失敗
    /// - Note: [HAZKEY_ALIGNMENT_CHARACTERIZATION]が[1]でない場合は、スキップする
    /// - Note: 対象モデルは[HAZKEY_ZENZAI_MODEL]で受け取る
    func testOptInAlignmentModelLoadFailureParity() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HAZKEY_ALIGNMENT_CHARACTERIZATION"] == "1",
            "Set HAZKEY_ALIGNMENT_CHARACTERIZATION=1 to run the real-model characterization.")
        let modelPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"])
        let reportPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ALIGNMENT_REPORT"])
        let modelURL = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))
        _ = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"])
        XCTAssertTrue(ZenzInferencePerf.shared.enabled)
        XCTAssertNotNil(PerfProbe.shared)

        var report: [String] = []
        /// 報告行を蓄積して標準出力へも出す
        ///
        /// - Parameter message: 追記する報告行
        func record(_ message: String) { report.append(message); print(message) }
        defer { appendReportSection("testOptInAlignmentModelLoadFailureParity", lines: report, to: reportPath) }

        try withIsolatedState(modelURL: modelURL, useInputHistory: false) { state, root in
            record("MODEL \(modelURL.path) CPU")
            state.serverConfig.currentProfile.zenzaiAlignmentSeparator = true
            let item = cases[1]
            try inputViaRPC(item.reading, to: state)
            let (_, onPerf) = try adjustViaRPC(offset: -item.suffix.count, to: state)
            let applies = HazkeyServerConfig.alignmentSeparatorApplies(
                profile: state.serverConfig.currentProfile, modelURL: modelURL)
            let zenzaiOn = (perfZenzai(onPerf) == "on")
            let shouldSend = HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: state.composingText.value, isSuggest: false,
                zenzaiOn: zenzaiOn, alignmentApplies: applies)
            XCTAssertTrue(applies, "H5 real model must support the alignment separator")
            XCTAssertTrue(shouldSend, "H5 first request must send the full reading with the separator")
            XCTAssertEqual(state.converter.zenzStatus, "load \(modelURL.absoluteString)", "H5 real model loaded successfully")
            XCTAssertEqual(perfZenzai(onPerf), "on", "H5 first request Zenzai mode")
            XCTAssertGreaterThan(perfInferenceMs(onPerf), 0, "H5 first request must perform inference")
            let count = converterTexts(in: state).count
            let dropped = state.droppedAlignmentCandidateCount
            record("H3 \(applies && shouldSend ? "PASS" : "FAIL") applies=\(applies) shouldSend=\(shouldSend) zenzai=\(perfZenzai(onPerf)) count=\(count) dropped=\(dropped)")

            let originalModelPath = state.serverConfig.zenzaiModelPath
            let invalid = root.appendingPathComponent("invalid-zenz-v3.2-small.gguf")
            do {
                try Data("not a GGUF model".utf8).write(to: invalid)
            } catch {
                record("H5 FAIL could not write invalid model: \(error)")
                XCTFail("H5 fixture write failed: \(error)")
                return
            }
            state.serverConfig.zenzaiModelPath = invalid
            defer { state.serverConfig.zenzaiModelPath = originalModelPath }

            XCTAssertTrue(
                HazkeyServerConfig.alignmentSeparatorApplies(
                    profile: state.serverConfig.currentProfile, modelURL: invalid),
                "H5 invalid fixture must still enable the alignment separator")
            let shouldSendInvalid = HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: state.composingText.value, isSuggest: false,
                zenzaiOn: zenzaiOn, alignmentApplies: true)
            XCTAssertTrue(shouldSendInvalid, "H5 failing request must send the full reading with the separator")

            let prefix = state.candidateRequestText(is_suggest: false)
            let expected: [String]
            do {
                expected = try fresh(prefix, in: state)
            } catch {
                record("H5 FAIL fresh threw: \(error)")
                XCTFail("H5 fresh failed: \(error)")
                return
            }
            let (fallbackResp, fallbackPerf) = try adjustViaRPC(offset: 0, to: state)
            XCTAssertEqual(fallbackResp.status, .success)
            let actual = converterTexts(in: state)
            let fallbackZenzai = perfZenzai(fallbackPerf)
            let zenzStatus = state.converter.zenzStatus
            let invalidMarker = "load \(invalid.absoluteString)"
            let statusOK = (zenzStatus != invalidMarker)
            if actual == expected {
                record("H5 PASS same=\(actual.count) fresh=\(expected.count) actual5=\(Array(actual.prefix(5))) expected5=\(Array(expected.prefix(5)))")
            } else {
                record("H5 FAIL same=\(actual.count) fresh=\(expected.count) actual5=\(Array(actual.prefix(5))) expected5=\(Array(expected.prefix(5)))")
            }
            record("H5 INFO zenzai=\(fallbackZenzai) status=\(zenzStatus) invalidMarker=\(invalidMarker) statusOK=\(statusOK)")
            XCTAssertEqual(actual, expected, "H5 model-load failure same-session parity")
            XCTAssertEqual(fallbackZenzai, "on", "H5 mode stayed on (getModel-failure path)")
            XCTAssertTrue(statusOK, "H5 zenzStatus must not be load <invalid url>")
            XCTAssertTrue(zenzStatus.hasPrefix(invalidMarker), "H5 invalid model load must have been attempted")
        }
    }

    // MARK: - C) learning deletion rebuild (H9)

    /// 学習削除後も区切りの不変条件が保たれることを検証する
    ///
    /// 先頭候補を確定して保存し学習付きの候補を作り直す
    ///
    /// 学習注釈付きの候補を削除して作り直した応答と現在の候補リストを比較する
    ///
    /// 作り直し後も読み文字数以内や[H1b]契約や全文送信判定や除外件数0を確認する
    ///
    /// 削除した表記の古い注釈が残らないことも確認する
    ///
    /// - Throws: 環境変数未設定や隔離状態の作成失敗やRPC失敗
    /// - Note: [HAZKEY_ALIGNMENT_CHARACTERIZATION]が[1]でない場合は、スキップする
    /// - Note: 学習を使用する隔離状態で実行し対象は、[cases]の5件目
    func testOptInAlignmentLearningDeletionRebuild() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HAZKEY_ALIGNMENT_CHARACTERIZATION"] == "1",
            "Set HAZKEY_ALIGNMENT_CHARACTERIZATION=1 to run the real-model characterization.")
        let modelPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"])
        let reportPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ALIGNMENT_REPORT"])
        let modelURL = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))
        _ = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"])
        XCTAssertTrue(ZenzInferencePerf.shared.enabled)
        XCTAssertNotNil(PerfProbe.shared)

        var report: [String] = []
        /// 報告行を蓄積して標準出力へも出す
        ///
        /// - Parameter message: 追記する報告行
        func record(_ message: String) { report.append(message); print(message) }
        defer { appendReportSection("testOptInAlignmentLearningDeletionRebuild", lines: report, to: reportPath) }

        try withIsolatedState(modelURL: modelURL, useInputHistory: true) { state, _ in
            record("MODEL \(modelURL.path) CPU learning=ON")
            state.serverConfig.currentProfile.zenzaiAlignmentSeparator = true
            let item = cases[4]
            let prefixLen = item.prefix.count
            try inputViaRPC(item.reading, to: state)
            let (_, _) = try adjustViaRPC(offset: -item.suffix.count, to: state)

            guard let displayed = state.currentCandidateList, !displayed.isEmpty else {
                record("H9 FAIL empty candidate list")
                XCTFail("H9 empty list")
                return
            }
            guard case .fromConverter(let target) = displayed[0] else {
                record("H9 FAIL first candidate is not .fromConverter")
                XCTFail("H9 first candidate must be .fromConverter")
                return
            }
            let targetText = target.text
            let targetRuby = target.rubyCount
            record("H9 INFO target=\(targetText) ruby=\(targetRuby) prefixLen=\(prefixLen)")

            let (_, _) = try prefixCompleteViaRPC(index: 0, to: state)
            let (saveResp, _) = try saveLearningViaRPC(to: state)
            if saveResp.status == .success {
                record("H9 INFO saveLearningData success")
            } else {
                record("H9 FAIL saveLearningData status=\(saveResp.status) error=\(saveResp.errorMessage)")
            }
            XCTAssertEqual(saveResp.status, .success, "H9 saveLearningData")

            // 同じ読みを区切り有効のまま再入力する
            try inputViaRPC(item.reading, to: state)
            let (reResp, _) = try adjustViaRPC(offset: -item.suffix.count, to: state)
            XCTAssertEqual(reResp.status, .success)
            let reDisplayed = state.currentCandidateList ?? []
            let reWire = Array(reResp.clauseBoundaryResult.candidates.candidates)
            XCTAssertEqual(reWire.count, reDisplayed.count, "H9 re-query wire/displayed count")
            var foundIndex: Int? = nil
            for (idx, entry) in reDisplayed.enumerated() {
                guard case .fromConverter(let cand) = entry else { continue }
                if idx < reWire.count && cand.text == targetText && reWire[idx].hasLearningEntry_p == true {
                    foundIndex = idx
                    break
                }
            }
            guard let deleteIndex = foundIndex else {
                record("H9 FAIL learned target \(targetText) not found with hasLearningEntry_p==true")
                XCTFail("H9 learned candidate not found")
                return
            }
            record("H9 INFO learned index=\(deleteIndex) target=\(targetText)")

            let (delResp, delPerf) = try deleteLearningViaRPC(index: deleteIndex, to: state)
            if delResp.status == .success {
                record("H9 INFO delete status success deleted=\(delResp.deleteCandidateLearningDataResult.deletedCount)")
            } else {
                record("H9 FAIL delete status=\(delResp.status) error=\(delResp.errorMessage)")
            }
            XCTAssertEqual(delResp.status, .success, "H9 delete status")
            XCTAssertGreaterThan(delResp.deleteCandidateLearningDataResult.deletedCount, 0, "H9 deletedCount")
            let delZenzai = perfZenzai(delPerf)
            if delZenzai == "on" {
                record("H9 PASS delete zenzai=on")
            } else {
                record("H9 FAIL delete zenzai=\(delZenzai)")
            }
            XCTAssertEqual(delZenzai, "on", "H9 delete perf zenzai")

            let rebuilt = Array(delResp.deleteCandidateLearningDataResult.candidates.candidates)
            let rebuiltDisplayed = state.currentCandidateList ?? []
            if rebuilt.count == rebuiltDisplayed.count {
                record("H9 PASS rebuilt count=\(rebuilt.count) matches current list")
            } else {
                record("H9 FAIL rebuilt=\(rebuilt.count) current=\(rebuiltDisplayed.count)")
            }
            XCTAssertEqual(rebuilt.count, rebuiltDisplayed.count, "H9 rebuilt count")

            let rebuiltConverters: [Candidate] = rebuiltDisplayed.compactMap {
                if case .fromConverter(let c) = $0 { return c }
                return nil
            }
            XCTAssertFalse(rebuiltDisplayed.isEmpty, "H9 rebuilt candidate list must not be empty")
            XCTAssertFalse(rebuiltConverters.isEmpty, "H9 rebuilt converter candidates must not be empty")
            if rebuiltConverters.allSatisfy({ $0.rubyCount <= prefixLen }) {
                record("H9 PASS rebuilt ruby<=\(prefixLen) count=\(rebuiltConverters.count)")
            } else {
                record("H9 FAIL rebuilt ruby bound violated")
            }
            XCTAssertTrue(rebuiltConverters.allSatisfy({ $0.rubyCount <= prefixLen }), "H9 rebuilt bound")

            let fullTextAfter = state.composingText.value
            let fullReadingAfter = fullTextAfter.toHiragana()
            checkH1b(
                fullText: fullTextAfter, fullReading: fullReadingAfter, rightReading: item.suffix,
                prefixLen: prefixLen, displayed: rebuiltDisplayed, wire: rebuilt,
                context: "H9-rebuilt \(item.reading)", record: record)

            let appliesAfter = HazkeyServerConfig.alignmentSeparatorApplies(
                profile: state.serverConfig.currentProfile, modelURL: modelURL)
            let shouldAfter = HazkeyServerState.shouldSendFullReadingForAlignment(
                fullText: fullTextAfter, isSuggest: false,
                zenzaiOn: (delZenzai == "on"), alignmentApplies: appliesAfter)
            if appliesAfter && shouldAfter {
                record("H9 PASS H3 after delete applies=true shouldSend=true")
            } else {
                record("H9 FAIL H3 after delete applies=\(appliesAfter) shouldSend=\(shouldAfter)")
                XCTFail("H9 H3 after delete failed")
            }
            if state.droppedAlignmentCandidateCount == 0 {
                record("H9 PASS dropped=0")
            } else {
                record("H9 FAIL dropped=\(state.droppedAlignmentCandidateCount)")
            }
            XCTAssertEqual(state.droppedAlignmentCandidateCount, 0, "H9 dropped count")

            var staleAnnotated = false
            for cand in rebuilt {
                if cand.text == targetText && cand.hasLearningEntry_p == true {
                    staleAnnotated = true
                    record("H9 FAIL stale annotation for \(targetText)")
                }
            }
            if !staleAnnotated {
                record("H9 PASS no stale annotation for \(targetText)")
            }
            XCTAssertFalse(staleAnnotated, "H9 rebuilt target must not stay annotated")
        }
    }
}

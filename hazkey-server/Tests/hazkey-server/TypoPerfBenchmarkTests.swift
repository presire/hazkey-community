import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// タイポ補正のON/OFFとニューラル変換 (Zenzai) のOFF/ONを組み合わせた打鍵ごとの遅延を測るオプトインの性能ベンチマーク
///
/// 通常のテストスイートではこのテストをスキップする
/// 実行するには環境変数 [HAZKEY_TYPO_BENCH] に 1 を設定する
///
/// 参考用の証跡は [.omo/evidence/hazkey-typo-perf/typo-perf-report.txt] へ書き出す
final class TypoPerfBenchmarkTests: XCTestCase {
    /// 誤りのない比較対象の読みコーパス
    private let cleanCorpus = [
        "にほんご", "きょう", "とうきょう", "かんじ",
        "がくしゅう", "へんかん", "よろしく", "でんしゃ",
    ]
    /// ローマ字入力の誤りを含む読みコーパス
    private let typoCorpus = [
        "shipppaishita", "konnnnichiha", "gakkkou", "mottto",
        "chottto", "kittto", "zetttai", "ipppai",
    ]
    /// 各コーパスに対して測定するパス数
    private let measuredPasses = 3

    /// オプトインで全条件を実行し、遅延を要約して証跡を書き出し、クリーンコーパスの差分を検証する
    ///
    /// 環境変数 [HAZKEY_TYPO_BENCH] が空ならスキップする
    ///
    /// Zenzai条件はモデルが無い場合にスキップし、その他の条件の失敗は伝播させる
    ///
    /// - Throws: サーバ起動や測定に失敗した場合のエラー
    func testOptInTypoPerfBenchmark() throws {
        try XCTSkipIf(
            (ProcessInfo.processInfo.environment["HAZKEY_TYPO_BENCH"] ?? "").isEmpty,
            "Set HAZKEY_TYPO_BENCH=1 to run the typo-correction per-keystroke benchmark.")

        // 前提: 任意のZenzai条件を利用できる場合のニューラル変換モデル
        let modelPath = zenzaiModelPath()

        // 実行: 利用可能な各条件を、それぞれ隔離されたXDGサンドボックスで実行する
        var conditions: [ConditionResult] = []
        var skipped: [String] = []
        for zenzai in [false, true] {
            for typo in [false, true] {
                let label = "zenzai=\(zenzai ? "on" : "off") typo=\(typo ? "on" : "off")"
                if zenzai && modelPath == nil {
                    skipped.append("\(label): skipped (no model at \(Self.expectedModelPath))")
                } else {
                    do {
                        conditions.append(try runCondition(zenzai: zenzai, typo: typo, modelPath: modelPath))
                    } catch {
                        guard zenzai else { throw error }
                        skipped.append("\(label): skipped after failure: \(error)")
                    }
                }
            }
        }

        // 検証: 測定した遅延を要約し、参考用の証跡を書き出し、クリーンコーパスの差分を検証する
        let report = try makeReport(conditions: conditions, skipped: skipped)
        for line in report { print(line) }
        try writeReport(report)
        try assertCleanZenzaiOffDifference(conditions: conditions)
    }

    /// 1つの条件を隔離されたXDGサンドボックスで実行し、測定済みの遅延サンプルを返す
    ///
    /// サーバを新規に起動し、決定論的プロファイルを適用し、両コーパスを1回ウォームアップした後に測定パスを実行する
    ///
    /// - Parameters:
    ///   - zenzai: ニューラル変換を有効にするかどうか
    ///   - typo: タイポ補正を有効にするかどうか
    ///   - modelPath: 使用するニューラル変換モデルのパス (nilならZenzai条件は実行できない)
    /// - Returns: 条件とクリーンとタイポのサンプルを保持する結果
    /// - Throws: 一時ディレクトリやソケット待機、サンプル数の検証に失敗した場合のエラー
    private func runCondition(zenzai: Bool, typo: Bool, modelPath: String?) throws -> ConditionResult {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["runtime", "data", "config", "cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
        let evidenceURL = root.appendingPathComponent("events.jsonl")
        let process = try startServer(root: root, evidenceURL: evidenceURL, modelPath: modelPath)
        defer { process.terminate(); process.waitUntilExit() }

        let socketURL = root.appendingPathComponent("runtime/hazkey-community-server.\(getuid()).sock")
        TestTempRoot.requireFitsInSunPath(socketURL.path)
        try waitForSocket(at: socketURL.path)

        let client = try EnvelopeClient(socketPath: socketURL.path)
        defer { client.close() }
        try setDeterministicProfile(client: client, zenzai: zenzai, typo: typo)

        // 50 msのタイポ時間予算がウォームアップ後の変換を測るよう、両コーパスを1回ずつウォームアップする
        try replay(readings: cleanCorpus, client: client)
        try replay(readings: typoCorpus, client: client)
        let warmupCount = try candidateSamples(at: evidenceURL).count
        for _ in 0..<measuredPasses { try replay(readings: cleanCorpus, client: client) }
        for _ in 0..<measuredPasses { try replay(readings: typoCorpus, client: client) }

        let allSamples = try candidateSamples(at: evidenceURL)
        let measured = Array(allSamples.dropFirst(warmupCount))
        let expected = (cleanCorpus.count + typoCorpus.count) * measuredPasses
        guard allSamples.count >= warmupCount, measured.count == expected else {
            throw TypoBenchError.unexpectedSampleCount(measured.count, expected)
        }
        let boundary = cleanCorpus.count * measuredPasses
        return ConditionResult(
            zenzai: zenzai, typo: typo,
            cleanSamples: Array(measured[0..<boundary]),
            typoSamples: Array(measured[boundary...]))
    }

    /// 読みの集合をクライアント経由で再生し、各読みについて組成開始と1文字ずつの入力と通常候補取得を順に送る
    ///
    /// - Parameters:
    ///   - readings: 再生する読みの配列
    ///   - client: リクエスト送信に使うソケットクライアント
    /// - Throws: いずれかのリクエスト送信が失敗した場合のエラー
    private func replay(readings: [String], client: EnvelopeClient) throws {
        for reading in readings {
            var composing = Hazkey_RequestEnvelope()
            composing.newComposingText = Hazkey_Commands_NewComposingText()
            XCTAssertEqual(try client.send(composing).status, .success, reading)
            for character in reading {
                var input = Hazkey_RequestEnvelope()
                input.inputChar = Hazkey_Commands_InputChar.with { $0.text = String(character) }
                XCTAssertEqual(try client.send(input).status, .success, reading)
            }
            var candidates = Hazkey_RequestEnvelope()
            candidates.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = false }
            XCTAssertEqual(try client.send(candidates).status, .success, reading)
        }
    }

    /// 決定論的にするため履歴とユーザ辞書を無効化したプロファイルをサーバへ適用する
    ///
    /// Zenzaiとタイポ補正の有効と無効は条件に応じて設定する
    ///
    /// - Parameters:
    ///   - client: リクエスト送信に使うソケットクライアント
    ///   - zenzai: ニューラル変換を有効にするかどうか
    ///   - typo: タイポ補正を有効にするかどうか
    /// - Throws: 設定リクエストの送信が失敗した場合のエラー
    private func setDeterministicProfile(client: EnvelopeClient, zenzai: Bool, typo: Bool) throws {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useInputHistory = false
        profile.useUserDictionary = false
        profile.zenzaiEnable = zenzai
        profile.useTypoCorrection = typo
        var request = Hazkey_RequestEnvelope()
        request.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = [profile] }
        XCTAssertEqual(try client.send(request).status, .success)
    }

    /// 隔離されたXDGディレクトリを指す環境変数を与えてサーバ実行ファイルを起動する
    ///
    /// - Parameters:
    ///   - root: 隔離されたXDGディレクトリのルート
    ///   - evidenceURL: 性能イベントを書き出すJSON LinesファイルのURL
    ///   - modelPath: 使用するニューラル変換モデルのパス (nilなら設定しない)
    /// - Returns: 起動したサーバのプロセス
    /// - Throws: 実行ファイルが見つからない場合や起動に失敗した場合のエラー
    private func startServer(root: URL, evidenceURL: URL, modelPath: String?) throws -> Process {
        guard let executable = TestServerBinary.resolve(packageRoot: packageRoot) else {
            throw TypoBenchError.serverExecutableMissing(
                TestServerBinary.candidatePaths(packageRoot: packageRoot).joined(separator: ", "))
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["HAZKEY_PERF_EVIDENCE"] = evidenceURL.path
        environment["HAZKEY_DICTIONARY"] =
            packageRoot.appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        if let modelPath { environment["HAZKEY_ZENZAI_MODEL"] = modelPath }
        process.environment = environment
        try process.run()
        return process
    }

    /// ソケットファイルが現れるまで期限付きで待機する
    ///
    /// - Parameter path: 待機するソケットファイルのパス
    /// - Throws: 期限までにファイルが現れなかった場合のエラー
    private func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw TypoBenchError.socketTimeout(path)
    }

    /// 性能イベントのJSON Linesから候補生成の所要時間を抽出する
    ///
    /// 種別が [getCandidates] で段階に [candidate_generation_ms] を持つ行だけを対象にする
    ///
    /// - Parameter url: 性能イベントのJSON LinesファイルのURL
    /// - Returns: 候補生成の所要時間 (ミリ秒) の配列
    /// - Throws: ファイル読み取りやJSON解析に失敗した場合のエラー
    private func candidateSamples(at url: URL) throws -> [Double] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var samples: [Double] = []
        for line in raw.split(separator: "\n") where !line.isEmpty {
            guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw TypoBenchError.invalidEvidence
            }
            guard event["type"] as? String == "getCandidates" else { continue }
            guard let stages = event["stages"] as? [String: Any],
                  let milliseconds = stages["candidate_generation_ms"] as? Double else { continue }
            samples.append(milliseconds)
        }
        return samples
    }

    /// 値の集合からサンプル数と最近順位法によるp50とp95を算出する
    ///
    /// - Parameter values: 要約する測定値の配列
    /// - Returns: サンプル数とp50とp95のタプル
    /// - Throws: 値が空の場合のエラー
    private func summarize(_ values: [Double]) throws -> (samples: Int, p50: Double, p95: Double) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { throw TypoBenchError.emptySamples }
        return (
            sorted.count,
            try nearestRank(sorted, numerator: 50, denominator: 100),
            try nearestRank(sorted, numerator: 95, denominator: 100))
    }

    /// ソート済みの値から指定した分位点を最近順位法で求める
    ///
    /// - Parameters:
    ///   - sorted: 昇順にソート済みの測定値
    ///   - numerator: 分位点の分子
    ///   - denominator: 分位点の分母
    /// - Returns: 指定分位点の値
    /// - Throws: 値が空の場合のエラー
    private func nearestRank(_ sorted: [Double], numerator: Int, denominator: Int) throws -> Double {
        guard !sorted.isEmpty else { throw TypoBenchError.emptySamples }
        return sorted[(numerator * sorted.count + denominator - 1) / denominator - 1]
    }

    /// 値の集合の要約をサンプル数とp50とp95を含む1行に整形する
    ///
    /// - Parameter values: 要約する測定値の配列
    /// - Returns: 整形済みの要約文字列
    /// - Throws: 要約に失敗した場合のエラー
    private func summaryText(_ values: [Double]) throws -> String {
        let summary = try summarize(values)
        return String(format: "samples=%d p50=%.3f p95=%.3f", summary.samples, summary.p50, summary.p95)
    }

    /// 指定したZenzai状態でのクリーンコーパスp50についてタイポ補正ONとOFFの差を返す
    ///
    /// 差はタイポ補正ONのp50からOFFのp50を引いて求める
    ///
    /// - Parameters:
    ///   - conditions: 実行済みの条件結果
    ///   - zenzai: 対象とするニューラル変換の有効と無効
    /// - Returns: p50の差 (該当する条件が無い場合はnil)
    /// - Throws: 要約に失敗した場合のエラー
    private func cleanP50Difference(conditions: [ConditionResult], zenzai: Bool) throws -> Double? {
        guard let off = condition(conditions, zenzai: zenzai, typo: false),
              let on = condition(conditions, zenzai: zenzai, typo: true) else { return nil }
        let onP50 = try summarize(on.cleanSamples).p50
        let offP50 = try summarize(off.cleanSamples).p50
        return onP50 - offP50
    }

    /// 指定したZenzaiとタイポ補正の組み合わせに一致する条件結果を返す
    ///
    /// - Parameters:
    ///   - conditions: 実行済みの条件結果
    ///   - zenzai: 対象とするニューラル変換の有効と無効
    ///   - typo: 対象とするタイポ補正の有効と無効
    /// - Returns: 一致する条件結果 (無い場合はnil)
    private func condition(_ conditions: [ConditionResult], zenzai: Bool, typo: Bool) -> ConditionResult? {
        conditions.first { $0.zenzai == zenzai && $0.typo == typo }
    }

    /// Zenzai OFF時のクリーンコーパスp50差が許容範囲に収まることを検証する
    ///
    /// - Parameter conditions: 実行済みの条件結果
    /// - Throws: 必要な条件が欠けている場合のエラー
    private func assertCleanZenzaiOffDifference(conditions: [ConditionResult]) throws {
        let difference = try XCTUnwrap(
            try cleanP50Difference(conditions: conditions, zenzai: false),
            "clean-corpus Zenzai-off conditions are required for the acceptance check")
        XCTAssertLessThan(abs(difference), 1.0,
            "clean-corpus typo ON/OFF p50 difference must stay below 1.0 ms (was \(difference) ms)")
    }

    /// 実行済みの条件とスキップ理由から参考用の証跡レポートを行の配列として組み立てる
    ///
    /// - Parameters:
    ///   - conditions: 実行済みの条件結果
    ///   - skipped: スキップした条件の説明
    /// - Returns: レポートの行の配列
    /// - Throws: 要約や差分算出に失敗した場合のエラー
    private func makeReport(conditions: [ConditionResult], skipped: [String]) throws -> [String] {
        var lines: [String] = [
            "# Typo-correction per-keystroke latency benchmark (advisory)",
            "gate: HAZKEY_TYPO_BENCH=\(ProcessInfo.processInfo.environment["HAZKEY_TYPO_BENCH"] ?? "")",
            "corpora: clean=\(cleanCorpus.count) readings; typo=\(typoCorpus.count) readings",
            "profile: useInputHistory=false; useUserDictionary=false; per-condition zenzaiEnable/useTypoCorrection",
            "method: fresh isolated server per condition; 1 unmeasured warm-up pass per corpus, then \(measuredPasses) measured passes per corpus",
            "quantiles: nearest-rank p50/p95 (ms) over PerfProbe candidate_generation_ms",
            "",
        ]
        for item in conditions {
            lines.append("[condition zenzai=\(item.zenzai ? "on" : "off") typo=\(item.typo ? "on" : "off")]")
            lines.append("  clean: \(try summaryText(item.cleanSamples))")
            lines.append("  typo:  \(try summaryText(item.typoSamples))")
        }
        if let diff = try cleanP50Difference(conditions: conditions, zenzai: false) {
            lines.append("")
            lines.append(String(format: "clean-corpus p50 diff (typo on - typo off), zenzai off: %+.3f ms (hard assertion: |diff| < 1.0)", diff))
        }
        if let diff = try cleanP50Difference(conditions: conditions, zenzai: true) {
            lines.append(String(format: "clean-corpus p50 diff (typo on - typo off), zenzai on: %+.3f ms (advisory: not asserted)", diff))
        }
        for note in skipped { lines.append("skipped condition: \(note)") }
        lines.append("")
        lines.append("note: this evidence is advisory and produced from isolated local runs; it is not a release gate.")
        lines.append("")
        return lines
    }

    /// 証跡ディレクトリを作成し、レポートをテキストファイルとして書き出す
    ///
    /// - Parameter lines: レポートの行の配列
    /// - Throws: ディレクトリ作成やファイル書き込みに失敗した場合のエラー
    private func writeReport(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let url = evidenceDirectory.appendingPathComponent("typo-perf-report.txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// テストファイルの位置から導出したhazkey-serverパッケージのルートディレクトリ
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 参考用の証跡を書き出すディレクトリ
    private var evidenceDirectory: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".omo/evidence/hazkey-typo-perf", isDirectory: true)
    }

    /// ニューラル変換モデルの既定の探索先パス
    private static var expectedModelPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "~"
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/hazkey-community/zenzai/zenzai.gguf").path
    }

    /// 既定の探索先に存在する場合にニューラル変換モデルのパスを返す
    ///
    /// - Returns: モデルのパス (存在しない場合はnil)
    private func zenzaiModelPath() -> String? {
        let path = Self.expectedModelPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// 1つの条件で測定したクリーンとタイポのサンプル
private struct ConditionResult {
    /// ニューラル変換を有効にした条件かどうか
    let zenzai: Bool
    /// タイポ補正を有効にした条件かどうか
    let typo: Bool
    /// クリーンコーパスの候補生成時間 (ミリ秒)
    let cleanSamples: [Double]
    /// タイポコーパスの候補生成時間 (ミリ秒)
    let typoSamples: [Double]
}

/// ベンチマークの失敗を表すエラー
private enum TypoBenchError: Error {
    /// 性能イベントが不正である
    case invalidEvidence
    /// 要約するサンプルが空である
    case emptySamples
    /// 測定サンプル数が期待値と一致しない (実際, 期待)
    case unexpectedSampleCount(Int, Int)
    /// サーバ実行ファイルが見つからない (候補パス)
    case serverExecutableMissing(String)
    /// ソケットの接続待機がタイムアウトした (パス)
    case socketTimeout(String)
}

/// 共有サーバのトランスポートに合わせた長さ接頭辞付きprotobufの最小クライアント
private final class EnvelopeClient {
    /// 接続済みソケットのファイルディスクリプタ (未接続は -1)
    private var fileDescriptor: Int32

    /// UNIXドメインソケットへ接続し、受信タイムアウトを設定する
    ///
    /// - Parameter socketPath: 接続するソケットファイルのパス
    /// - Throws: ソケット作成や接続に失敗した場合のエラー
    init(socketPath: String) throws {
        fileDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else { throw TypoBenchError.socketTimeout(socketPath) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw TypoBenchError.socketTimeout(socketPath)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { pointer in
            strncpy(&address.sun_path.0, pointer, MemoryLayout.size(ofValue: address.sun_path) - 1)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw TypoBenchError.socketTimeout(socketPath) }
    }

    /// ソケットを閉じる
    deinit { close() }

    /// ソケットを閉じ、ファイルディスクリプタを無効化する
    func close() {
        if fileDescriptor >= 0 { Glibc.close(fileDescriptor); fileDescriptor = -1 }
    }

    /// リクエストを長さ接頭辞付きで送信し、応答を読み取って復号する
    ///
    /// - Parameter request: 送信するリクエスト
    /// - Returns: 復号した応答
    /// - Throws: 送受信や復号に失敗した場合のエラー
    func send(_ request: Hazkey_RequestEnvelope) throws -> Hazkey_ResponseEnvelope {
        let body = try request.serializedData()
        var length = UInt32(body.count).bigEndian
        try writeAll(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        try writeAll(body)
        let header = try readAll(count: MemoryLayout<UInt32>.size)
        let responseLength = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return try Hazkey_ResponseEnvelope(serializedBytes: readAll(count: Int(responseLength)))
    }

    /// すべてのバイトを書き切るまでソケットへ書き込む
    ///
    /// - Parameter data: 書き込むデータ
    /// - Throws: 書き込みに失敗した場合のエラー
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { throw TypoBenchError.invalidEvidence }
                let written = write(fileDescriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw TypoBenchError.invalidEvidence }
                offset += written
            }
        }
    }

    /// 指定バイト数を読み切るまでソケットから読み取る
    ///
    /// - Parameter count: 読み取るバイト数
    /// - Returns: 読み取ったデータ
    /// - Throws: 読み取りに失敗した場合のエラー
    private func readAll(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { throw TypoBenchError.invalidEvidence }
                let readCount = read(fileDescriptor, base.advanced(by: offset), buffer.count - offset)
                guard readCount > 0 else { throw TypoBenchError.invalidEvidence }
                offset += readCount
            }
        }
        return data
    }
}

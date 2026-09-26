import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// オプトインの Zenzai（`zenzaiEnable=true`）候補出力パリティハーネス。
///
/// `OutputParityTests.swift` は `zenzaiEnable = false` を固定するため（`state.swift:578` の
/// 「この値が true のままなら config.swift:578 がニューラル変換を有効化する」というコメントを参照）、
/// Zenzai/llama.cpp のコードパスを実行しない。`InferenceSeamBenchmarkTests.swift` は
/// `zenzai_inference_ms` の時間だけを記録し、候補テキスト自体は記録しない。既存のどちらの
/// ハーネスも、llama.cpp/Zenzai バックエンドの更新による候補出力の退行を検出できない。
/// このファイルはその不足を補う。実際の Zenzai モデルを使う実際の子プロセス
/// `hazkey-server` を、本番クライアントと同じ UNIXソケット protobuf トランスポート経由で
/// 操作し、将来の llama.cpp 更新で候補パリティを検証できるよう候補テキストを記録、比較する。
///
/// 完全なオプトインであり、`HAZKEY_PARITY=1` がない場合はスキップする。既定の
/// `swift test` スイートには含まれず、実行中のシステム `hazkey-server` にも触れない。
/// 常に隔離した一時 XDG ルート配下に専用の子プロセスを起動する。隔離方法は
/// `InferenceSeamBenchmarkTests.startServer` / `OutputParityTests.setUpWithError` と同じ。
// allow: SIZE_OK — このテストファイルは隔離サーバとソケットハーネスを意図的に内包する。
final class CandidateParityTests: XCTestCase {
/// `CorpusFixtures.swift` から再利用する読み。フィクスチャ宣言順で重複を除く
/// （ここで新しいコーパス内容を作成しない）。
    private static let corpus: [String] = {
        let fixtures = [
            CorpusFixtures.fullConversion,
            CorpusFixtures.suggestion,
            CorpusFixtures.prefixConversion,
            CorpusFixtures.kanaNumber,
            CorpusFixtures.relativeDate,
            CorpusFixtures.nonLearnableCommit,
        ]
        var seen = Set<String>()
        var readings: [String] = []
        for fixture in fixtures where seen.insert(fixture.reading).inserted {
            readings.append(fixture.reading)
        }
        return readings
    }()

    func testZenzaiCandidateParitySnapshot() throws {
        let parityMode = ProcessInfo.processInfo.environment["HAZKEY_PARITY"] ?? ""
        try XCTSkipUnless(
            !parityMode.isEmpty, "Set HAZKEY_PARITY=1 to run the Zenzai candidate parity harness.")

        guard
            let baselinePathString = ProcessInfo.processInfo.environment["HAZKEY_PARITY_BASELINE_JSON"],
            !baselinePathString.isEmpty
        else {
            throw ParityError.missingBaselinePath
        }
        let baselineURL = URL(fileURLWithPath: baselinePathString)
        let modelPath = try resolveZenzaiModelPath()

        if FileManager.default.fileExists(atPath: baselineURL.path) {
            try runVerify(baselineURL: baselineURL, modelPath: modelPath)
        } else {
            try runRecord(baselineURL: baselineURL, modelPath: modelPath)
        }
    }

    // MARK: - 記録 / 検証モード

/// ベースラインファイルがない場合は記録実行となる。ベースラインを書き込む前に、読みごとに
/// 状態変更を挟まず `getCandidates` を2回連続で呼ぶ決定性プローブが成功しなければならない。
/// 候補順位が非決定的なら、将来の検証時の比較は意味を失うためである。
    private func runRecord(baselineURL: URL, modelPath: String) throws {
        let (snapshot, probeFailures) = try collectCandidates(
            corpus: Self.corpus, modelPath: modelPath, probeDeterminism: true)
        guard probeFailures.isEmpty else {
            XCTFail(
                """
                Zenzai candidate output was not identical across two consecutive \
                getCandidates calls with the same input for reading(s): \
                \(probeFailures.joined(separator: ", ")). \
                同一性検証は決定性制約により部分検証になります (record aborted; baseline not written).
                """)
            return
        }
        try FileManager.default.createDirectory(
            at: baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: baselineURL, options: .atomic)
    }

/// ベースラインファイルがある場合は検証実行となる。コーパスを1回実行して記録済みの
/// ベースラインと比較する。決定性プローブは記録時に実行済みのため、ここでは繰り返さない。
    private func runVerify(baselineURL: URL, modelPath: String) throws {
        let (snapshot, _) = try collectCandidates(
            corpus: Self.corpus, modelPath: modelPath, probeDeterminism: false)
        let baselineData = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode([String: [String]].self, from: baselineData)
        XCTAssertEqual(
            snapshot, baseline, "Candidate output diverged from recorded baseline at \(baselineURL.path)")
    }

    // MARK: - モデルパスの解決
// .omo/evidence/hazkey-zenzai-inference/ の task-4/task-5 証跡に合わせる。
// 明示的な HAZKEY_ZENZAI_MODEL 上書きを優先し、それ以外では実行中のシステムサーバが使う
// 実際の固定済みユーザーレベルモデルへフォールバックする。

    private func resolveZenzaiModelPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"], !override.isEmpty {
            guard FileManager.default.fileExists(atPath: override) else {
                throw ParityError.modelMissing(override)
            }
            return override
        }
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw ParityError.missingHome
        }
        let path = URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/hazkey-community/zenzai/zenzai.gguf").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ParityError.modelMissing(path)
        }
        return path
    }

    // MARK: - サーバを使った候補収集

/// 隔離した子プロセス `hazkey-server` を1つ起動し、`zenzaiEnable = true` で `corpus` を
/// 再生して候補テキストのスナップショットを返す。`probeDeterminism` が true の場合、各読みの
/// `getCandidates` を状態変更を挟まず2回連続で実行する。`getCandidates` は冪等である
/// （`state.swift:355-367` の `ensureCompositionSeparatorForConversion` を参照）。
/// 一致しない読みは throw せず、返却する失敗リストで報告するため、呼び出し元が対応を決められる。
    private func collectCandidates(
        corpus: [String],
        modelPath: String,
        probeDeterminism: Bool
    ) throws -> (snapshot: [String: [String]], probeFailures: [String]) {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["runtime", "data", "config", "cache", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let process = try startServer(root: root, modelPath: modelPath)
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let socketURL = root.appendingPathComponent("runtime/hazkey-community-server.\(getuid()).sock")
        let socketIsIsolated = socketURL.standardizedFileURL.path.hasPrefix(
            root.standardizedFileURL.path + "/")
        XCTAssertTrue(socketIsIsolated, "Test socket must remain under its temporary XDG root.")
        guard socketIsIsolated else { throw ParityError.socketEscapesSandbox(socketURL.path) }
        TestTempRoot.requireFitsInSunPath(socketURL.path)
        try waitForSocket(at: socketURL.path)

        let client = try ParityRPCClient(socketPath: socketURL.path)
        // `client` がスコープを抜けると `ParityRPCClient.deinit` がソケットを閉じる。
        // ここで明示的に `defer { client.close() }` を置くと閉じる処理が重複する。
        // `deinit` は、すでに開いたファイルディスクリプタを解放する必要がある init-throws 経路も扱う。
        try setZenzaiProfile(client: client)

        var snapshot: [String: [String]] = [:]
        var probeFailures: [String] = []
        for reading in corpus {
            try replayReading(reading, client: client)
            let firstCall = try requestCandidates(client: client)
            if probeDeterminism {
                let secondCall = try requestCandidates(client: client)
                if firstCall != secondCall {
                    probeFailures.append(reading)
                }
            }
            snapshot[reading] = firstCall
        }
        return (snapshot, probeFailures)
    }

    private func startServer(root: URL, modelPath: String) throws -> Process {
        let process = Process()
        process.executableURL = try serverExecutable()
        process.currentDirectoryURL = packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment["HAZKEY_ZENZAI_MODEL"] = modelPath
        // 候補出力が実際のユーザーの ~/.local/share 辞書状態に依存しないよう、
        // システム辞書 submodule を固定する。
        environment["HAZKEY_DICTIONARY"] = packageRoot
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        process.environment = environment
        try process.run()
        return process
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func serverExecutable() throws -> URL {
        guard let executable = TestServerBinary.resolve(packageRoot: packageRoot) else {
            throw ParityError.serverExecutableMissing(
                TestServerBinary.candidatePaths(packageRoot: packageRoot).joined(separator: ", "))
        }
        return executable
    }

    private func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw ParityError.socketTimeout(path)
    }

    private func setZenzaiProfile(client: ParityRPCClient) throws {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useInputHistory = false
        profile.useUserDictionary = false
        profile.zenzaiEnable = true
        var request = Hazkey_RequestEnvelope()
        request.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = [profile] }
        let response = try client.send(request)
        guard response.status == .success else {
            throw ParityError.setupFailed(response.errorMessage)
        }
    }

    private func replayReading(_ reading: String, client: ParityRPCClient) throws {
        var newComposing = Hazkey_RequestEnvelope()
        newComposing.newComposingText = Hazkey_Commands_NewComposingText()
        let newComposingResponse = try client.send(newComposing)
        guard newComposingResponse.status == .success else {
            throw ParityError.rpcFailed("newComposingText", reading, newComposingResponse.errorMessage)
        }
        for character in reading {
            var input = Hazkey_RequestEnvelope()
            input.inputChar = Hazkey_Commands_InputChar.with { $0.text = String(character) }
            let inputResponse = try client.send(input)
            guard inputResponse.status == .success else {
                throw ParityError.rpcFailed("inputChar", reading, inputResponse.errorMessage)
            }
        }
    }

    private func requestCandidates(client: ParityRPCClient) throws -> [String] {
        var request = Hazkey_RequestEnvelope()
        request.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = false }
        let response = try client.send(request)
        guard response.status == .success else {
            throw ParityError.rpcFailed("getCandidates", "-", response.errorMessage)
        }
        return response.candidates.candidates.map(\.text)
    }
}

private enum ParityError: Error {
    case missingBaselinePath
    case missingHome
    case modelMissing(String)
    case serverExecutableMissing(String)
    case socketEscapesSandbox(String)
    case socketTimeout(String)
    case setupFailed(String)
    case rpcFailed(String, String, String)
    case invalidResponse
}

/// 最小限の長さプレフィックス付き UNIXソケット protobuf クライアント。フレーミングと
/// transact 動作（接続、長さプレフィックス付き送信、長さプレフィックス付き受信）は
/// `InferenceSeamBenchmarkTests.BenchmarkClient` とバイト単位で一致する。Swift の
/// トップレベル `private` により同クラスは `InferenceSeamBenchmarkTests.swift` の
/// ファイルスコープとなり、そのファイルは編集できないため、再実装せず同じクライアントパターンを
/// ここで複製する。
private final class ParityRPCClient {
    private var fileDescriptor: Int32

    init(socketPath: String) throws {
        fileDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else { throw ParityError.socketTimeout(socketPath) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard
            setsockopt(
                fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else {
            throw ParityError.socketTimeout(socketPath)
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
        guard connected == 0 else { throw ParityError.socketTimeout(socketPath) }
    }

    deinit { close() }

    func close() {
        if fileDescriptor >= 0 {
            Glibc.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    func send(_ request: Hazkey_RequestEnvelope) throws -> Hazkey_ResponseEnvelope {
        let body = try request.serializedData()
        var length = UInt32(body.count).bigEndian
        try writeAll(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        try writeAll(body)
        let header = try readAll(count: MemoryLayout<UInt32>.size)
        let responseLength = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return try Hazkey_ResponseEnvelope(serializedBytes: readAll(count: Int(responseLength)))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw ParityError.invalidResponse }
                offset += written
            }
        }
    }

    private func readAll(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let readCount = read(fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard readCount > 0 else { throw ParityError.invalidResponse }
                offset += readCount
            }
        }
        return data
    }
}

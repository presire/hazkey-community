import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// Zenzai (ニューラル変換) を有効にした状態で、変換候補の出力が変わっていないかを確かめるテスト
/// 設定キー[zenzaiEnable]をtrueにして実行する
///
/// 既存テストとの役割分担
/// - OutputParityTestsは[zenzaiEnable]をfalseに固定するため、Zenzai / llama.cppの処理を通らない
/// - InferenceSeamBenchmarkTestsは推論時間[zenzai_inference_ms]だけを記録して、候補の文字列は記録しない
/// - そのため、既存テストではllama.cppやZenzaiの更新で候補が変わっても検出できない
///
/// このテストは上記の不足を補う
/// 実際のZenzaiモデルを読み込んだhazkey-serverを子プロセスとして起動し、
/// 本番のクライアントと同じUNIXソケット + protobuf通信で操作する
/// 得られた候補の文字列をベースラインとして記録し、次回以降の実行でベースラインと比較する
///
/// 環境変数[HAZKEY_PARITY]が未設定の場合はスキップする
/// 通常のswift testでは実行されず、動作中のシステムのhazkey-serverにも影響しない
/// サーバは毎回、一時ディレクトリに作ったXDGディレクトリ群の配下で隔離して起動する
/// (隔離方法はInferenceSeamBenchmarkTests.startServer / OutputParityTests.setUpWithErrorと同じ)

// allow: SIZE_OK - 隔離サーバの起動処理とソケット通信処理を意図的にこのファイル内に持つ
final class CandidateParityTests: XCTestCase {
    /// テストで入力する読みの一覧
    /// CorpusFixtures.swiftの既存フィクスチャを宣言順に並べ、重複する読みを除いて使用する
    /// (このテスト専用の読みは新たに追加しない)
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

    /// 記録モード (環境変数[HAZKEY_PARITY_BASELINE_JSON]が指すファイルが存在しない場合)
    /// ベースラインを書き込む前に、読みごとに[getCandidates]を2回続けて呼び、結果が同じかを確認する
    /// 同じ入力で候補の順位が毎回変わるようでは、後の比較が意味を持たないため、
    /// 1つでも一致しない読みがあればテストを失敗させ、ベースラインは書き込まない
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

    /// 検証モード (ベースラインファイルが存在する場合)
    /// 全ての読みを1回ずつ変換し、記録済みのベースラインと完全一致するかを確認する
    /// 2回呼び出しによる一致確認は記録時に済んでいるため、ここでは行わない
    private func runVerify(baselineURL: URL, modelPath: String) throws {
        let (snapshot, _) = try collectCandidates(
            corpus: Self.corpus, modelPath: modelPath, probeDeterminism: false)
        let baselineData = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode([String: [String]].self, from: baselineData)
        XCTAssertEqual(
            snapshot, baseline, "Candidate output diverged from recorded baseline at \(baselineURL.path)")
    }

    // MARK: - モデルパスの解決
    //
    // 使用するZenzaiモデルの決め方
    // 1. 環境変数[HAZKEY_ZENZAI_MODEL]が設定されていれば、そのファイルを使う
    // 2. 未設定なら、ユーザが使用している "~/.local/share/hazkey-community/zenzai/zenzai.gguf" を使用する
    // どちらもファイルが存在しなければエラーにする

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

    /// 隔離したhazkey-serverを1つ起動して、Zenzaiを有効にして全ての読みを入力し、
    /// 読みごとの候補文字列の一覧 (スナップショット) を返す
    ///
    /// probeDeterminismがtrueの場合は、読みごとに[getCandidates]を2回続けて呼び、結果を比較する
    /// [getCandidates]は何度呼んでも入力状態を変えないため、2回目も同じ条件で変換される
    /// (HazkeyServerState.getCandidates(is_suggest:)内のensureCompositionSeparatorForConversion()を参照)
    ///
    /// 結果が一致しない読みは例外にせず、戻り値のprobeFailuresに入れて呼び出し元に判断を任せる
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
        // clientがスコープを抜けると、ParityRPCClientのdeinitがソケットを閉じる
        // そのため、ここで"defer { client.close() }" は書かない (閉じる処理が重複するため)
        // deinitは、initの途中で例外が発生した場合に開いたままのソケットも閉じる
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

        // 候補がユーザ環境 (~/.local/share配下) の辞書に左右されないよう、
        // リポジトリ内のシステム辞書submoduleを[HAZKEY_DICTIONARY]で指定する
        environment["HAZKEY_DICTIONARY"] = packageRoot.appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
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

/// テスト用の最小限のUNIXソケットクライアント
/// 本番クライアントと同じく、4バイト (ビッグエンディアン) の長さの後にprotobufの本体を続けて送受信する
/// 通信手順はInferenceSeamBenchmarkTestsのBenchmarkClientとバイト単位で同じ
///
/// BenchmarkClientはprivate宣言のため他のファイルから使えず、ここに同じ実装を複製している
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

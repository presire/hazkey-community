import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// ZenzaiのCPU推論を制御する2つの環境変数の動作確認テスト
/// - [HAZKEY_ZENZAI_CPU_THREADS]: CPU推論のスレッド数 (有効範囲は1〜8)
/// - [HAZKEY_ZENZAI_DEADLINE_MS]: 推論1回の上限時間[ms] (有効範囲は0〜2000、0は期限なし)
///
/// どちらもAzooKeyKanaKanjiConverterのフォーク (presire/AzooKeyKanaKanjiConverter) 側で解釈される
///
/// サーバの起動処理とソケットクライアントは、CandidateParityTests / InferenceSeamBenchmarkTestsと同じものを複製している
/// 複製元はprivate宣言のため他のファイルから使用できないため、このファイルにも同じ実装を持たせている
///
/// 環境変数[HAZKEY_CPU_BUDGET_QA]が未設定の場合はスキップする
/// 動作中のシステムのhazkey-serverには影響せず、毎回一時ディレクトリ配下で隔離したサーバを起動する

// allow: SIZE_OK - 隔離サーバの起動処理とソケット通信処理を意図的にこのファイル内に持つ
final class CPUBudgetControlsTests: XCTestCase {
    private static let reading = CorpusFixtures.fullConversion.reading

    /// 正常系
    /// 有効な値 (1スレッド、上限2000[ms]) を指定しても候補が1件以上返り、リクエスト後もサーバが動作し続けることを確認する
    func testHappyPathCPUBudgetControls() throws {
        try XCTSkipUnless(qaEnabled, "Set HAZKEY_CPU_BUDGET_QA=1 to run this opt-in QA harness.")
        try runFixture(
            label: "happy(threads=1,deadline=2000ms)",
            extraEnvironment: [
                "HAZKEY_ZENZAI_CPU_THREADS": "1",
                "HAZKEY_ZENZAI_DEADLINE_MS": "2000",
            ])
    }

    /// 異常系
    /// 範囲外や数値でない値 (0、9、-5、999999、abc) を指定した場合は、その値を無視して既定の動作になることを確認する
    /// サーバがクラッシュ (トラップ) せず、候補が1件以上返り、リクエスト後もサーバが動作し続けること
    func testFailureFixturesCPUBudgetControls() throws {
        try XCTSkipUnless(qaEnabled, "Set HAZKEY_CPU_BUDGET_QA=1 to run this opt-in QA harness.")
        let invalidFixtures: [(String, [String: String])] = [
            ("HAZKEY_ZENZAI_CPU_THREADS=0", ["HAZKEY_ZENZAI_CPU_THREADS": "0"]),
            ("HAZKEY_ZENZAI_CPU_THREADS=9", ["HAZKEY_ZENZAI_CPU_THREADS": "9"]),
            ("HAZKEY_ZENZAI_CPU_THREADS=abc", ["HAZKEY_ZENZAI_CPU_THREADS": "abc"]),
            ("HAZKEY_ZENZAI_DEADLINE_MS=-5", ["HAZKEY_ZENZAI_DEADLINE_MS": "-5"]),
            ("HAZKEY_ZENZAI_DEADLINE_MS=999999", ["HAZKEY_ZENZAI_DEADLINE_MS": "999999"]),
            ("HAZKEY_ZENZAI_DEADLINE_MS=abc", ["HAZKEY_ZENZAI_DEADLINE_MS": "abc"]),
        ]
        for (label, environment) in invalidFixtures {
            try runFixture(label: "failure(\(label))", extraEnvironment: environment)
        }
    }

    // MARK: - 共通フィクスチャ実行処理

    private var qaEnabled: Bool {
        !(ProcessInfo.processInfo.environment["HAZKEY_CPU_BUDGET_QA"] ?? "").isEmpty
    }

    private func runFixture(label: String, extraEnvironment: [String: String]) throws {
        let modelPath = try resolveZenzaiModelPath()
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["runtime", "data", "config", "cache", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let process = try startServer(root: root, modelPath: modelPath, extraEnvironment: extraEnvironment)
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let socketURL = root.appendingPathComponent("runtime/hazkey-community-server.\(getuid()).sock")
        TestTempRoot.requireFitsInSunPath(socketURL.path)
        try waitForSocket(at: socketURL.path)

        let client = try QARPCClient(socketPath: socketURL.path)
        try setZenzaiProfile(client: client)

        var newComposing = Hazkey_RequestEnvelope()
        newComposing.newComposingText = Hazkey_Commands_NewComposingText()
        let newComposingResponse = try client.send(newComposing)
        XCTAssertEqual(
            newComposingResponse.status, .success, "[\(label)] newComposingText should succeed")

        for character in Self.reading {
            var input = Hazkey_RequestEnvelope()
            input.inputChar = Hazkey_Commands_InputChar.with { $0.text = String(character) }
            let inputResponse = try client.send(input)
            XCTAssertEqual(
                inputResponse.status, .success, "[\(label)] inputChar('\(character)') should succeed")
        }

        var getCandidates = Hazkey_RequestEnvelope()
        getCandidates.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = false }
        let candidatesResponse = try client.send(getCandidates)
        XCTAssertEqual(
            candidatesResponse.status, .success, "[\(label)] getCandidates should succeed")
        XCTAssertFalse(
            candidatesResponse.candidates.candidates.isEmpty,
            "[\(label)] candidates must be non-empty (fallback to non-neural candidates on deadline/invalid-value expiry)")

        client.close()
        XCTAssertTrue(process.isRunning, "[\(label)] server process must still be alive after the request")
    }

    // MARK: - サーバプロセス用ヘルパー (他のテストからの複製、ファイル先頭のコメントを参照)

    private func resolveZenzaiModelPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"], !override.isEmpty {
            guard FileManager.default.fileExists(atPath: override) else {
                throw QAError.modelMissing(override)
            }
            return override
        }
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw QAError.missingHome
        }
        let path = URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/hazkey-community/zenzai/zenzai.gguf").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw QAError.modelMissing(path)
        }
        return path
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func serverExecutable() throws -> URL {
        guard let executable = TestServerBinary.resolve(packageRoot: packageRoot) else {
            throw QAError.serverExecutableMissing(
                TestServerBinary.candidatePaths(packageRoot: packageRoot).joined(separator: ", "))
        }
        return executable
    }

    private func startServer(
        root: URL, modelPath: String, extraEnvironment: [String: String]
    ) throws -> Process {
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
        environment["HAZKEY_DICTIONARY"] = packageRoot.appendingPathComponent("azooKey_dictionary_storage/Dictionary").path

        // テストを実行するシェル側で設定された値が混ざらないよう、2つの環境変数を一度削除して、 このケースで指定した値だけを設定する
        environment.removeValue(forKey: "HAZKEY_ZENZAI_CPU_THREADS")
        environment.removeValue(forKey: "HAZKEY_ZENZAI_DEADLINE_MS")
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment
        try process.run()
        return process
    }

    private func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw QAError.socketTimeout(path)
    }

    private func setZenzaiProfile(client: QARPCClient) throws {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useInputHistory = false
        profile.useUserDictionary = false
        profile.zenzaiEnable = true
        var request = Hazkey_RequestEnvelope()
        request.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = [profile] }
        let response = try client.send(request)
        guard response.status == .success else {
            throw QAError.setupFailed(response.errorMessage)
        }
    }
}

private enum QAError: Error {
    case missingHome
    case modelMissing(String)
    case serverExecutableMissing(String)
    case socketTimeout(String)
    case setupFailed(String)
    case invalidResponse
}

/// テスト用の最小限のUNIXソケットクライアント (CandidateParityTestsのParityRPCClientの複製)
/// 本番クライアントと同じく、4バイト (ビッグエンディアン) の長さの後にprotobufの本体を続けて送受信する
/// 複製元はprivate宣言のため他のファイルから使用できず、ここに同じ実装を持たせている
private final class QARPCClient {
    private var fileDescriptor: Int32

    init(socketPath: String) throws {
        fileDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else { throw QAError.socketTimeout(socketPath) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard
            setsockopt(
                fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else {
            throw QAError.socketTimeout(socketPath)
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
        guard connected == 0 else { throw QAError.socketTimeout(socketPath) }
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
                guard written > 0 else { throw QAError.invalidResponse }
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
                guard readCount > 0 else { throw QAError.invalidResponse }
                offset += readCount
            }
        }
        return data
    }
}

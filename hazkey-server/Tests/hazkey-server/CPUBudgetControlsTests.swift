import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// fork の `HAZKEY_ZENZAI_CPU_THREADS` / `HAZKEY_ZENZAI_DEADLINE_MS`
/// 環境変数制御に対するオプトインの機能QA（`.omo/plans/hazkey-ime-cpu-latency.md`
/// の todo 3 を参照）。
///
/// `CandidateParityTests.swift` / `InferenceSeamBenchmarkTests.swift` で確立済みの
/// 小規模な子プロセスとソケットクライアントのパターンを意図的に複製している。Swift の
/// トップレベル `private` はヘルパー型をファイルスコープにするため、各ファイルが専用の
/// コピーを持つ必要があり、どちらの移植元ファイルも編集できない。完全なオプトインであり、
/// `HAZKEY_CPU_BUDGET_QA=1` がない場合はスキップする。実行中のシステム
/// `hazkey-server` には触れず、常に一時的な XDG ルート配下の隔離子プロセスを使う。
// allow: SIZE_OK — このテストファイルは隔離サーバとソケットハーネスを意図的に内包する。
final class CPUBudgetControlsTests: XCTestCase {
    private static let reading = CorpusFixtures.fullConversion.reading

/// 正常系: 有効な上書き値（1スレッド、期限2000ms）でも空でない候補を生成し、
/// サーバが稼働し続ける。
    func testHappyPathCPUBudgetControls() throws {
        try XCTSkipUnless(qaEnabled, "Set HAZKEY_CPU_BUDGET_QA=1 to run this opt-in QA harness.")
        try runFixture(
            label: "happy(threads=1,deadline=2000ms)",
            extraEnvironment: [
                "HAZKEY_ZENZAI_CPU_THREADS": "1",
                "HAZKEY_ZENZAI_DEADLINE_MS": "2000",
            ])
    }

/// 異常系フィクスチャ: 両制御の無効値は既存の既定動作へ縮退しなければならない。
/// クラッシュもトラップもせず、候補は空にならず、サーバは稼働し続ける。
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

// MARK: - サーバプロセス用ヘルパー（重複パターン。ファイル先頭のdocコメントを参照）

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
        environment["HAZKEY_DICTIONARY"] = packageRoot
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        // 同一 `swift test` プロセスで先行フィクスチャが設定した環境上書きを明示的に消去し、
        // このフィクスチャの値だけを適用する。
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

/// `CandidateParityTests.ParityRPCClient` から複製した最小限の長さプレフィックス付き
/// UNIXソケット protobuf クライアント。トップレベルの `private` によりこのクラスは
/// ファイルスコープとなり、移植元ファイルは編集できない。
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

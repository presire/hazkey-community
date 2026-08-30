import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// Opt-in Zenzai (`zenzaiEnable=true`) candidate-output parity harness.
///
/// `OutputParityTests.swift` pins `zenzaiEnable = false` (see the comment at
/// `state.swift:578`, "config.swift:578 enables neural conversion when this
/// remains true") so it never exercises the Zenzai/llama.cpp code path.
/// `InferenceSeamBenchmarkTests.swift` records `zenzai_inference_ms` timing
/// only and never the candidate text itself. Neither existing harness can
/// detect a candidate-output regression caused by a llama.cpp/Zenzai backend
/// update. This file closes that gap: it drives a real subprocess
/// `hazkey-server` with a real Zenzai model through the same UNIX-socket
/// protobuf transport used by production clients, and records/compares the
/// resulting candidate text so a future llama.cpp update can be verified for
/// candidate parity.
///
/// Fully opt-in: skipped unless `HAZKEY_PARITY=1`. Never runs as part of the
/// default `swift test` suite, and never touches the live system
/// `hazkey-server` (it always spawns its own subprocess under an isolated
/// temporary XDG root — same isolation strategy as
/// `InferenceSeamBenchmarkTests.startServer` / `OutputParityTests.setUpWithError`).
// allow: SIZE_OK — this one staged test file intentionally owns its isolated server and socket harness.
final class CandidateParityTests: XCTestCase {
    /// Readings reused from `CorpusFixtures.swift`, deduplicated in fixture
    /// declaration order (do not invent new corpus content here).
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

    // MARK: - Record / verify modes

    /// Baseline file absent: this is a record run. A determinism probe (two
    /// consecutive `getCandidates` calls per reading, no intervening state
    /// change) must pass before a baseline is written, since a non-deterministic
    /// candidate ranking would make any future verify comparison meaningless.
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

    /// Baseline file present: this is a verify run. A single pass over the
    /// corpus is compared against the recorded baseline; the determinism
    /// probe already ran at record time, so it is not repeated here.
    private func runVerify(baselineURL: URL, modelPath: String) throws {
        let (snapshot, _) = try collectCandidates(
            corpus: Self.corpus, modelPath: modelPath, probeDeterminism: false)
        let baselineData = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode([String: [String]].self, from: baselineData)
        XCTAssertEqual(
            snapshot, baseline, "Candidate output diverged from recorded baseline at \(baselineURL.path)")
    }

    // MARK: - Model path resolution
    // Mirrors task-4/task-5 evidence in .omo/evidence/hazkey-zenzai-inference/:
    // prefer an explicit HAZKEY_ZENZAI_MODEL override, otherwise fall back to
    // the real, pinned user-level model used by the live system server.

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
            .appendingPathComponent(".local/share/hazkey/zenzai/zenzai.gguf").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ParityError.modelMissing(path)
        }
        return path
    }

    // MARK: - Server-driven candidate collection

    /// Starts one isolated subprocess `hazkey-server`, replays `corpus`
    /// through it with `zenzaiEnable = true`, and returns the candidate-text
    /// snapshot. When `probeDeterminism` is true, each reading's
    /// `getCandidates` call is issued twice consecutively (no intervening
    /// state change — `getCandidates` is idempotent, see
    /// `ensureCompositionSeparatorForConversion` at `state.swift:355-367`)
    /// and any mismatching reading is reported via the returned failure list
    /// instead of throwing, so the caller can decide how to react.
    private func collectCandidates(
        corpus: [String],
        modelPath: String,
        probeDeterminism: Bool
    ) throws -> (snapshot: [String: [String]], probeFailures: [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-candidate-parity-\(UUID().uuidString)", isDirectory: true)
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

        let socketURL = root.appendingPathComponent("runtime/hazkey-server.\(getuid()).sock")
        let socketIsIsolated = socketURL.standardizedFileURL.path.hasPrefix(
            root.standardizedFileURL.path + "/")
        XCTAssertTrue(socketIsIsolated, "Test socket must remain under its temporary XDG root.")
        guard socketIsIsolated else { throw ParityError.socketEscapesSandbox(socketURL.path) }
        try waitForSocket(at: socketURL.path)

        let client = try ParityRPCClient(socketPath: socketURL.path)
        // The socket is closed by `ParityRPCClient.deinit` when `client` goes
        // out of scope; an explicit `defer { client.close() }` here would just
        // duplicate that close. (deinit also covers the init-throws path,
        // where the already-opened file descriptor must be released.)
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
        // Pin the system dictionary submodule so candidate output does not
        // depend on the real user's ~/.local/share dictionary state.
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
        if let override = ProcessInfo.processInfo.environment["HAZKEY_SERVER_TEST_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let cmakeExecutable = packageRoot.deletingLastPathComponent().appendingPathComponent(
            "build/hazkey-server/swift-build/x86_64-unknown-linux-gnu/release/hazkey-server")
        if FileManager.default.isExecutableFile(atPath: cmakeExecutable.path) {
            return cmakeExecutable
        }
        let swiftExecutable = packageRoot.appendingPathComponent(".build/debug/hazkey-server")
        guard FileManager.default.isExecutableFile(atPath: swiftExecutable.path) else {
            throw ParityError.serverExecutableMissing(cmakeExecutable.path)
        }
        return swiftExecutable
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

/// Minimal length-prefixed UNIX-socket protobuf client. This mirrors
/// `InferenceSeamBenchmarkTests.BenchmarkClient` byte-for-byte in framing and
/// transact behavior (connect / length-prefixed send / length-prefixed
/// receive). It cannot be imported directly because Swift's top-level
/// `private` makes that class file-scoped to `InferenceSeamBenchmarkTests.swift`
/// (and that file must not be edited), so the same client pattern is
/// reproduced here rather than reinvented.
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

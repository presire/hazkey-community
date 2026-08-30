import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

// allow: SIZE_OK — this one staged test file intentionally owns its isolated server and socket harness.
final class InferenceSeamBenchmarkTests: XCTestCase {
    private let corpus = [
        "かな", "にほんご", "きょう", "あした", "とうきょう", "へんかん",
        "かんじ", "じしょ", "せいのう", "がくしゅう", "ぷろぐらむ", "にゅうりょく",
    ]

    func testOptInRealZenzaiDifferentialBenchmark() throws {
        let benchmarkMode = ProcessInfo.processInfo.environment["HAZKEY_BENCH"] ?? ""
        try XCTSkipUnless(!benchmarkMode.isEmpty, "Set HAZKEY_BENCH=1 to run the real-model benchmark.")

        let modelPath = try zenzaiModelPath()
        let runAEnabled = benchmarkMode != "probe-run-a-off"
        let onRun = try runCorpus(
            zenzaiEnabled: runAEnabled,
            modelPath: modelPath,
            warmedIterations: 20)
        if runAEnabled {
            try writeJSONL(onRun, named: "task-4-bench-on.jsonl")
        }
        let onEvents = candidateEvents(in: onRun.events)
        try assertZenzaiOn(onEvents, expectedCount: corpus.count * 21)

        if !runAEnabled {
            return
        }

        let offRun = try runCorpus(
            zenzaiEnabled: false,
            modelPath: modelPath,
            warmedIterations: 5)
        try writeJSONL(offRun, named: "task-4-bench-off.jsonl")
        let offEvents = candidateEvents(in: offRun.events)
        try assertZenzaiOff(offEvents, expectedCount: corpus.count * 6)

        try writeReport(onRun: onRun, offRun: offRun)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var evidenceDirectory: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".omo/evidence/hazkey-zenzai-inference", isDirectory: true)
    }

    private func zenzaiModelPath() throws -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw BenchmarkError.missingHome
        }
        let path = URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/hazkey/zenzai/zenzai.gguf").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw BenchmarkError.modelMissing(path)
        }
        return path
    }

    private func runCorpus(
        zenzaiEnabled: Bool,
        modelPath: String,
        warmedIterations: Int
    ) throws -> BenchmarkRun {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-inference-benchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["runtime", "data", "config", "cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let evidenceURL = root.appendingPathComponent("events.jsonl")
        let process = try startServer(root: root, evidenceURL: evidenceURL, modelPath: modelPath)
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let socketURL = root.appendingPathComponent("runtime/hazkey-server.\(getuid()).sock")
        let socketIsIsolated = socketURL.standardizedFileURL.path.hasPrefix(
            root.standardizedFileURL.path + "/")
        XCTAssertTrue(socketIsIsolated, "Test socket must remain under its temporary XDG root.")
        guard socketIsIsolated else { throw BenchmarkError.socketEscapesSandbox(socketURL.path) }
        try waitForSocket(at: socketURL.path)

        let client = try BenchmarkClient(socketPath: socketURL.path)
        defer { client.close() }
        try setDeterministicProfile(client: client, zenzaiEnabled: zenzaiEnabled)
        let backend = try captureBackend(client: client)
        for _ in 0...warmedIterations {
            try replayFixedCorpus(client: client)
        }

        let rawLines = try String(contentsOf: evidenceURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        return BenchmarkRun(rawLines: rawLines, events: try rawLines.map(parseEvent), backend: backend)
    }

    private func startServer(root: URL, evidenceURL: URL, modelPath: String) throws -> Process {
        let process = Process()
        process.executableURL = try serverExecutable()
        process.currentDirectoryURL = packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["HAZKEY_PERF_EVIDENCE"] = evidenceURL.path
        environment["HAZKEY_ZENZAI_MODEL"] = modelPath
        environment["HAZKEY_DICTIONARY"] = packageRoot
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        process.environment = environment
        try process.run()
        return process
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
            throw BenchmarkError.serverExecutableMissing(cmakeExecutable.path)
        }
        return swiftExecutable
    }

    private func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw BenchmarkError.socketTimeout(path)
    }

    private func setDeterministicProfile(client: BenchmarkClient, zenzaiEnabled: Bool) throws {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useInputHistory = false
        profile.useUserDictionary = false
        profile.zenzaiEnable = zenzaiEnabled
        var request = Hazkey_RequestEnvelope()
        request.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = [profile] }
        XCTAssertEqual(try client.send(request).status, .success)
    }

    private func captureBackend(client: BenchmarkClient) throws -> BackendRecord {
        var request = Hazkey_RequestEnvelope()
        request.getConfig = Hazkey_Config_GetConfig()
        let response = try client.send(request)
        XCTAssertEqual(response.status, .success)
        let activeProfile = try XCTUnwrap(response.currentConfig.profiles.first)
        return BackendRecord(
            activeProfileBackend: activeProfile.zenzaiBackendDeviceName,
            devices: response.currentConfig.availableZenzaiBackendDevices.map { "\($0.name): \($0.desc)" },
            modelAvailable: response.currentConfig.zenzaiModelAvailable,
            modelPath: response.currentConfig.zenzaiModelPath)
    }

    private func replayFixedCorpus(client: BenchmarkClient) throws {
        for reading in corpus {
            var newComposing = Hazkey_RequestEnvelope()
            newComposing.newComposingText = Hazkey_Commands_NewComposingText()
            XCTAssertEqual(try client.send(newComposing).status, .success, reading)
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

    private func assertZenzaiOn(_ events: [[String: Any]], expectedCount: Int) throws {
        XCTAssertEqual(events.count, expectedCount)
        for event in events {
            XCTAssertEqual(event["zenzai"] as? String, "on")
            let stages = try XCTUnwrap(event["stages"] as? [String: Any])
            let inference = try XCTUnwrap(stages["zenzai_inference_ms"] as? Double)
            let candidate = try XCTUnwrap(stages["candidate_generation_ms"] as? Double)
            XCTAssertGreaterThan(inference, 0)
            XCTAssertLessThanOrEqual(inference, candidate)
        }
    }

    private func assertZenzaiOff(_ events: [[String: Any]], expectedCount: Int) throws {
        XCTAssertEqual(events.count, expectedCount)
        for event in events {
            XCTAssertEqual(event["zenzai"] as? String, "off")
            let stages = try XCTUnwrap(event["stages"] as? [String: Any])
            XCTAssertNil(stages["zenzai_inference_ms"])
        }
    }

    private func writeJSONL(_ run: BenchmarkRun, named name: String) throws {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try run.rawLines.joined(separator: "\n").appending("\n").write(
            to: evidenceDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeReport(onRun: BenchmarkRun, offRun: BenchmarkRun) throws {
        let onEvents = candidateEvents(in: onRun.events)
        let offEvents = candidateEvents(in: offRun.events)
        let onWarmed = Array(onEvents.dropFirst(corpus.count))
        let offWarmed = Array(offEvents.dropFirst(corpus.count))
        let onCandidate = try stage("candidate_generation_ms", in: onWarmed)
        let inference = try stage("zenzai_inference_ms", in: onWarmed)
        let offCandidate = try stage("candidate_generation_ms", in: offWarmed)
        let ratio = inference.enumerated().map { inference[$0.offset] / onCandidate[$0.offset] }
        let medianRatio = try nearestRank(ratio, numerator: 50, denominator: 100)
        let dominates = medianRatio > 0.5
        let comparison: String
        if onRun.backend.activeProfileBackend == "CPU" {
            comparison = "task-5 baseline comparison: comparable (active backend=CPU); baseline candidate_generation_ms p50=9.497526 p95=15.068931 ms."
        } else {
            comparison = "task-5 baseline comparison: incomparable because task-5 used CPU but this run used \(onRun.backend.activeProfileBackend)."
        }
        let lines = [
            "# Task 4 — opt-in real-Zenzai differential benchmark",
            "profile: useInputHistory=false; useUserDictionary=false; Run A zenzaiEnable=true; cold_passes=1; warmed_iterations=20; warmed_candidate_events=\(onWarmed.count)",
            "Run B: zenzaiEnable=false; cold_passes=1; warmed_iterations=5; warmed_candidate_events=\(offWarmed.count)",
            "backend devices (getConfig): \(onRun.backend.devices.joined(separator: " | "))",
            "active profile backend (getConfig): \(onRun.backend.activeProfileBackend); zenzai model available=\(onRun.backend.modelAvailable); model path=\(onRun.backend.modelPath)",
            "quantiles: nearest-rank on sorted warmed samples (p50=ceil(0.50*n), p95=ceil(0.95*n)); ms",
            try quantiles("Run A candidate_generation_ms", onCandidate),
            try quantiles("Run A zenzai_inference_ms", inference),
            try quantiles("Run B candidate_generation_ms", offCandidate),
            String(format: "Run A warmed median zenzai_inference_ms / candidate_generation_ms ratio=%.6f", medianRatio),
            comparison,
            "DOMINANCE VERDICT: Real neural work \(dominates ? "dominates" : "does not dominate") candidate generation on this fixed warmed corpus (median ratio=\(String(format: "%.6f", medianRatio))).",
            dominates
                ? "Future llama.cpp update planning is justified by this measured neural-work dominance."
                : "Future llama.cpp update planning is not justified by neural-work dominance from this benchmark alone.",
            "No wall-clock threshold was asserted; binary seam and differential assertions determine test success.",
            "Run A backend record: \(onRun.backend.activeProfileBackend); Run B backend record: \(offRun.backend.activeProfileBackend).",
        ]
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(
            to: evidenceDirectory.appendingPathComponent("task-4-benchmark.txt"), atomically: true, encoding: .utf8)
    }

    private func candidateEvents(in events: [[String: Any]]) -> [[String: Any]] {
        events.filter { $0["type"] as? String == "getCandidates" }
    }

    private func stage(_ name: String, in events: [[String: Any]]) throws -> [Double] {
        try events.map { event in
            let stages = try XCTUnwrap(event["stages"] as? [String: Any])
            return try XCTUnwrap(stages[name] as? Double)
        }
    }

    private func quantiles(_ label: String, _ values: [Double]) throws -> String {
        let sorted = values.sorted()
        guard let minimum = sorted.first, let maximum = sorted.last else {
            throw BenchmarkError.emptySamples(label)
        }
        return String(format: "%@: samples=%d p50=%.6f p95=%.6f min=%.6f max=%.6f", label, sorted.count,
                      try nearestRank(sorted, numerator: 50, denominator: 100),
                      try nearestRank(sorted, numerator: 95, denominator: 100), minimum, maximum)
    }

    private func nearestRank(_ values: [Double], numerator: Int, denominator: Int) throws -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { throw BenchmarkError.emptySamples("quantile") }
        return sorted[(numerator * sorted.count + denominator - 1) / denominator - 1]
    }

    private func parseEvent(_ rawEvent: String) throws -> [String: Any] {
        guard let event = try JSONSerialization.jsonObject(with: Data(rawEvent.utf8)) as? [String: Any] else {
            throw BenchmarkError.invalidEvidence
        }
        return event
    }
}

private struct BenchmarkRun {
    let rawLines: [String]
    let events: [[String: Any]]
    let backend: BackendRecord
}

private struct BackendRecord {
    let activeProfileBackend: String
    let devices: [String]
    let modelAvailable: Bool
    let modelPath: String
}

private enum BenchmarkError: Error {
    case invalidEvidence
    case emptySamples(String)
    case missingHome
    case modelMissing(String)
    case serverExecutableMissing(String)
    case socketEscapesSandbox(String)
    case socketTimeout(String)
}

private final class BenchmarkClient {
    private var fileDescriptor: Int32

    init(socketPath: String) throws {
        fileDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else { throw BenchmarkError.socketTimeout(socketPath) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw BenchmarkError.socketTimeout(socketPath)
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
        guard connected == 0 else { throw BenchmarkError.socketTimeout(socketPath) }
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
                guard written > 0 else { throw BenchmarkError.invalidEvidence }
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
                guard readCount > 0 else { throw BenchmarkError.invalidEvidence }
                offset += readCount
            }
        }
        return data
    }
}

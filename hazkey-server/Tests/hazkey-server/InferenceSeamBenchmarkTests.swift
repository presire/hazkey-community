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
        let onEvents = candidateEvents(in: onRun.events)
        try assertZenzaiOn(onEvents, expectedCount: corpus.count * 21)

        if !runAEnabled {
            return
        }

        let offRun = try runCorpus(
            zenzaiEnabled: false,
            modelPath: modelPath,
            warmedIterations: 5)
        let offEvents = candidateEvents(in: offRun.events)
        try assertZenzaiOff(offEvents, expectedCount: corpus.count * 6)
    }

    func testOptInCPUContentionBaseline() throws {
        let cpuLoadMode = ProcessInfo.processInfo.environment["HAZKEY_BENCH_CPU_LOAD"] ?? ""
        try XCTSkipUnless(!cpuLoadMode.isEmpty, "Set HAZKEY_BENCH_CPU_LOAD=1 to run the CPU-contention baseline.")

        let modelPath = try zenzaiModelPath()
        let idleBaseline = try sampleIdleCPU()
        let withoutLoad = try runCorpus(
            zenzaiEnabled: true,
            modelPath: modelPath,
            warmedIterations: 20)
        let withoutLoadEvents = candidateEvents(in: withoutLoad.events)
        try assertZenzaiOn(withoutLoadEvents, expectedCount: corpus.count * 21)
        try writeJSONL(withoutLoad, named: "task-1-bench-load-off.jsonl")

        let loadDriver = CPULoadDriver()
        let duringLoad = CPUSampler()
        let withLoad = try runCorpus(
            zenzaiEnabled: true,
            modelPath: modelPath,
            warmedIterations: 20,
            loadDriver: loadDriver,
            cpuSampler: duringLoad)
        let withLoadEvents = candidateEvents(in: withLoad.events)
        try assertZenzaiOn(withLoadEvents, expectedCount: corpus.count * 21)
        try writeJSONL(withLoad, named: "task-1-bench-load-on.jsonl")
        try writeCPUContentionReport(
            withoutLoad: withoutLoad,
            withLoad: withLoad,
            idleBaseline: idleBaseline,
            duringLoad: try duringLoad.summary(),
            loadDriverDescription: loadDriver.description)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var evidenceDirectory: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".omo/evidence/hazkey-ime-cpu-latency", isDirectory: true)
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
        warmedIterations: Int,
        loadDriver: CPULoadDriver? = nil,
        cpuSampler: CPUSampler? = nil
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
        try replayFixedCorpus(client: client)

        if let loadDriver {
            try loadDriver.start()
            defer { loadDriver.stop() }
            try cpuSampler?.start()
        }
        for _ in 0..<warmedIterations {
            try replayFixedCorpus(client: client, cpuSampler: cpuSampler)
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

    private func replayFixedCorpus(client: BenchmarkClient, cpuSampler: CPUSampler? = nil) throws {
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
            try cpuSampler?.recordIfDue()
        }
    }

    private func assertZenzaiOn(_ events: [[String: Any]], expectedCount: Int) throws {
        XCTAssertEqual(events.count, expectedCount)
        var positiveInferenceCount = 0
        for event in events {
            XCTAssertEqual(event["zenzai"] as? String, "on")
            let stages = try XCTUnwrap(event["stages"] as? [String: Any])
            let inference = try XCTUnwrap(stages["zenzai_inference_ms"] as? Double)
            let candidate = try XCTUnwrap(stages["candidate_generation_ms"] as? Double)
            XCTAssertGreaterThanOrEqual(inference, 0)
            XCTAssertLessThanOrEqual(inference, candidate)
            if inference > 0 {
                positiveInferenceCount += 1
            }
        }
        XCTAssertGreaterThan(positiveInferenceCount, 0, "The full on-run must contain at least one real inference sample.")
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

    private func sampleIdleCPU() throws -> CPUSamplingSummary {
        let sampler = CPUSampler()
        try sampler.start()
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.2)
            try sampler.recordNow()
        }
        return try sampler.summary()
    }

    private func writeCPUContentionReport(
        withoutLoad: BenchmarkRun,
        withLoad: BenchmarkRun,
        idleBaseline: CPUSamplingSummary,
        duringLoad: CPUSamplingSummary,
        loadDriverDescription: String
    ) throws {
        let withoutEvents = candidateEvents(in: withoutLoad.events)
        let withEvents = candidateEvents(in: withLoad.events)
        let withoutCandidate = try stage("candidate_generation_ms", in: withoutEvents)
        let withCandidate = try stage("candidate_generation_ms", in: withEvents)
        let withoutInference = try stage("zenzai_inference_ms", in: withoutEvents).filter { $0 > 0 }
        let withInference = try stage("zenzai_inference_ms", in: withEvents).filter { $0 > 0 }
        let withoutDictionary = try dictionaryReloadSummary(withoutEvents)
        let withDictionary = try dictionaryReloadSummary(withEvents)
        let lines = [
            "# Task 1 — CPU-contention baseline",
            "profile: useInputHistory=false; useUserDictionary=false; zenzaiEnable=true; fresh isolated server per run; one no-load warmup corpus followed by 20 measured corpus iterations.",
            "load driver: \(loadDriverDescription); started after server startup and warmup, before the with-load measurement pass; stopped immediately after that pass.",
            "quantiles: nearest-rank on sorted full-run samples (p50=ceil(0.50*n), p95=ceil(0.95*n)); ms.",
            "without-load request count (getCandidates): \(withoutEvents.count)",
            try quantiles("without-load candidate_generation_ms", withoutCandidate),
            "without-load positive zenzai_inference_ms count=\(withoutInference.count) of \(withoutEvents.count)",
            try quantiles("without-load positive zenzai_inference_ms", withoutInference),
            "with-load request count (getCandidates): \(withEvents.count)",
            try quantiles("with-load candidate_generation_ms", withCandidate),
            "with-load positive zenzai_inference_ms count=\(withInference.count) of \(withEvents.count)",
            try quantiles("with-load positive zenzai_inference_ms", withInference),
            "without-load \(withoutDictionary)",
            "with-load \(withDictionary)",
            "idle CPU before load: \(idleBaseline.description)",
            "idle CPU during with-load measurement: \(duringLoad.description)",
            "backend record without-load: \(withoutLoad.backend.description)",
            "backend record with-load: \(withLoad.backend.description)",
            "determinism: fixed 12-reading corpus, isolated XDG roots, deterministic profile, fresh server per condition; the incremental lattice cache may legitimately yield zero inference time for repeated inputs.",
            "No wall-clock threshold is asserted; this report is advisory evidence only.",
        ]
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(
            to: evidenceDirectory.appendingPathComponent("task-1-benchmark.txt"), atomically: true, encoding: .utf8)
    }

    private func dictionaryReloadSummary(_ events: [[String: Any]]) throws -> String {
        let reloadDurations = try stage("user_dictionary_reload_ms", in: events)
        let total = reloadDurations.reduce(0, +)
        return String(format: "dictionary reload stage count=%d; total user_dictionary_reload_ms=%.6f (analysis-level event count, not a production import counter)", reloadDurations.count, total)
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

    var description: String {
        "active profile backend=\(activeProfileBackend); model available=\(modelAvailable); model path=\(modelPath); devices=\(devices.joined(separator: " | "))"
    }
}

private struct CPUSamplingSummary {
    let idlePercentages: [Double]
    let busyPercentages: [Double]

    var description: String {
        String(
            format: "samples=%d; idle_cpu_percent mean=%.2f min=%.2f; busy_cpu_percent mean=%.2f max=%.2f",
            idlePercentages.count,
            idlePercentages.reduce(0, +) / Double(idlePercentages.count),
            idlePercentages.min() ?? 0,
            busyPercentages.reduce(0, +) / Double(busyPercentages.count),
            busyPercentages.max() ?? 0)
    }
}

private final class CPUSampler {
    private var previous: CPUJiffies?
    private var lastSampleAt = Date.distantPast
    private var idlePercentages: [Double] = []
    private var busyPercentages: [Double] = []

    func start() throws {
        previous = try CPUJiffies.read()
        lastSampleAt = Date()
    }

    func recordIfDue() throws {
        guard Date().timeIntervalSince(lastSampleAt) >= 0.2 else { return }
        try recordNow()
    }

    func recordNow() throws {
        let current = try CPUJiffies.read()
        guard let previous else { throw BenchmarkError.cpuSamplerNotStarted }
        let totalDelta = current.total - previous.total
        guard totalDelta > 0 else { throw BenchmarkError.invalidCPUStat }
        let idleDelta = current.idle - previous.idle
        let idlePercentage = Double(idleDelta) * 100 / Double(totalDelta)
        idlePercentages.append(idlePercentage)
        busyPercentages.append(100 - idlePercentage)
        self.previous = current
        lastSampleAt = Date()
    }

    func summary() throws -> CPUSamplingSummary {
        guard !idlePercentages.isEmpty else { throw BenchmarkError.emptyCPUSamples }
        return CPUSamplingSummary(idlePercentages: idlePercentages, busyPercentages: busyPercentages)
    }
}

private struct CPUJiffies {
    let total: UInt64
    let idle: UInt64

    static func read() throws -> CPUJiffies {
        let contents = try String(contentsOfFile: "/proc/stat", encoding: .utf8)
        guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else {
            throw BenchmarkError.invalidCPUStat
        }
        let fields = line.split(separator: " ").dropFirst()
        let values = try fields.map { field -> UInt64 in
            guard let value = UInt64(field) else { throw BenchmarkError.invalidCPUStat }
            return value
        }
        guard values.count >= 5 else { throw BenchmarkError.invalidCPUStat }
        return CPUJiffies(total: values.reduce(0, +), idle: values[3] + values[4])
    }
}

private final class CPULoadDriver {
    private let spinnerCount = max(1, ProcessInfo.processInfo.processorCount - 2)
    private var spinners: [Process] = []

    var description: String {
        "\(spinnerCount) /bin/sh busy-loop spinner subprocesses (nproc-equivalent minus two reserved cores)"
    }

    func start() throws {
        for _ in 0..<spinnerCount {
            let spinner = Process()
            spinner.executableURL = URL(fileURLWithPath: "/bin/sh")
            spinner.arguments = ["-c", "while :; do :; done"]
            try spinner.run()
            spinners.append(spinner)
        }
    }

    func stop() {
        for spinner in spinners where spinner.isRunning {
            spinner.terminate()
            spinner.waitUntilExit()
        }
        spinners.removeAll()
    }

    deinit { stop() }
}

private enum BenchmarkError: Error {
    case invalidEvidence
    case emptySamples(String)
    case missingHome
    case modelMissing(String)
    case serverExecutableMissing(String)
    case socketEscapesSandbox(String)
    case socketTimeout(String)
    case cpuSamplerNotStarted
    case emptyCPUSamples
    case invalidCPUStat
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

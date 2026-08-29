import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

final class PerfProbeTests: XCTestCase {
    func testRequestCountsMatchBaselineAcrossColdAndWarmCorpusRuns() throws {
        let run = try runCorpus(zenzaiEnabled: true)
        let observed = counts(in: run.events)
        let baselineURL = packageRoot
            .appendingPathComponent("Tests/hazkey-server/rpc_baseline.json")
        try assertBaseline(observed, at: baselineURL)

        let firstPassRequestCount = 49
        let coldEvents = Array(run.events.dropFirst().prefix(firstPassRequestCount))
        let warmEvents = Array(run.events.dropFirst(1 + firstPassRequestCount))
        try writeEvidence(
            named: "task-2-benchmark.txt",
            lines: run.rawLines + [
                "cold_counts=\(try countsJSON(in: coldEvents))",
                "warm_counts=\(try countsJSON(in: warmEvents))",
                "zenzai_markers=\(candidateMarkers(in: run.events))",
            ])
    }

    func testDisabledZenzaiEmitsOffMarkerAndCandidateStages() throws {
        let run = try runCorpus(zenzaiEnabled: false)
        let candidateEvents = run.events.filter { $0["type"] as? String == "getCandidates" }
        XCTAssertFalse(candidateEvents.isEmpty)
        for event in candidateEvents {
            XCTAssertEqual(event["zenzai"] as? String, "off")
            XCTAssertNotNil(event["stages"] as? [String: Any])
        }
        try writeEvidence(named: "task-2-failure.txt", lines: run.rawLines)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var evidenceDirectory: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".omo/evidence/hazkey-performance", isDirectory: true)
    }

    private func runCorpus(zenzaiEnabled: Bool) throws -> ProbeRun {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-perf-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for name in ["runtime", "data", "config", "cache"] {
            try FileManager.default.createDirectory(
                at: temporaryRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let evidenceURL = temporaryRoot.appendingPathComponent("evidence.jsonl")
        let process = try startServer(root: temporaryRoot, evidenceURL: evidenceURL)
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let socketPath = temporaryRoot.appendingPathComponent(
            "runtime/hazkey-server.\(getuid()).sock").path
        try waitForSocket(at: socketPath)
        let client = try EnvelopeClient(socketPath: socketPath)
        defer { client.close() }
        try setDeterministicProfile(client: client, zenzaiEnabled: zenzaiEnabled)
        try replayCorpus(client: client)
        try replayCorpus(client: client)

        let rawLines = try String(contentsOf: evidenceURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let events = try rawLines.map(parseJSONLine)
        return ProbeRun(rawLines: rawLines, events: events)
    }

    private func startServer(root: URL, evidenceURL: URL) throws -> Process {
        let executable = try serverExecutable()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["HAZKEY_PERF_EVIDENCE"] = evidenceURL.path
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
        let executable = packageRoot.appendingPathComponent(".build/debug/hazkey-server")
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--traits", "ZenzaiSupport"]
        build.currentDirectoryURL = packageRoot
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw ProbeError.serverBuildFailed }
        return executable
    }

    private func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw ProbeError.socketTimeout(path)
    }

    private func setDeterministicProfile(client: EnvelopeClient, zenzaiEnabled: Bool) throws {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useInputHistory = false
        profile.useUserDictionary = false
        profile.zenzaiEnable = zenzaiEnabled
        var request = Hazkey_RequestEnvelope()
        request.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = [profile] }
        XCTAssertEqual(try client.send(request).status, .success)
    }

    private func replayCorpus(client: EnvelopeClient) throws {
        for fixture in [
            CorpusFixtures.fullConversion,
            CorpusFixtures.suggestion,
            CorpusFixtures.prefixConversion,
            CorpusFixtures.kanaNumber,
            CorpusFixtures.relativeDate,
            CorpusFixtures.nonLearnableCommit,
        ] {
            var newComposing = Hazkey_RequestEnvelope()
            newComposing.newComposingText = Hazkey_Commands_NewComposingText()
            XCTAssertEqual(try client.send(newComposing).status, .success, fixture.name)
            for character in fixture.reading {
                var input = Hazkey_RequestEnvelope()
                input.inputChar = Hazkey_Commands_InputChar.with { $0.text = String(character) }
                XCTAssertEqual(try client.send(input).status, .success, fixture.name)
            }
            if case .prefix(let offset) = fixture.request {
                var move = Hazkey_RequestEnvelope()
                move.moveCursor = Hazkey_Commands_MoveCursor.with { $0.offset = Int32(offset) }
                XCTAssertEqual(try client.send(move).status, .success, fixture.name)
            }
            var hiragana = Hazkey_RequestEnvelope()
            hiragana.getHiraganaWithCursor = Hazkey_Commands_GetHiraganaWithCursor()
            XCTAssertEqual(try client.send(hiragana).status, .success, fixture.name)
            for isSuggestion in [false, true] {
                var candidates = Hazkey_RequestEnvelope()
                candidates.getCandidates = Hazkey_Commands_GetCandidates.with {
                    $0.isSuggest = isSuggestion
                }
                XCTAssertEqual(try client.send(candidates).status, .success, fixture.name)
            }
        }
    }

    private func parseJSONLine(_ line: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw ProbeError.invalidEvidence
        }
        return object
    }

    private func counts(in events: [[String: Any]]) -> [String: Int] {
        Dictionary(grouping: events, by: { $0["type"] as? String ?? "unknown" })
            .mapValues(\.count)
    }

    private func countsJSON(in events: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: counts(in: events), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func candidateMarkers(in events: [[String: Any]]) -> [String] {
        events.compactMap { event in
            event["type"] as? String == "getCandidates" ? event["zenzai"] as? String : nil
        }
    }

    private func assertBaseline(_ observed: [String: Int], at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        }
        let data = try Data(contentsOf: url)
        let expected = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        XCTAssertEqual(observed, expected)
    }

    private func writeEvidence(named name: String, lines: [String]) throws {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(
            to: evidenceDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

private struct ProbeRun {
    let rawLines: [String]
    let events: [[String: Any]]
}

private enum ProbeError: Error {
    case invalidEvidence
    case serverBuildFailed
    case socketTimeout(String)
}

private final class EnvelopeClient {
    private var fileDescriptor: Int32

    init(socketPath: String) throws {
        fileDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else { throw ProbeError.socketTimeout(socketPath) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ProbeError.socketTimeout(socketPath)
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
        guard connected == 0 else { throw ProbeError.socketTimeout(socketPath) }
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
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fileDescriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                guard written > 0 else { throw ProbeError.invalidEvidence }
                offset += written
            }
        }
    }

    private func readAll(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let readCount = read(fileDescriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                guard readCount > 0 else { throw ProbeError.invalidEvidence }
                offset += readCount
            }
        }
        return data
    }
}

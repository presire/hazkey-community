import Foundation
import Glibc
import SwiftProtobuf
import XCTest

@testable import hazkey_server

// 唯一共有する依存先は"TestTempRoot"のみ
// sun_path用に短い一時ルートを使う
final class InferenceSeamTests: XCTestCase {
    func testDisabledZenzaiOmitsInferenceStage() throws {
        let run = try runServer(zenzaiEnabled: false, modelPath: nil)
        let candidateEvents = candidateEvents(in: run.events)

        XCTAssertFalse(candidateEvents.isEmpty)
        for event in candidateEvents {
            XCTAssertEqual(event["zenzai"] as? String, "off")
            let stages = try XCTUnwrap(event["stages"] as? [String: Any])
            XCTAssertNotNil(stages["candidate_generation_ms"])
            XCTAssertNil(stages["zenzai_inference_ms"])
        }
    }

    func testEnabledZenzaiRecordsInferenceStageWhenModelExists() throws {
        guard let home = getenv("HOME") else {
            throw InferenceSeamError.missingHome
        }
        let modelPath = URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent(".local/share/hazkey-community/zenzai/zenzai.gguf").path
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelPath),
            "Zenzai model is not installed at \(modelPath)")

        let run = try runServer(zenzaiEnabled: true, modelPath: modelPath)
        let candidateEvents = candidateEvents(in: run.events)

        XCTAssertFalse(candidateEvents.isEmpty)
        for event in candidateEvents {
            XCTAssertEqual(event["zenzai"] as? String, "on")
            let stages = try XCTUnwrap(event["stages"] as? [String: Any])
            let inferenceMilliseconds = try XCTUnwrap(stages["zenzai_inference_ms"] as? Double)
            let candidateMilliseconds = try XCTUnwrap(stages["candidate_generation_ms"] as? Double)
            XCTAssertGreaterThan(inferenceMilliseconds, 0)
            XCTAssertLessThanOrEqual(inferenceMilliseconds, candidateMilliseconds)
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runServer(zenzaiEnabled: Bool, modelPath: String?) throws -> InferenceSeamRun {
        let root = try TestTempRoot.make()
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

        let socketURL = root.appendingPathComponent("runtime/hazkey-community-server.\(getuid()).sock")
        XCTAssertTrue(socketURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        TestTempRoot.requireFitsInSunPath(socketURL.path)
        try waitForSocket(at: socketURL.path)
        let client = try InferenceSeamClient(socketPath: socketURL.path)
        defer { client.close() }
        try setDeterministicProfile(client: client, zenzaiEnabled: zenzaiEnabled)
        try replayFixedCorpus(client: client)

        let rawEvents = try String(contentsOf: evidenceURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        return InferenceSeamRun(events: try rawEvents.map(parseEvent))
    }

    private func startServer(root: URL, evidenceURL: URL, modelPath: String?) throws -> Process {
        let process = Process()
        process.executableURL = try serverExecutable()
        process.currentDirectoryURL = packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["HAZKEY_PERF_EVIDENCE"] = evidenceURL.path
        environment["HAZKEY_DICTIONARY"] = packageRoot
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        if let modelPath {
            environment["HAZKEY_ZENZAI_MODEL"] = modelPath
        }
        process.environment = environment
        try process.run()
        return process
    }

    private func serverExecutable() throws -> URL {
        guard let executable = TestServerBinary.resolve(packageRoot: packageRoot) else {
            throw InferenceSeamError.serverExecutableMissing(
                TestServerBinary.candidatePaths(packageRoot: packageRoot).joined(separator: ", "))
        }
        return executable
    }

    private func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw InferenceSeamError.socketTimeout(path)
    }

    private func setDeterministicProfile(client: InferenceSeamClient, zenzaiEnabled: Bool) throws {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.useInputHistory = false
        profile.useUserDictionary = false
        profile.zenzaiEnable = zenzaiEnabled
        var request = Hazkey_RequestEnvelope()
        request.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = [profile] }
        XCTAssertEqual(try client.send(request).status, .success)
    }

    private func replayFixedCorpus(client: InferenceSeamClient) throws {
        var newComposing = Hazkey_RequestEnvelope()
        newComposing.newComposingText = Hazkey_Commands_NewComposingText()
        XCTAssertEqual(try client.send(newComposing).status, .success)
        for character in "かな" {
            var input = Hazkey_RequestEnvelope()
            input.inputChar = Hazkey_Commands_InputChar.with { $0.text = String(character) }
            XCTAssertEqual(try client.send(input).status, .success)
        }
        var candidates = Hazkey_RequestEnvelope()
        candidates.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = false }
        XCTAssertEqual(try client.send(candidates).status, .success)
    }

    private func candidateEvents(in events: [[String: Any]]) -> [[String: Any]] {
        events.filter { $0["type"] as? String == "getCandidates" }
    }

    private func parseEvent(_ rawEvent: String) throws -> [String: Any] {
        guard let event = try JSONSerialization.jsonObject(with: Data(rawEvent.utf8)) as? [String: Any] else {
            throw InferenceSeamError.invalidEvidence
        }
        return event
    }
}

private struct InferenceSeamRun {
    let events: [[String: Any]]
}

private enum InferenceSeamError: Error {
    case invalidEvidence
    case missingHome
    case serverExecutableMissing(String)
    case socketTimeout(String)
}

private final class InferenceSeamClient {
    private var fileDescriptor: Int32

    init(socketPath: String) throws {
        fileDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else { throw InferenceSeamError.socketTimeout(socketPath) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw InferenceSeamError.socketTimeout(socketPath)
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
        guard connected == 0 else { throw InferenceSeamError.socketTimeout(socketPath) }
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
                guard written > 0 else { throw InferenceSeamError.invalidEvidence }
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
                guard readCount > 0 else { throw InferenceSeamError.invalidEvidence }
                offset += readCount
            }
        }
        return data
    }
}

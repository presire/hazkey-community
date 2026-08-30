import Foundation

/// Test-only request evidence sink. It is absent unless HAZKEY_PERF_EVIDENCE names a file.
final class PerfProbe: @unchecked Sendable {
    struct RequestMeasurement {
        fileprivate let type: String
        fileprivate let startedAt: UInt64
    }

    static let shared: PerfProbe? = makeIfEnabled()

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var sequence = 0
    private var stages: [String: Double] = [:]
    private var zenzai: String?

    private init?(path: String) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(atPath: path, contents: nil) else {
                NSLog("Failed to create HAZKEY_PERF_EVIDENCE file")
                return nil
            }
        }
        do {
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fileHandle.seekToEndOfFile()
        } catch {
            NSLog("Failed to open HAZKEY_PERF_EVIDENCE: \(error)")
            return nil
        }
    }

    deinit {
        try? fileHandle.close()
    }

    static func payloadType(_ payload: Hazkey_RequestEnvelope.OneOf_Payload?) -> String {
        switch payload {
        case .setContext: return "setContext"
        case .newComposingText: return "newComposingText"
        case .inputChar: return "inputChar"
        case .modifierEvent: return "modifierEvent"
        case .deleteLeft: return "deleteLeft"
        case .deleteRight: return "deleteRight"
        case .prefixComplete: return "prefixComplete"
        case .moveCursor: return "moveCursor"
        case .adjustClauseBoundary: return "adjustClauseBoundary"
        case .getHiraganaWithCursor: return "getHiraganaWithCursor"
        case .getComposingString: return "getComposingString"
        case .getCandidates: return "getCandidates"
        case .getCurrentInputMode: return "getCurrentInputMode"
        case .saveLearningData: return "saveLearningData"
        case .getConfig: return "getConfig"
        case .setConfig: return "setConfig"
        case .clearAllHistory_p: return "clearAllHistory"
        case .reloadZenzaiModel: return "reloadZenzaiModel"
        case .getDefaultProfile: return "getDefaultProfile"
        case .none: return "none"
        }
    }

    func begin(type: String) -> RequestMeasurement {
        lock.lock()
        stages = [:]
        zenzai = nil
        lock.unlock()
        return RequestMeasurement(type: type, startedAt: now())
    }

    func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func recordCandidateStages(
        userDictionaryStartedAt: UInt64,
        userDictionaryFinishedAt: UInt64,
        candidateStartedAt: UInt64,
        zenzai: String,
        zenzaiInferenceNanoseconds: UInt64? = nil
    ) {
        let finishedAt = now()
        lock.lock()
        stages["user_dictionary_reload_ms"] = milliseconds(from: userDictionaryStartedAt, to: userDictionaryFinishedAt)
        stages["candidate_generation_ms"] = milliseconds(from: candidateStartedAt, to: finishedAt)
        if let zenzaiInferenceNanoseconds {
            stages["zenzai_inference_ms"] = Double(zenzaiInferenceNanoseconds) / 1_000_000
        }
        self.zenzai = zenzai
        lock.unlock()
    }

    func finish(_ measurement: RequestMeasurement) {
        let finishedAt = now()
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        var event: [String: Any] = [
            "seq": sequence,
            "type": measurement.type,
            "total_ms": milliseconds(from: measurement.startedAt, to: finishedAt),
            "stages": stages,
        ]
        if let zenzai {
            event["zenzai"] = zenzai
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else {
            return
        }
        fileHandle.write(data)
        fileHandle.write(Data([0x0A]))
    }

    private static func makeIfEnabled() -> PerfProbe? {
        guard let path = ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"], !path.isEmpty else {
            return nil
        }
        return PerfProbe(path: path)
    }

    private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}

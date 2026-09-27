import Foundation

/// テスト専用のリクエスト計測シンク
///
/// [HAZKEY_PERF_EVIDENCE]がファイルを指定するときだけ生成される
///
/// 有効でない場合sharedはnilになり計測は行わない
///
/// - Note: テスト証跡のための常駐記録器であり通常動作には影響しない
final class PerfProbe: @unchecked Sendable {
    /// 1リクエスト分の計測値
    ///
    /// リクエスト種別名と開始時刻 (ナノ秒) を保持する
    ///
    /// - Note: begin(type:)が生成しfinish(_:)が消費する
    struct RequestMeasurement {
        /// リクエスト種別名
        fileprivate let type: String
        /// 開始時刻の単調時計値 (ナノ秒)
        fileprivate let startedAt: UInt64
    }

    /// プロセス全体で共有する計測器
    ///
    /// [HAZKEY_PERF_EVIDENCE]が設定されたときだけ生成され未設定や空文字ではnilになる
    static let shared: PerfProbe? = makeIfEnabled()

    /// 証跡ファイルへの書き込みハンドル
    private let fileHandle: FileHandle
    /// 計測状態を守る排他ロック
    private let lock = NSLock()
    /// 書き込み済みイベントの通番
    private var sequence = 0
    /// 段階別所要時間の集計(ミリ秒)
    private var stages: [String: Double] = [:]
    /// 直近に記録したZenzai動作モード
    private var zenzai: String?

    /// 証跡ファイルを開く
    ///
    /// 存在しない場合は空ファイルを作成し末尾に追記できる状態で開く
    ///
    /// 開けない場合はNSLogで記録してnilを返す
    ///
    /// - Parameter path: 証跡ファイルのパス
    /// - Note: 失敗時は呼び出し側のmakeIfEnabled()がnilを返す
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

    /// ファイルハンドルを閉じる
    deinit {
        try? fileHandle.close()
    }

    /// ペイロード種別を短い要求名に変換する
    ///
    /// 未対応や未設定はnoneを返す
    ///
    /// [getLearningHistory]と[deleteLearningEntries]と[deleteCandidateLearningData]も現状はnoneにまとめる
    ///
    /// - Parameter payload: 変換対象の要求ペイロード
    /// - Returns: 証跡に記録する要求名
    static func payloadType(_ payload: Hazkey_RequestEnvelope.OneOf_Payload?) -> String {
        switch payload {
        case .setContext: return "setContext"
        case .newComposingText: return "newComposingText"
        case .inputChar: return "inputChar"
        case .modifierEvent: return "modifierEvent"
        case .deleteLeft: return "deleteLeft"
        case .deleteRight: return "deleteRight"
        case .prefixComplete: return "prefixComplete"
        case .acceptPrediction: return "acceptPrediction"
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
        case .toggleZenzai: return "toggleZenzai"
        case .getLearningHistory, .deleteLearningEntries, .deleteCandidateLearningData, .none:
            return "none"
        }
    }

    /// 計測を開始する
    ///
    /// 段階集計とZenzai記録を初期化して開始時刻を刻む
    ///
    /// - Parameter type: 記録する要求名
    /// - Returns: 開始時刻を持つ計測値
    func begin(type: String) -> RequestMeasurement {
        lock.lock()
        stages = [:]
        zenzai = nil
        lock.unlock()
        return RequestMeasurement(type: type, startedAt: now())
    }

    /// 現在時刻をナノ秒で返す
    ///
    /// DispatchTimeの単調時計値を用いる
    ///
    /// - Returns: 起動起点からの経過ナノ秒
    func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// 候補生成の段階時間を記録する
    ///
    /// [user_dictionary_reload_ms]と[candidate_generation_ms]を確定し、推論時間があれば[zenzai_inference_ms]も残す
    ///
    /// Zenzai動作モード文字列も同時に保持する
    ///
    /// - Parameters:
    ///   - userDictionaryStartedAt: ユーザ辞書再読込の開始時刻 (ナノ秒)
    ///   - userDictionaryFinishedAt: ユーザ辞書再読込の終了時刻 (ナノ秒)
    ///   - candidateStartedAt: 候補生成の開始時刻 (ナノ秒)
    ///   - zenzai: Zenzai動作モード文字列
    ///   - zenzaiInferenceNanoseconds: Zenzai推論時間 (ナノ秒、ない場合は省略)
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

    /// 1件分の証跡をJSON1行で書き込む
    ///
    /// 時刻差から総所要時間を算出し通番と要求名と段階集計を1行にする
    ///
    /// Zenzai記録がある場合だけ追加し、最後に改行 (0x0A) を付ける
    ///
    /// - Parameter measurement: begin(type:)が返した計測値
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

    /// 環境変数が指定するときだけ計測器を作る
    ///
    /// [HAZKEY_PERF_EVIDENCE]が未設定や空文字の場合はnilを返す
    ///
    /// - Returns: 有効な場合の計測器、無効な場合はnil
    private static func makeIfEnabled() -> PerfProbe? {
        guard let path = ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"], !path.isEmpty else {
            return nil
        }
        return PerfProbe(path: path)
    }

    /// ナノ秒差をミリ秒に変換する
    ///
    /// - Parameters:
    ///   - from: 開始時刻(ナノ秒)
    ///   - to: 終了時刻(ナノ秒)
    /// - Returns: ミリ秒単位の差
    private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}

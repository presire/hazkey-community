import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// リッチ評価でロジット行を使い回す (A7) 場合と使い回さない場合で、全応答が同じことを確かめる
///
/// [HAZKEY_RICH_LOGITS_REUSE_PARITY]が[1]のときだけ実行されるオプトインのテスト
///
/// - Note: 実モデルは[HAZKEY_ZENZAI_MODEL]で受け取る
/// - Note: 使い回しの無効化はコンバータの[HAZKEY_ZENZAI_RICH_LOGITS_REUSE]=[0]で行う
/// - Note: CPUで推論する (Vulkanでは、同じプロセス内の1回目と2回目で使い回しの有無に関わらず応答がずれることがあるため、プロセスを分けて確かめる)
/// - Note: 使い回しが実際に起きたこと (使い回したトークン数 > 0) も確かめる
final class ZenzaiRichLogitsReuseParityTests: XCTestCase {
    /// 難読語を含む文 (ローマ字)
    private static let sentences = [
        "keikakuhazusannnakanrideshita",
        "ryoushanoninshikinisogogaatta",
        "joushinisontakusurunohayameyou",
        "hiikinochiimuwoouennsuru",
    ]

    /// 一連の操作で得た全応答のバイト列と、使い回したトークン数
    private struct RunResult {
        var responses: [Data] = []
        var labels: [String] = []
        var reusedTokens = 0
    }

    /// リッチな候補だけON (設定A) とリッチな提案もON (設定B) の両方で、使い回しの有無による応答の差が無いことを確かめる
    ///
    /// - Note: [HAZKEY_RICH_LOGITS_REUSE_PARITY]が[1]でない場合は、スキップする
    func testOptInRichLogitsReuseKeepsEveryResponseIdentical() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HAZKEY_RICH_LOGITS_REUSE_PARITY"] == "1",
            "Set HAZKEY_RICH_LOGITS_REUSE_PARITY=1 to run the real-model parity test.")
        let modelPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"])
        let modelURL = URL(fileURLWithPath: modelPath)
        for richSuggestion in [false, true] {
            let reused = try run(modelURL: modelURL, richSuggestion: richSuggestion, reuse: true)
            let fresh = try run(modelURL: modelURL, richSuggestion: richSuggestion, reuse: false)
            XCTAssertEqual(reused.responses.count, fresh.responses.count, "richSuggestion=\(richSuggestion)")
            for (index, (lhs, rhs)) in zip(reused.responses, fresh.responses).enumerated() where lhs != rhs {
                XCTFail("richSuggestion=\(richSuggestion): response #\(index) (\(reused.labels[index])) differs")
            }
            XCTAssertEqual(fresh.reusedTokens, 0, "reuse must stay off when disabled")
            XCTAssertGreaterThan(
                reused.reusedTokens, 0, "richSuggestion=\(richSuggestion): logits rows must actually be reused")
        }
    }

    /// 一時XDGルートの新しい接続状態で一連の操作を行い、全応答を集める
    private func run(modelURL: URL, richSuggestion: Bool, reuse: Bool) throws -> RunResult {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment: [String: String] = [:]
        for (variable, directory) in [
            "XDG_DATA_HOME": "data", "XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime", "XDG_STATE_HOME": "state",
        ] {
            let path = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            environment[variable] = path.path
        }
        environment["HAZKEY_DICTIONARY"] = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary").path
        environment["HAZKEY_ZENZAI_DEADLINE_MS"] = "0"
        environment["HAZKEY_ZENZAI_RICH_LOGITS_REUSE"] = reuse ? "1" : "0"
        let original = ProcessInfo.processInfo.environment
        defer {
            for variable in environment.keys {
                if let value = original[variable] { setenv(variable, value, 1) } else { unsetenv(variable) }
            }
        }
        for (variable, value) in environment { XCTAssertEqual(setenv(variable, value, 1), 0) }

        let state = HazkeyServerState()
        defer { state.close() }
        state.serverConfig.currentProfile.zenzaiEnable = true
        state.serverConfig.currentProfile.zenzaiBackendDeviceName = "CPU"
        state.serverConfig.currentProfile.useInputHistory = true
        state.serverConfig.currentProfile.useUserDictionary = false
        state.serverConfig.currentProfile.useRichCandidates = true
        state.serverConfig.currentProfile.useRichSuggestion = richSuggestion
        state.serverConfig.currentProfile.zenzaiRightContext = true
        state.serverConfig.currentProfile.zenzaiAlignmentSeparator = true
        state.serverConfig.currentProfile.useTypoCorrection = false
        state.serverConfig.currentProfile.specialConversionMode = .init()
        state.serverConfig.currentProfile.useZenzaiCustomWeight = true
        state.serverConfig.currentProfile.zenzaiWeightPath = modelURL.path
        state.serverConfig.reloadZenzaiModel()
        XCTAssertTrue(state.serverConfig.zenzaiAvailable, "zenzai must be available")
        state.baseConvertRequestOptions = state.serverConfig.genBaseConvertRequestOptions()
        state.shared.syncConverterLearningConfig()

        let reusedTokensBefore = ZenzInferencePerf.shared.richLogitsReusedTokenCount()
        var result = RunResult()
        func send(_ label: String, _ build: (inout Hazkey_RequestEnvelope) -> Void) throws -> Hazkey_ResponseEnvelope {
            var request = Hazkey_RequestEnvelope()
            build(&request)
            let data = ProtocolHandler(state: state).processProto(data: try request.serializedData())
            result.responses.append(data)
            result.labels.append(label)
            let response = try Hazkey_ResponseEnvelope(serializedBytes: data)
            XCTAssertEqual(response.status, .success, label)
            return response
        }
        for round in 0..<2 {
            for sentence in Self.sentences {
                let tag = "r\(round) \(sentence)"
                _ = try send("\(tag) new") { $0.newComposingText = .init() }
                _ = try send("\(tag) context") {
                    $0.setContext = .with { $0.context = "今日の日記。と思う。"; $0.anchor = 6 }
                }
                for character in sentence {
                    _ = try send("\(tag) input \(character)") { $0.inputChar = .with { $0.text = String(character) } }
                    _ = try send("\(tag) hiragana") { $0.getHiraganaWithCursor = .init() }
                    _ = try send("\(tag) suggest") { $0.getCandidates = .with { $0.isSuggest = true } }
                }
                _ = try send("\(tag) convert") { $0.getCandidates = .with { $0.isSuggest = false } }
                _ = try send("\(tag) cursor -3") { $0.moveCursor = .with { $0.offset = -3 } }
                _ = try send("\(tag) convert mid") { $0.getCandidates = .with { $0.isSuggest = false } }
                _ = try send("\(tag) cursor +3") { $0.moveCursor = .with { $0.offset = 3 } }
                _ = try send("\(tag) convert end") { $0.getCandidates = .with { $0.isSuggest = false } }
                _ = try send("\(tag) adjust -1") { $0.adjustClauseBoundary = .with { $0.offset = -1 } }
                _ = try send("\(tag) adjust +2") { $0.adjustClauseBoundary = .with { $0.offset = 2 } }
                // 先頭候補で確定し終えるまで繰り返す (候補が無くなったら止める)
                for step in 0..<8 {
                    let hiragana = try send("\(tag) commit \(step) hiragana") { $0.getHiraganaWithCursor = .init() }
                    let remaining = hiragana.textWithCursor
                    if (remaining.beforeCursosr + remaining.onCursor + remaining.afterCursor).isEmpty { break }
                    let candidates = try send("\(tag) commit \(step) candidates") {
                        $0.getCandidates = .with { $0.isSuggest = false }
                    }
                    if candidates.candidates.candidates.isEmpty { break }
                    _ = try send("\(tag) commit \(step) complete") { $0.prefixComplete = .with { $0.index = 0 } }
                }
                _ = try send("\(tag) delete new") { $0.newComposingText = .init() }
                for character in sentence.prefix(6) {
                    _ = try send("\(tag) delete input \(character)") {
                        $0.inputChar = .with { $0.text = String(character) }
                    }
                }
                _ = try send("\(tag) delete candidates") { $0.getCandidates = .with { $0.isSuggest = false } }
                _ = try send("\(tag) delete learning") { $0.deleteCandidateLearningData = .with { $0.index = 0 } }
            }
        }
        result.reusedTokens = ZenzInferencePerf.shared.richLogitsReusedTokenCount() - reusedTokensBefore
        return result
    }
}

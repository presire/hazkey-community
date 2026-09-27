import Foundation
import SwiftProtobuf

/// 要求を対応する処理へ振り分ける薄いディスパッチャ
///
/// 接続単位のHazkeyServerStateを持ち、自身は要求ごとの状態を持たない
///
/// 要求1件ごとに生成して使い捨てる
class ProtocolHandler {
    /// 振り分け先の接続単位のサーバ状態
    ///
    /// 変換と設定の実処理はここに委譲する
    private let state: HazkeyServerState

    /// 処理対象のサーバ状態を保持する
    ///
    /// - Parameter state: この接続のサーバ状態
    init(state: HazkeyServerState) {
        self.state = state
    }

    /// 要求バイト列を解析して対応する処理を呼び出す
    ///
    /// [set_config]や[get_config]や[delete_learning_entries]を含む全要求を扱う
    ///
    /// 解析に失敗した場合は失敗応答を返す
    ///
    /// 応答には[config_revision]を付けて返す
    ///
    /// - Parameter data: 要求エンベロープのバイト列
    /// - Returns: 応答エンベロープのバイト列、応答の生成に失敗した場合は空である
    /// - Note: 計測はPerfProbeを通して行う
    /// - Warning: ペイロード未設定の要求は失敗応答になる
    func processProto(data: Data) -> Data {
        let query: Hazkey_RequestEnvelope
        let response: Hazkey_ResponseEnvelope

        do {
            query = try Hazkey_RequestEnvelope(serializedBytes: data)
        } catch {
            NSLog("Failed to parse protobuf: \(error)")
            response = Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Failed to parse protobuf: \(error)"
            }
            return serializeResult(unserialized: response)
        }

        let measurement = PerfProbe.shared?.begin(type: PerfProbe.payloadType(query.payload))
        defer {
            if let measurement {
                PerfProbe.shared?.finish(measurement)
            }
        }

        switch query.payload {
        case .setContext(let req):
            response = state.setContext(
                surroundingText: req.context, anchorIndex: Int(req.anchor))
        case .newComposingText:
            response = state.createComposingTextInstanse()
        case .inputChar(let req):
            response = state.inputChar(inputString: req.text)
        case .modifierEvent(let req):
            response = state.processModifierEvent(modifier: req.modType, event: req.eventType)
        case .deleteLeft:
            response = state.deleteLeft()
        case .deleteRight:
            response = state.deleteRight()
        case .prefixComplete(let req):
            response = state.completePrefix(candidateIndex: Int(req.index))
        case .acceptPrediction(let req):
            response = state.acceptPrediction(candidateIndex: Int(req.index))
        case .moveCursor(let req):
            response = state.moveCursor(offset: Int(req.offset))
        case .adjustClauseBoundary(let req):
            response = state.adjustClauseBoundary(offset: Int(req.offset))
        case .getHiraganaWithCursor:
            response = state.getHiraganaWithCursor()
        case .getComposingString(let req):
            response = state.getComposingString(
                charType: req.charType, currentPreedit: req.currentPreedit)
        case .getCandidates(let req):
            response = state.getCandidates(is_suggest: req.isSuggest)
        case .getCurrentInputMode:
            response = state.getCurrentInputMode()
        case .saveLearningData:
            response = state.saveLearningData()
        case .getConfig:
            response = state.serverConfig.getCurrentConfig()
        case .setConfig(let req):
            response = state.serverConfig.setCurrentConfig(
                req.fileHashes, req.profiles, state: state)
        case .clearAllHistory_p:
            response = state.clearProfileLearningData()
        case .reloadZenzaiModel:
            response = state.reloadZenzaiModel()
        case .getDefaultProfile:
            response = HazkeyServerConfig.getDefaultProfile()
        case .getLearningHistory(let req):
            do {
                let result = try state.listLearningEntries(
                    query: req.query, offset: req.offset, limit: req.limit)
                response = Hazkey_ResponseEnvelope.with {
                    $0.status = .success
                    $0.getLearningHistoryResult.entries = result.entries
                    $0.getLearningHistoryResult.totalCount = UInt32(result.totalCount)
                }
            } catch {
                response = Hazkey_ResponseEnvelope.with {
                    $0.status = .failed
                    $0.errorMessage = "Failed to list learning history: \(error)"
                }
            }
        case .deleteLearningEntries(let req):
            do {
                // エントリは(reading, word)をキーにまとめた行であり、各表記の全CID変種を削除する
                let deletedCount = try state.forgetLearningSurfaces(
                    req.entries.map { ($0.reading, $0.word) })
                response = Hazkey_ResponseEnvelope.with {
                    $0.status = .success
                    $0.deleteLearningEntriesResult.deletedCount = deletedCount
                }
            } catch {
                response = Hazkey_ResponseEnvelope.with {
                    $0.status = .failed
                    $0.errorMessage = "Failed to forget learning history: \(error)"
                }
            }
        case .deleteCandidateLearningData(let req):
            response = state.deleteCandidateLearningData(candidateIndex: Int(req.index))
        case .toggleZenzai:
            response = state.serverConfig.toggleZenzai()
        case .none:
            NSLog("Payload not specified")
            response = Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Payload not specified"
            }
        }
        return serializeResult(unserialized: response)
    }

    /// 応答に[config_revision]を付けてバイト列に変換する
    ///
    /// 版数は接続のserverConfigから取得する
    ///
    /// 変換に失敗した場合は空のバイト列を返す
    ///
    /// - Parameter unserialized: 変換前の応答エンベロープ
    /// - Returns: 応答エンベロープのバイト列、失敗時は空である
    private func serializeResult(unserialized: Hazkey_ResponseEnvelope) -> Data {
        var response = unserialized
        response.configRevision = state.serverConfig.configRevision
        do {
            let serialized = try response.serializedData()
            return serialized
        } catch {
            NSLog("Failed to serialize response message: \(unserialized)")
            return Data()
        }
    }
}

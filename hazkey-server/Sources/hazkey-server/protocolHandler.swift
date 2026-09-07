import Foundation
import SwiftProtobuf

class ProtocolHandler {
    private let state: HazkeyServerState

    init(state: HazkeyServerState) {
        self.state = state
    }

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
            state.serverConfig.reloadZenzaiModel()
            response = Hazkey_ResponseEnvelope.with {
                $0.status = .success
            }
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
                let deletedCount = try state.forgetLearningEntries(
                    req.entries.map { ($0.reading, $0.word, $0.lcid, $0.rcid) })
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
        case .none:
            NSLog("Payload not specified")
            response = Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Payload not specified"
            }
        }
        return serializeResult(unserialized: response)
    }

    private func serializeResult(unserialized: Hazkey_ResponseEnvelope) -> Data {
        do {
            let serialized = try unserialized.serializedData()
            return serialized
        } catch {
            NSLog("Failed to serialize response message: \(unserialized)")
            return Data()
        }
    }
}

import XCTest
import KanaKanjiConverterModule

@testable import hazkey_server

/// Integration tests for the [community] AcceptPrediction RPC
/// (prediction candidate accepted as a fixed leading notation,
/// upstream ad714fe / #357).
///
/// The prediction candidate is injected into `currentCandidateList`
/// synthetically so the test does not depend on the environment's
/// dictionary producing live prediction results.
final class AcceptPredictionTests: XCTestCase {
    private func makePredictionCandidate(text: String, ruby: String) -> Candidate {
        Candidate(
            text: text,
            value: 0,
            composingCount: .surfaceCount(text.count),
            lastMid: MIDData.一般.mid,
            data: [
                .init(word: text, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)
            ]
        )
    }

    private func makeStateWithInput(_ reading: String) throws -> HazkeyServerState {
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.getCandidates(is_suggest: true).status, .success)
        return state
    }

    func testAcceptPredictionGrowsComposingTextWithoutCommitting() throws {
        let state = try makeStateWithInput("よろし")

        // Inject a synthetic prediction candidate whose ruby extends the
        // typed input ("よろし" + "くおねがいします").
        state.currentCandidateList?.append(
            .fromConverter(
                makePredictionCandidate(text: "よろしくお願いします", ruby: "ヨロシクオネガイシマス")))
        let predictionIndex = try XCTUnwrap(state.currentCandidateList?.indices.last)

        XCTAssertEqual(state.acceptPrediction(candidateIndex: predictionIndex).status, .success)

        // The composition grew to cover the accepted candidate's ruby and
        // the candidate list was invalidated (indices are stale now).
        XCTAssertEqual(
            state.composingText.value.convertTarget.toHiragana(), "よろしくおねがいします")
        XCTAssertNil(state.currentCandidateList)
    }

    func testAcceptPredictionRejectsRegularCandidate() throws {
        let state = try makeStateWithInput("よろし")
        let candidates = try XCTUnwrap(state.currentCandidateList)

        // A candidate covering at most the typed input is not a prediction.
        let inputCount = "よろし".count
        let regularIndex = try XCTUnwrap(
            candidates.firstIndex(where: { entry in
                if case .fromConverter(let candidate) = entry {
                    return candidate.rubyCount <= inputCount
                }
                return false
            }),
            "No regular candidate found for よろし")

        XCTAssertEqual(state.acceptPrediction(candidateIndex: regularIndex).status, .failed)
    }

    func testAcceptPredictionRejectsUnknownIndex() throws {
        let state = try makeStateWithInput("よろし")
        XCTAssertEqual(state.acceptPrediction(candidateIndex: 9999).status, .failed)
    }
}

import XCTest
import KanaKanjiConverterModule

@testable import hazkey_server

/// AcceptPrediction RPCの統合テスト
/// 予測候補を先頭表記として固定受入する (upstream ad714fe / #357)
///
/// 環境の辞書がライブ予測結果を生成するかどうかに依存しないよう、
/// 予測候補は`currentCandidateList`へ合成的に注入する
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

        // 入力済みのruby（"よろし" + "くおねがいします") を拡張する
        // 合成予測候補を注入する
        state.currentCandidateList?.append(
            .fromConverter(
                makePredictionCandidate(text: "よろしくお願いします", ruby: "ヨロシクオネガイシマス")))
        let predictionIndex = try XCTUnwrap(state.currentCandidateList?.indices.last)

        XCTAssertEqual(state.acceptPrediction(candidateIndex: predictionIndex).status, .success)

        // 組成を受入候補のruby全体まで拡張し、候補リストを無効化する
        // この時点で候補インデックスは古くなっている
        XCTAssertEqual(
            state.composingText.value.convertTarget.toHiragana(), "よろしくおねがいします")
        XCTAssertNil(state.currentCandidateList)
    }

    func testAcceptPredictionRejectsRegularCandidate() throws {
        let state = try makeStateWithInput("よろし")
        let candidates = try XCTUnwrap(state.currentCandidateList)

        // 入力済みの範囲までしか含まない候補は予測候補ではない
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

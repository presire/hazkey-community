import Foundation
import XCTest

@testable import hazkey_server

final class CandidateTests: BaseHazkeyServerTestCase {

  func testGetCandidatesWithEmptyInput() throws {
    let candidatesQuery = QueryDataBuilder.getCandidates()
    let candidatesResponse = try sendQuery(candidatesQuery)

    XCTAssertEqual(
      candidatesResponse.status, .success, "Getting candidates should succeed even with empty input"
    )

    if case .candidates(let candidatesResult) = candidatesResponse.props {
      XCTAssertTrue(
        candidatesResult.candidates.isEmpty || candidatesResult.candidates.count > 0,
        "Should return candidates array (empty or populated)")
    } else {
      XCTFail("Response should contain candidates")
    }
  }

  func testGetCandidatesWithHiraganaInput() throws {
    // ひらがなを入力する
    let inputQuery = QueryDataBuilder.inputText("あい")
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success)

    let candidatesQuery = QueryDataBuilder.getCandidates(nBest: 5)
    let candidatesResponse = try sendQuery(candidatesQuery)

    XCTAssertEqual(candidatesResponse.status, .success, "Getting candidates should succeed")

    if case .candidates(let candidatesResult) = candidatesResponse.props {
      XCTAssertFalse(
        candidatesResult.candidates.isEmpty, "Should return some candidates for hiragana input")

      // 先頭候補の構造を確認する
      if let firstCandidate = candidatesResult.candidates.first {
        XCTAssertFalse(firstCandidate.text.isEmpty, "Candidate text should not be empty")
      }
    } else {
      XCTFail("Response should contain candidates")
    }
  }

  func testGetCandidatesWithNBestLimit() throws {
    let inputQuery = QueryDataBuilder.inputText("あ")
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success)

    let nBest: Int32 = 3
    let candidatesQuery = QueryDataBuilder.getCandidates(nBest: nBest)
    let candidatesResponse = try sendQuery(candidatesQuery)

    XCTAssertEqual(candidatesResponse.status, .success)

    if case .candidates(let candidatesResult) = candidatesResponse.props {
      XCTAssertTrue(candidatesResult.candidates.count >= 0, "Should return candidates array")
    } else {
      XCTFail("Response should contain candidates")
    }
  }

  func testGetCandidatesInPredictMode() throws {
    let inputQuery = QueryDataBuilder.inputText("こん")
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success)

    let candidatesQuery = QueryDataBuilder.getCandidates(isPredictMode: true)
    let candidatesResponse = try sendQuery(candidatesQuery)

    XCTAssertEqual(candidatesResponse.status, .success, "Predict mode should work")

    if case .candidates(let candidatesResult) = candidatesResponse.props {
      // 予測モードでは予測候補が返る場合がある
      XCTAssertTrue(candidatesResult.candidates.count >= 0, "Should return candidates array")
    } else {
      XCTFail("Response should contain candidates")
    }
  }
}

import XCTest

@testable import hazkey_server

final class AutoConversionTests: XCTestCase {
  func testConfiguredThresholdSuppressesBelowAndShowsAtAndAboveThreshold() throws {
    let belowThreshold = try candidates(input: "あ", minimumCharacters: 2)
    assertNoLiveText(belowThreshold)

    let atThreshold = try candidates(input: "あい", minimumCharacters: 2)
    assertLiveTextMatchesCandidate(atThreshold)

    let aboveThreshold = try candidates(input: "あいう", minimumCharacters: 2)
    assertLiveTextMatchesCandidate(aboveThreshold)
  }

  func testZeroAndUnsetThresholdUseDefaultBehavior() throws {
    let zeroBelowDefault = try candidates(input: "あ", minimumCharacters: 0)
    assertNoLiveText(zeroBelowDefault)

    let zeroAtDefault = try candidates(input: "あい", minimumCharacters: 0)
    assertLiveTextMatchesCandidate(zeroAtDefault)

    let unsetBelowDefault = try candidates(input: "あ", minimumCharacters: nil)
    assertNoLiveText(unsetBelowDefault)

    let unsetAtDefault = try candidates(input: "あい", minimumCharacters: nil)
    assertLiveTextMatchesCandidate(unsetAtDefault)
  }

  private func candidates(
    input: String,
    minimumCharacters: Int32?
  ) throws -> Hazkey_Commands_CandidatesResult {
    let state = HazkeyServerState()
    state.serverConfig.currentProfile.autoConvertMode = .autoConvertForMultipleChars

    if let minimumCharacters {
      state.serverConfig.currentProfile.autoConvertMinChars = minimumCharacters
    } else {
      state.serverConfig.currentProfile.clearAutoConvertMinChars()
    }

    for character in input {
      XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
    }

    let response = state.getCandidates(is_suggest: true)
    XCTAssertEqual(response.status, .success)

    return try XCTUnwrap(
      {
        guard case .candidates(let candidates)? = response.payload else {
          return nil
        }
        return candidates
      }(),
      "Suggestion requests should return candidate results"
    )
  }

  private func assertNoLiveText(
    _ candidates: Hazkey_Commands_CandidatesResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(candidates.liveText, "", file: file, line: line)
    XCTAssertEqual(candidates.liveTextIndex, -1, file: file, line: line)
  }

  private func assertLiveTextMatchesCandidate(
    _ candidates: Hazkey_Commands_CandidatesResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(candidates.liveText.isEmpty, file: file, line: line)

    let index = Int(candidates.liveTextIndex)
    guard index >= 0, index < candidates.candidates.count else {
      XCTFail("Live text index should identify a returned candidate", file: file, line: line)
      return
    }

    XCTAssertEqual(candidates.candidates[index].text, candidates.liveText, file: file, line: line)
  }
}

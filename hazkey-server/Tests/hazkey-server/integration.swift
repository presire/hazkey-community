import Foundation
import XCTest

@testable import hazkey_server

final class IntegrationTests: BaseHazkeyServerTestCase {

  func testCompleteInputWorkflow() throws {
    // 1. カスタム設定を適用する
    let configQuery = QueryDataBuilder.setConfig(
      numberFullwidth: 1,
      symbolFullwidth: 1
    )
    let configResponse = try sendQuery(configQuery)
    XCTAssertEqual(configResponse.status, .success)

    // 2. 組成テキストのインスタンスを作成する
    let instanceQuery = QueryDataBuilder.createComposingTextInstance()
    let instanceResponse = try sendQuery(instanceQuery)
    XCTAssertEqual(instanceResponse.status, .success)

    // 3. 複数文字を入力する
    let inputChars = ["こ", "ん", "に", "ち", "は"]
    for char in inputChars {
      let inputQuery = QueryDataBuilder.inputText(char)
      let inputResponse = try sendQuery(inputQuery)
      XCTAssertEqual(inputResponse.status, .success, "Input of '\(char)' should succeed")
    }

    // 4. 組成文字列を取得する
    let getStringQuery = QueryDataBuilder.getComposingString(charType: .hiragana)
    let stringResponse = try sendQuery(getStringQuery)
    XCTAssertEqual(stringResponse.status, .success)
    XCTAssertEqual(stringResponse.result, "こんにちは", "Should compose complete hiragana string")

    // 5. 候補を取得する
    let candidatesQuery = QueryDataBuilder.getCandidates()
    let candidatesResponse = try sendQuery(candidatesQuery)
    XCTAssertEqual(candidatesResponse.status, .success)

    if case .candidates(let candidatesResult) = candidatesResponse.props {
      XCTAssertFalse(candidatesResult.candidates.isEmpty, "Should return candidates for 'こんにちは'")

      // "こんにちは"または"今日は"が候補に含まれることを確認する
      let candidateTexts = candidatesResult.candidates.map { $0.text }
      XCTAssertTrue(
        candidateTexts.contains("こんにちは") || candidateTexts.contains("今日は"),
        "Should contain greeting candidates")
    } else {
      XCTFail("Should receive candidates")
    }
  }

  func testNumberAndSymbolConversion() throws {
    // 全角変換を設定する
    let configQuery = QueryDataBuilder.setConfig(
      numberFullwidth: 1,
      symbolFullwidth: 1
    )
    let configResponse = try sendQuery(configQuery)
    XCTAssertEqual(configResponse.status, .success)

    let instanceQuery = QueryDataBuilder.createComposingTextInstance()
    let instanceResponse = try sendQuery(instanceQuery)
    XCTAssertEqual(instanceResponse.status, .success)

    // 数字変換を検証する
    let numberInputQuery = QueryDataBuilder.inputText("5")
    let numberResponse = try sendQuery(numberInputQuery)
    XCTAssertEqual(numberResponse.status, .success)

    let getNumberQuery = QueryDataBuilder.getComposingString()
    let numberStringResponse = try sendQuery(getNumberQuery)
    XCTAssertEqual(numberStringResponse.status, .success)
    XCTAssertEqual(numberStringResponse.result, "５", "Number should be converted to fullwidth")
  }

  func testMultipleSessionsSequentially() throws {
    // セッション1
    let session1InstanceQuery = QueryDataBuilder.createComposingTextInstance()
    let session1Response = try sendQuery(session1InstanceQuery)
    XCTAssertEqual(session1Response.status, .success)

    let session1InputQuery = QueryDataBuilder.inputText("あ")
    let session1InputResponse = try sendQuery(session1InputQuery)
    XCTAssertEqual(session1InputResponse.status, .success)

    // セッション2 (新しいインスタンス)
    let session2InstanceQuery = QueryDataBuilder.createComposingTextInstance()
    let session2Response = try sendQuery(session2InstanceQuery)
    XCTAssertEqual(session2Response.status, .success)

    // セッション2は初期状態であるべき
    let session2GetQuery = QueryDataBuilder.getComposingString()
    let session2StringResponse = try sendQuery(session2GetQuery)
    XCTAssertEqual(session2StringResponse.status, .success)
    XCTAssertEqual(session2StringResponse.result, "", "New session should start with empty state")
  }
}

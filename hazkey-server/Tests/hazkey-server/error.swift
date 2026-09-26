import Foundation
import XCTest

@testable import hazkey_server

final class ErrorHandlingTests: BaseHazkeyServerTestCase {

  func testInvalidCharacterTypeInGetComposingString() throws {
    // まずテキストを入力する
    let inputQuery = QueryDataBuilder.inputText("あ")
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success)

    // 不正な文字種別で組成文字列の取得を試みる
    var query = Hazkey_Commands_QueryData()
    query.function = .getComposingString
    query.getComposingString = Hazkey_Commands_QueryData.GetComposingStringProps.with {
      $0.charType = .UNRECOGNIZED(999)  // 不正な文字種別
    }

    let response = try sendQuery(query)
    XCTAssertEqual(response.status, .failed, "Invalid character type should result in failure")
    XCTAssertFalse(
      response.errorMessage.isEmpty, "Should provide error message for invalid character type")
  }

  func testMultipleComposingTextInstanceCreation() throws {
    // 1つ目のインスタンスを作成する
    let firstInstanceQuery = QueryDataBuilder.createComposingTextInstance()
    let firstResponse = try sendQuery(firstInstanceQuery)
    XCTAssertEqual(firstResponse.status, .success)

    // テキストを入力する
    let inputQuery = QueryDataBuilder.inputText("test")
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success)

    // 2つ目のインスタンスを作成する（1つ目はリセットされる）
    let secondInstanceQuery = QueryDataBuilder.createComposingTextInstance()
    let secondResponse = try sendQuery(secondInstanceQuery)
    XCTAssertEqual(secondResponse.status, .success)

    // 組成文字列がリセットされたことを確認する
    let getStringQuery = QueryDataBuilder.getComposingString()
    let stringResponse = try sendQuery(getStringQuery)
    XCTAssertEqual(stringResponse.status, .success)
    XCTAssertEqual(stringResponse.result, "", "New instance should have empty composing text")
  }

  func testLargeInputString() throws {
    // 非常に長い文字列で検証する
    let largeString = String(repeating: "あ", count: 1000)

    // 注: サーバは先頭のUnicode文字だけを処理する
    let inputQuery = QueryDataBuilder.inputText(largeString)
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success, "Large input should succeed")

    let getStringQuery = QueryDataBuilder.getComposingString()
    let stringResponse = try sendQuery(getStringQuery)
    XCTAssertEqual(stringResponse.status, .success)
    XCTAssertEqual(stringResponse.result, "あ", "Should only process first character")
  }
}

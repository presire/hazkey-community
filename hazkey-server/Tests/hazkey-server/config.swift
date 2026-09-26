import Foundation
import XCTest

@testable import hazkey_server

final class ConfigurationTests: BaseHazkeyServerTestCase {
  func testSetCustomConfiguration() throws {
    let query = QueryDataBuilder.setConfig(
      commaStyle: 1,
      numberFullwidth: 1,
      periodStyle: 2,
      spaceFullwidth: 1,
      symbolFullwidth: 1,
      tenCombining: 1,
      zenzaiEnabled: true,
      zenzaiInferLimit: 5
    )

    let response = try sendQuery(query)

    XCTAssertEqual(
      response.status, .success,
      "Setting custom configuration should succeed")
    XCTAssertTrue(
      response.errorMessage.isEmpty,
      "Error message should be empty on success")
  }

  func testConfigurationPersistence() throws {
    // カスタム設定を適用する
    let customConfig = QueryDataBuilder.setConfig(
      numberFullwidth: 1,
      symbolFullwidth: 1
    )
    let configResponse = try sendQuery(customConfig)
    XCTAssertEqual(configResponse.status, .success)

    // 永続化を確認するため、新しい組成テキストのインスタンスを作成する
    let instanceQuery = QueryDataBuilder.createComposingTextInstance()
    let instanceResponse = try sendQuery(instanceQuery)
    XCTAssertEqual(instanceResponse.status, .success)

    // 数字を入力し、全角に変換されることを確認する
    let inputQuery = QueryDataBuilder.inputText("1")
    let inputResponse = try sendQuery(inputQuery)
    XCTAssertEqual(inputResponse.status, .success)

    let getStringQuery = QueryDataBuilder.getComposingString()
    let stringResponse = try sendQuery(getStringQuery)
    XCTAssertEqual(stringResponse.status, .success)

    // 全角数字が有効な場合、"1"は"１"になる
    XCTAssertEqual(
      stringResponse.result, "１",
      "Number should be converted to fullwidth when numberFullwidth is enabled")
  }
}

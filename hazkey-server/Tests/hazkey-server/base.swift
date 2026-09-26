import Foundation
import XCTest

@testable import hazkey_server

class BaseHazkeyServerTestCase: XCTestCase {
  var client: HazkeyServerClient!

  override func setUpWithError() throws {
    try super.setUpWithError()

    // サーバが起動していることを確認する
    XCTAssertTrue(
      TestUtilities.waitForServer(),
      "Server socket did not appear within timeout. Make sure the hazkey-server is running."
    )

    // クライアントを作成して接続する
    client = HazkeyServerClient()
    try client.connect()

    // サーバ状態を初期化する
    try initializeServerState()
  }

  override func tearDownWithError() throws {
    client?.disconnect()
    client = nil
    try super.tearDownWithError()
  }

  private func initializeServerState() throws {
    // 既定の設定を適用する
    let configQuery = QueryDataBuilder.setConfig()
    let configResponse = try client.sendQuery(configQuery)
    XCTAssertEqual(configResponse.status, .success, "Failed to set initial configuration")

    // 組成テキストのインスタンスを作成する
    let instanceQuery = QueryDataBuilder.createComposingTextInstance()
    let instanceResponse = try client.sendQuery(instanceQuery)
    XCTAssertEqual(instanceResponse.status, .success, "Failed to create composing text instance")
  }

  // エラー報告を改善してクエリを送信するヘルパーメソッド
  func sendQuery(
    _ query: Hazkey_Commands_QueryData,
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> Hazkey_Commands_ResultData {
    do {
      return try client.sendQuery(query)
    } catch {
      XCTFail("Failed to send query: \(error)", file: file, line: line)
      throw error
    }
  }
}

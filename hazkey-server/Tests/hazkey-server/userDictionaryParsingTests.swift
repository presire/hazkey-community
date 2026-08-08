import Foundation
import XCTest

@testable import hazkey_server

final class UserDictionaryParsingTests: XCTestCase {
  func testParseLineReadsPersonPosWithComment() {
    let entry = UserDictionary.parseLine("たろう\t太郎\t私の名前\tperson")

    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.reading, "たろう")
    XCTAssertEqual(entry?.word, "太郎")
    XCTAssertEqual(entry?.comment, "私の名前")
    XCTAssertEqual(entry?.pos, "person")
  }

  func testParseLineDefaultsToNounForThreeColumnLine() {
    let entry = UserDictionary.parseLine("はし\t橋")

    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.pos, "noun")
  }

  func testNounMapsToProperNounCid() {
    let element = UserDictionary.parseLine("はし\t橋")?.toDicdataElement()

    XCTAssertNotNil(element)
    XCTAssertEqual(element?.lcid, 1288)
    XCTAssertEqual(element?.rcid, 1288)
    XCTAssertEqual(element?.mid, 501)
    XCTAssertEqual(element?.ruby, "ハシ")
  }

  func testVerbMapsToRawCidWithEmptyCommentPreserved() {
    let entry = UserDictionary.parseLine("おきる\t起きる\t\tverb")

    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.comment, "")
    let element = entry?.toDicdataElement()
    XCTAssertEqual(element?.lcid, 772)
    XCTAssertEqual(element?.rcid, 772)
  }

  func testPlaceMapsToPlaceCid() {
    let element = UserDictionary.parseLine("なまえ\t名前\t\tplace")?.toDicdataElement()

    XCTAssertNotNil(element)
    XCTAssertEqual(element?.lcid, 1293)
    XCTAssertEqual(element?.rcid, 1293)
  }

  func testPosTokenIsCaseInsensitive() {
    let entry = UserDictionary.parseLine("なまえ\t名前\t\tPERSON")

    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.pos, "person")
    let element = entry?.toDicdataElement()
    XCTAssertEqual(element?.lcid, 1289)
    XCTAssertEqual(element?.rcid, 1289)
  }

  func testUnknownPosTokenFallsBackToNoun() {
    let entry = UserDictionary.parseLine("x\ty\t\txyz")

    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.pos, "noun")
    let element = entry?.toDicdataElement()
    XCTAssertEqual(element?.lcid, 1288)
    XCTAssertEqual(element?.rcid, 1288)
  }

  func testParseLineReturnsNilForCommentLine() {
    XCTAssertNil(UserDictionary.parseLine("# comment"))
  }

  func testParseLineReturnsNilForEmptyLine() {
    XCTAssertNil(UserDictionary.parseLine(""))
  }

  func testParseLineReturnsNilForSingleColumnLine() {
    XCTAssertNil(UserDictionary.parseLine("onlyonecol"))
  }

  func testRubyIsConvertedToKatakana() {
    let element = UserDictionary.parseLine("ひらがな\t平仮名")?.toDicdataElement()

    XCTAssertEqual(element?.ruby, "ヒラガナ")
  }
}

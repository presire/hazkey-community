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

  func testVerbOkiruConjugatesAsIchidan() {
    let entry = UserDictionary.parseLine("おきる\t起きる\t\tverb")

    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.comment, "")
    // Base form uses detected 一段 CID (619), not old hardcoded 772
    let baseElement = entry?.toDicdataElement()
    XCTAssertEqual(baseElement?.lcid, 619)
    XCTAssertEqual(baseElement?.rcid, 619)
    // Expansion produces 9 forms (8 conjugated + 1 base)
    let forms = entry?.expandedDicdataElements()
    XCTAssertEqual(forms?.count, 9)
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

  func testVerbExpandedFormsForHashiru() {
    let entry = UserDictionary.parseLine("はしる\t走る\t\tverb")
    let forms = entry?.expandedDicdataElements()
    // はしる's prev kana し in イ段 -> misdetected as 一段 (619) -- known limitation
    // 一段 produces 8 conjugated forms + 1 base = 9
    XCTAssertEqual(forms?.count, 9)
    // Base form 走る should be present
    XCTAssertTrue(forms?.contains(where: { $0.word == "走る" }) ?? false)
  }

  func testNounExpandedProducesSingleElement() {
    let entry = UserDictionary.parseLine("はし\t橋")
    let forms = entry?.expandedDicdataElements()
    XCTAssertEqual(forms?.count, 1)
  }

  func testUserDictionaryToDicdataElementsFlatMaps() {
    // Construct entries directly (avoids depending on defaultPath() which reads
    // from XDG_CONFIG_HOME).
    let lines = [
      "はし\t橋",
      "はしる\t走る\t\tverb",
      "ねこ\t猫",
    ]
    let entries = lines.compactMap { UserDictionary.parseLine($0) }
    XCTAssertEqual(entries.count, 3)
    let elements = entries.flatMap { $0.expandedDicdataElements() }
    // noun(1) + verb(9, 一段 misclassification) + noun(1) = 11
    XCTAssertEqual(elements.count, 11)
  }
}

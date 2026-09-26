import XCTest

@testable import hazkey_server

final class KanaNumberProviderTests: XCTestCase {
    func testZeroReadingsRecognizesAllApprovedTriggers() {
        // 前提: 承認済みのゼロ起動読み
        // 実行: プロバイダの起動読み集合を調べる
        // 期待: 承認済みの別名だけがすべて含まれる
        XCTAssertEqual(KanaNumberProvider.zeroReadings, ["れい", "ぜろ", "ゼロ"])
    }

    func testDecimalOneProducesApprovedFamiliesInOrder() {
        XCTAssertEqual(
            KanaNumberProvider.generateCandidates(forDecimalDigits: "1"),
            ["₁", "¹", "①", "Ⅰ", "⑴", "⒈", "❶", "ⅰ"])
    }

    func testMultiDigitValueProducesSubscriptAndSuperscript() {
        XCTAssertEqual(
            KanaNumberProvider.generateCandidates(forDecimalDigits: "123"),
            ["₁₂₃", "¹²³"])
    }

    func testDecimalTenProducesAllBoundedFamilies() {
        // 前提: 承認済みのすべての文字種で表せる10進数の10
        // 実行: 候補を生成する
        // 期待: すべての文字種が規定の順序で現れる
        XCTAssertEqual(
            KanaNumberProvider.generateCandidates(forDecimalDigits: "10"),
            ["₁₀", "¹⁰", "⑩", "Ⅹ", "⑽", "⒑", "❿", "ⅹ"])
    }

    func testDecimalTwentyOneProducesOnlyDigitFamilies() {
        // 前提: すべての範囲限定の文字種の上限を超える10進数の21
        // 実行: 候補を生成する
        // 期待: 複数字の下付き文字と上付き文字だけが残る
        XCTAssertEqual(
            KanaNumberProvider.generateCandidates(forDecimalDigits: "21"),
            ["₂₁", "²¹"])
    }

    func testZeroProducesRepresentableFamilies() {
        XCTAssertEqual(
            KanaNumberProvider.generateCandidates(forDecimalDigits: "0"),
            ["₀", "⁰", "⓪"])
    }

    func testNonDecimalTextProducesNoCandidates() {
        XCTAssertEqual(KanaNumberProvider.generateCandidates(forDecimalDigits: "いち"), [])
    }
}

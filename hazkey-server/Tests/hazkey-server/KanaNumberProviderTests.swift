import XCTest

@testable import hazkey_server

final class KanaNumberProviderTests: XCTestCase {
    func testZeroReadingsRecognizesAllApprovedTriggers() {
        // Given: the approved zero-trigger readings
        // When: inspecting the provider's trigger set
        // Then: all and only the approved aliases are present
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
        // Given: decimal 10, representable in every approved family
        // When: generating candidates
        // Then: all families appear in the prescribed order
        XCTAssertEqual(
            KanaNumberProvider.generateCandidates(forDecimalDigits: "10"),
            ["₁₀", "¹⁰", "⑩", "Ⅹ", "⑽", "⒑", "❿", "ⅹ"])
    }

    func testDecimalTwentyOneProducesOnlyDigitFamilies() {
        // Given: decimal 21, beyond every bounded-family range
        // When: generating candidates
        // Then: only multi-digit subscript and superscript remain
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

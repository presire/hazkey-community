import XCTest

@testable import hazkey_server

final class KanaNumberIntegrationTests: XCTestCase {
    func testZeroAliasesProduceZeroFamily() throws {
        for reading in ["れい", "ぜろ", "ゼロ"] {
            let texts = try candidateTexts(forReading: reading)
            for expected in ["₀", "⁰", "⓪"] {
                XCTAssertEqual(texts.filter { $0 == expected }.count, 1)
            }
        }
    }

    func testTenProducesOrderedSpecialCandidates() throws {
        let texts = try candidateTexts(forReading: "じゅう")
        let expected = ["₁₀", "¹⁰", "⑩", "Ⅹ", "⑽", "⒑", "❿"]
        guard let anchorIndex = texts.firstIndex(of: "10") else {
            XCTFail("Expected ASCII decimal anchor")
            return
        }
        XCTAssertEqual(Array(texts[(anchorIndex + 1)..<(anchorIndex + 1 + expected.count)]), expected)
    }

    func testApprovedGlyphsAppearAtMostOnce() throws {
        // Given: a value whose candidate list also contains dictionary variants
        // When: converting the Japanese number reading
        // Then: no approved glyph is duplicated by the synthetic insertion
        let texts = try candidateTexts(forReading: "いち")
        for glyph in KanaNumberProvider.generateCandidates(forDecimalDigits: "1") {
            XCTAssertLessThanOrEqual(texts.filter { $0 == glyph }.count, 1)
        }
    }

    private func candidateTexts(forReading reading: String) throws -> [String] {
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return []
        }
        return result.candidates.map(\.text)
    }
}

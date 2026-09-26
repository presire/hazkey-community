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

    func testTenAnchorExistsAndEachApprovedGlyphAppearsExactlyOnce() throws {
        let texts = try candidateTexts(forReading: "じゅう")
        guard texts.contains("10") else {
            XCTFail("Expected ASCII decimal anchor")
            return
        }
        for glyph in KanaNumberProvider.generateCandidates(forDecimalDigits: "10") {
            XCTAssertEqual(texts.filter { $0 == glyph }.count, 1)
        }
    }

    func testApprovedGlyphsAppearAtMostOnce() throws {
        // 前提: 候補リストに辞書由来の候補も含まれる値
        // 実行: 日本語の数詞読みを変換する
        // 期待: 合成挿入によって承認済みの字形が重複しない
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

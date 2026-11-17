import XCTest

@testable import hazkey_server

/// 記号の判定 (SymbolCandidateClassifier.isSymbol(_:)) の判定表
final class SymbolCandidateClassifierTests: XCTestCase {
    /// 記号・句読点だけからなる表記は記号と判定する (VS15付きの↕︎と、テキスト表示が既定の裸の❤を含む)
    func testSymbolsAndPunctuationAreSymbols() {
        for text in ["→", "☆", "※", "〒", "℃", "「」", "…", "〜", "○", "\u{2195}\u{FE0E}", "\u{2764}", "÷", "【】"] {
            XCTAssertTrue(SymbolCandidateClassifier.isSymbol(text), text)
        }
    }

    /// 文字・数字・空白・絵文字表示・異体字セレクタVS16・ZWJを含む表記と空文字列は記号ではない
    func testLettersDigitsWhitespaceAndEmojiAreNotSymbols() {
        let texts = [
            "〇", "々", "ー", "○丸", "A１", "°C", "\u{3000}", "→ ", "\u{2795}", "\u{2764}\u{FE0F}",
            "\u{2764}\u{200D}\u{2192}", "", "\u{FE0E}", "\u{2192}\u{FE0E}\u{FE0E}",
        ]
        for text in texts {
            XCTAssertFalse(SymbolCandidateClassifier.isSymbol(text), text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
    }

    /// かなの判定は、ひらがな・カタカナ・半角カタカナだけからなる空でない表記に限る
    func testKanaOnly() {
        for text in ["した", "シタ", "ｼﾀ", "カード"] {
            XCTAssertTrue(SymbolCandidateClassifier.isKanaOnly(text), text)
        }
        for text in ["下", "ue", "した下", "", "↓"] {
            XCTAssertFalse(SymbolCandidateClassifier.isKanaOnly(text), text)
        }
    }
}

import XCTest

@testable import hazkey_server

/// The default profile enables the Fullwidth Symbol keymap so ASCII symbols
/// typed in romaji mode compose as full-width characters instead of passing
/// through half-width.
final class KeymapTests: XCTestCase {
    func testFullwidthSymbolMapCoversBracesAndQuotes() {
        // Given: the built-in full-width symbol table.

        // When / Then: braces and quotes map to their full-width forms.
        XCTAssertEqual(fullwidthSymbolMap["{"]?.0, "｛")
        XCTAssertEqual(fullwidthSymbolMap["}"]?.0, "｝")
        XCTAssertEqual(fullwidthSymbolMap["\""]?.0, "＂")
        XCTAssertEqual(fullwidthSymbolMap["'"]?.0, "＇")
    }

    func testBraceAndQuoteInputComposesFullwidth() {
        // Given: a fresh composition.
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)

        // When: brace/quote keys are typed (as both frontends deliver them).
        for character in ["{", "}", "\"", "'"] {
            XCTAssertEqual(state.inputChar(inputString: character).status, .success)
        }

        // Then: the composition holds full-width symbols, not half-width passthrough.
        XCTAssertEqual(state.composingText.value.convertTarget, "｛｝＂＇")
    }
}

import XCTest

@testable import hazkey_server

/// 既定プロファイルはFullwidth Symbolキーマップを有効にするため、
/// ローマ字モードで入力したASCII記号は半角のまま通過せず、全角文字として組成される
final class KeymapTests: XCTestCase {
    func testFullwidthSymbolMapCoversBracesAndQuotes() {
        // 前提: 組み込みの全角記号テーブル

        // 実行・確認: 波括弧と引用符が全角形式に対応付けられる
        XCTAssertEqual(fullwidthSymbolMap["{"]?.0, "｛")
        XCTAssertEqual(fullwidthSymbolMap["}"]?.0, "｝")
        XCTAssertEqual(fullwidthSymbolMap["\""]?.0, "＂")
        XCTAssertEqual(fullwidthSymbolMap["'"]?.0, "＇")
    }

    func testBraceAndQuoteInputComposesFullwidth() {
        // 前提: 新しい組成
        let state = HazkeyServerState()
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)

        // 実行: 両フロントエンドから渡される形式で、波括弧と引用符のキーを入力する
        for character in ["{", "}", "\"", "'"] {
            XCTAssertEqual(state.inputChar(inputString: character).status, .success)
        }

        // 期待: 組成には半角のまま通過した文字ではなく、全角記号が含まれる
        XCTAssertEqual(state.composingText.value.convertTarget, "｛｝＂＇")
    }
}

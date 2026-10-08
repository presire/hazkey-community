import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// "HazkeyServerState.setContext(surroundingText:anchorIndex:)" の周辺テキスト分割テスト
///
/// カーソル位置 (anchor) は符号点 (Unicode scalar) 単位で数え、左文脈はカーソルより前の全符号点、
/// 右文脈はカーソルより後の先頭40文字 (Character 単位) を接続単位で保持しなければならない
final class SetContextSplitTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case setFailed(String)
        case missingPath(String)
    }

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey-community"), withIntermediateDirectories: true)

        let paths = [
            "XDG_DATA_HOME": "data",
            "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime",
            "XDG_STATE_HOME": "state",
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            if variable == "HAZKEY_DICTIONARY" {
                let dictionaryPath = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
                guard setenv(variable, dictionaryPath.path, 1) == 0 else {
                    throw SetupError.setFailed(variable)
                }
                continue
            }
            guard let directory = paths[variable] else {
                throw SetupError.missingPath(variable)
            }
            guard setenv(variable, root.appendingPathComponent(directory).path, 1) == 0 else {
                throw SetupError.setFailed(variable)
            }
        }
        temporaryDirectory = root
    }

    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                setenv(variable, value, 1)
            } else {
                unsetenv(variable)
            }
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func makeShared() -> HazkeySharedResources {
        HazkeySharedResources(emojiDictionaryURL: nil)
    }

    private func makeState(shared: HazkeySharedResources) -> HazkeyServerState {
        HazkeyServerState(shared: shared)
    }

    /// (a) ASCII文字列をanchorで左右に分ける
    func testAsciiTextSplitsAtAnchor() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        XCTAssertEqual(state.setContext(surroundingText: "abcdef", anchorIndex: 3).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "abc")
        XCTAssertEqual(state.zenzaiRightContext, "def")
    }

    /// (b) かな文字列をanchorで左右に分ける
    func testHiraganaTextSplitsAtAnchor() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        XCTAssertEqual(state.setContext(surroundingText: "あいうえお", anchorIndex: 3).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "あいう")
        XCTAssertEqual(state.zenzaiRightContext, "えお")
    }

    /// (c) ZWJ家族絵文字の直後でも分割位置がずれない
    ///
    /// "👨‍👩‍👧"は、1つのキャラクター (grapheme cluster) だが、5つのUnicode scalar (男・ZWJ・女・ZWJ・女児) である
    /// 旧実装は、"surroundingText.count" (キャラクター数) でクランプするため、"👨‍👩‍👧abc"のカウントは4になり、
    /// anchor=5は4へ丸められて左文脈が文字列全体 (誤り) になってしまう
    func testZwjFamilyEmojiSplitsByCodePointsNotCharacters() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        let text = "👨‍👩‍👧abc"
        XCTAssertEqual(text.unicodeScalars.count, 8)
        XCTAssertEqual(text.count, 4)

        XCTAssertEqual(state.setContext(surroundingText: text, anchorIndex: 5).status, .success)
        // 左を先に検証する: 旧実装は、ここで"👨‍👩‍👧abc"を返してFAILする
        XCTAssertEqual(state.zenzaiLeftContext, "👨‍👩‍👧")
        XCTAssertEqual(state.zenzaiRightContext, "abc")
    }

    /// (d) 負数・超過したanchorが符号点数の範囲へクランプされる
    func testAnchorIsClampedToCodePointRange() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        // 負数: 左なし・右は全文
        XCTAssertEqual(state.setContext(surroundingText: "abc", anchorIndex: -5).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "")
        XCTAssertEqual(state.zenzaiRightContext, "abc")

        // 超過: 左は全文・右なし
        XCTAssertEqual(state.setContext(surroundingText: "abc", anchorIndex: 99).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "abc")
        XCTAssertEqual(state.zenzaiRightContext, "")
    }

    /// (e) 右側が長い時は先頭40文字へ切り詰め、短い左側はそのまま保つ
    func testRightContextIsTruncatedToFirstFortyCharacters() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        let left = "L"
        let right = String(repeating: "あ", count: 50)
        XCTAssertEqual(state.setContext(surroundingText: left + right, anchorIndex: 1).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, left)
        XCTAssertEqual(state.zenzaiRightContext, String(repeating: "あ", count: 40))
        XCTAssertEqual(state.zenzaiRightContext.count, HazkeyServerState.rightContextMaxCharacters)
    }

    /// (e2) 左側が長い時はカーソル直前の末尾256文字だけを保持し、変換エンジンが使う末尾40文字は変わらない
    func testLeftContextKeepsOnlyTheTrailingCharactersBeforeTheCursor() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        let head = String(repeating: "x", count: 100_000)
        let tail = String(repeating: "い", count: HazkeyServerState.leftContextMaxCharacters - 1) + "👨‍👩‍👧"
        let text = head + tail + "右"
        let anchor = (head + tail).unicodeScalars.count
        XCTAssertEqual(state.setContext(surroundingText: text, anchorIndex: anchor).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, tail)
        XCTAssertEqual(state.zenzaiLeftContext.count, HazkeyServerState.leftContextMaxCharacters)
        XCTAssertEqual(
            String(state.zenzaiLeftContext.suffix(40)),
            String((head + tail).suffix(40)))
        XCTAssertEqual(state.zenzaiRightContext, "右")
    }

    /// (f) 空文字列では左右とも空
    func testEmptyTextProducesEmptyContexts() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        XCTAssertEqual(state.setContext(surroundingText: "", anchorIndex: 0).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "")
        XCTAssertEqual(state.zenzaiRightContext, "")
    }

    /// (g) 組成開始と設定再初期化の両方のリセット経路で左右文脈が空になる
    func testResetPathsClearBothContexts() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        XCTAssertEqual(state.setContext(surroundingText: "abcdef", anchorIndex: 3).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "abc")
        XCTAssertEqual(state.zenzaiRightContext, "def")
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "")
        XCTAssertEqual(state.zenzaiRightContext, "")

        XCTAssertEqual(state.setContext(surroundingText: "abcdef", anchorIndex: 3).status, .success)
        XCTAssertEqual(state.zenzaiRightContext, "def")
        state.reinitializeConfiguration()
        XCTAssertEqual(state.zenzaiLeftContext, "")
        XCTAssertEqual(state.zenzaiRightContext, "")
    }

    /// (h) 接続単位: 同じ共有リソース上の2つの状態で右文脈が混線しない
    func testTwoStatesDoNotShareRightContext() {
        let shared = makeShared()
        let first = makeState(shared: shared)
        let second = makeState(shared: shared)
        defer {
            first.close()
            second.close()
        }

        XCTAssertEqual(first.setContext(surroundingText: "abcdef", anchorIndex: 3).status, .success)
        XCTAssertEqual(second.setContext(surroundingText: "あいうえお", anchorIndex: 3).status, .success)

        XCTAssertEqual(first.zenzaiLeftContext, "abc")
        XCTAssertEqual(first.zenzaiRightContext, "def")
        XCTAssertEqual(second.zenzaiLeftContext, "あいう")
        XCTAssertEqual(second.zenzaiRightContext, "えお")
    }

    /// (i) 右文脈の40文字切り詰めは符号点ではなく、キャラクター (grapheme cluster) 単位で行う
    ///
    /// ZWJ家族絵文字は1キャラクター = 5 符号点、結合文字 "か\u{3099}" (が) は1キャラクター = 2 符号点である
    /// 符号点で40個切り詰めると絵文字は8個 = 40符号点、"が" は20文字 = 40符号点となり、
    /// キャラクターは、それぞれ40個 = 200符号点 / 80符号点でなければならない
    func testRightContextTruncationIsByCharactersNotScalars() {
        let shared = makeShared()
        let state = makeState(shared: shared)
        defer { state.close() }

        let family = "👨‍👩‍👧"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 5)
        XCTAssertEqual(state.setContext(surroundingText: "L" + String(repeating: family, count: 45), anchorIndex: 1).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "L")
        XCTAssertEqual(state.zenzaiRightContext, String(repeating: family, count: 40))
        XCTAssertEqual(state.zenzaiRightContext.count, 40)
        XCTAssertEqual(state.zenzaiRightContext.unicodeScalars.count, 200)

        let combining = "か\u{3099}"
        XCTAssertEqual(combining.count, 1)
        XCTAssertEqual(combining.unicodeScalars.count, 2)
        XCTAssertEqual(state.setContext(surroundingText: "L" + String(repeating: combining, count: 45), anchorIndex: 1).status, .success)
        XCTAssertEqual(state.zenzaiLeftContext, "L")
        XCTAssertEqual(state.zenzaiRightContext, String(repeating: combining, count: 40))
        XCTAssertEqual(state.zenzaiRightContext.count, 40)
        XCTAssertEqual(state.zenzaiRightContext.unicodeScalars.count, 80)
    }
}

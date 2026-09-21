// Tests for the shared composition-cursor presentation rules.
//
// These pure functions are the single source of the live-conversion pause
// behavior: both fcitx5-hazkey and ibus-hazkey call them instead of deriving
// the mode or the caret offset themselves. Registered in
// hazkey-frontend-common so they also run in an IBus-only build
// (-DENABLE_FCITX5=OFF).
//
// No hazkey-server, socket or frontend toolkit is involved.
#include "composing_cursor_view.h"

#include <cassert>
#include <iostream>
#include <string>

namespace {

using hazkey::frontend::caretByteOffset;
using hazkey::frontend::caretCharOffset;
using hazkey::frontend::composingTextOf;
using hazkey::frontend::ComposingTextWithCursor;
using hazkey::frontend::cursorAtEnd;
using hazkey::frontend::shouldShowAuxText;

ComposingTextWithCursor parts(const std::string& before,
                              const std::string& onCursor,
                              const std::string& after) {
    return ComposingTextWithCursor{before, onCursor, after};
}

void testEmptyComposition() {
    // Given: no composition at all (the server returns three empty fields).
    const auto p = parts("", "", "");
    // Then: end mode, so live conversion is never paused for an empty
    // composition, and the caret offsets are zero.
    assert(cursorAtEnd(p));
    assert(caretByteOffset(p) == 0);
    assert(caretCharOffset(p) == 0);
    assert(composingTextOf(p).empty());

    std::cout << "[PASS] empty composition is end mode with a zero caret\n";
}

void testCursorAtEnd() {
    // Given: the cursor sits after the last character (nothing under it and
    // nothing to its right).
    const auto p = parts("あいう", "", "");
    assert(cursorAtEnd(p));
    // Then: the caret is at the very end of the text.
    assert(caretByteOffset(p) == std::string("あいう").size());
    assert(caretCharOffset(p) == 3);
    assert(composingTextOf(p) == "あいう");

    std::cout << "[PASS] cursor at end keeps live conversion enabled\n";
}

void testCursorOnLastCharacter() {
    // Given: the cursor is ON the last character; `after` is empty but
    // `onCursor` is not. This is the case that a naive "after.empty()" test
    // would misread as the end.
    const auto p = parts("あい", "う", "");
    assert(!cursorAtEnd(p));
    assert(caretByteOffset(p) == std::string("あい").size());
    assert(caretCharOffset(p) == 2);
    assert(composingTextOf(p) == "あいう");

    std::cout << "[PASS] cursor on the last character is internal mode\n";
}

void testCursorInMiddle() {
    const auto p = parts("あ", "い", "うえ");
    assert(!cursorAtEnd(p));
    assert(caretByteOffset(p) == std::string("あ").size());
    assert(caretCharOffset(p) == 1);
    assert(composingTextOf(p) == "あいうえ");

    std::cout << "[PASS] cursor in the middle is internal mode\n";
}

void testMultibyteCaretUnits() {
    // fcitx5 wants a byte offset, IBus wants a character offset. For kana
    // (3 bytes per character in UTF-8) the two MUST differ, otherwise one of
    // the frontends would place the caret in the wrong spot.
    const auto kana = parts("あいう", "え", "お");
    assert(caretByteOffset(kana) == 9);
    assert(caretCharOffset(kana) == 3);
    assert(caretByteOffset(kana) != caretCharOffset(kana));

    // Mixed ASCII + kana: only the kana inflates the byte offset.
    const auto mixed = parts("abあ", "い", "");
    assert(caretByteOffset(mixed) == 5);
    assert(caretCharOffset(mixed) == 3);

    // Pure ASCII: the two units coincide, which is also correct.
    const auto ascii = parts("abc", "d", "");
    assert(caretByteOffset(ascii) == 3);
    assert(caretCharOffset(ascii) == 3);

    // 4-byte UTF-8 (emoji) counts as one character.
    const auto emoji = parts("\xF0\x9F\x98\x80", "あ", "");
    assert(caretByteOffset(emoji) == 4);
    assert(caretCharOffset(emoji) == 1);

    std::cout << "[PASS] caret byte and character offsets are distinct units\n";
}

void testAuxTextGate() {
    using Mode = hazkey::config::Profile_AuxTextMode;

    // DISABLED: never shown, in either mode.
    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_DISABLED,
                              /*cursorIsAtEnd=*/true));
    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_DISABLED,
                              /*cursorIsAtEnd=*/false));

    // SHOW_ALWAYS: always shown, in either mode.
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS,
                             /*cursorIsAtEnd=*/true));
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS,
                             /*cursorIsAtEnd=*/false));

    // SHOW_WHEN_CURSOR_NOT_AT_END: only in internal mode.
    assert(!shouldShowAuxText(
        Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END,
        /*cursorIsAtEnd=*/true));
    assert(shouldShowAuxText(
        Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END,
        /*cursorIsAtEnd=*/false));

    // UNSPECIFIED: falls back to the server default
    // (auxTextShowWhenCursorNotAtEnd), NOT to "hidden".
    assert(!shouldShowAuxText(
        Mode::Profile_AuxTextMode_AUX_TEXT_MODE_UNSPECIFIED,
        /*cursorIsAtEnd=*/true));
    assert(shouldShowAuxText(
        Mode::Profile_AuxTextMode_AUX_TEXT_MODE_UNSPECIFIED,
        /*cursorIsAtEnd=*/false));

    std::cout << "[PASS] aux-text gate for all four modes x end/internal\n";
}

void testGateComposesWithCursorAtEnd() {
    // The frontends call the two together; check the composition once so a
    // future signature change cannot silently invert the gate.
    using Mode = hazkey::config::Profile_AuxTextMode;
    const auto atEnd = parts("あいう", "", "");
    const auto internalPos = parts("あい", "う", "");

    assert(!shouldShowAuxText(
        Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END,
        cursorAtEnd(atEnd)));
    assert(shouldShowAuxText(
        Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END,
        cursorAtEnd(internalPos)));

    std::cout << "[PASS] gate composed with cursorAtEnd()\n";
}

}  // namespace

int main() {
    testEmptyComposition();
    testCursorAtEnd();
    testCursorOnLastCharacter();
    testCursorInMiddle();
    testMultibyteCaretUnits();
    testAuxTextGate();
    testGateComposesWithCursorAtEnd();
    std::cout << "composing_cursor_view_test: all checks passed\n";
    return 0;
}

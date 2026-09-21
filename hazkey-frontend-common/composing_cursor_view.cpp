#include "composing_cursor_view.h"

namespace hazkey::frontend {

namespace {

// UTF-8 character count without GLib: every byte that is not a continuation
// byte (0b10xxxxxx) starts a character. Malformed input degrades gracefully
// (a stray continuation byte is simply not counted) instead of throwing,
// which is the right trade-off for a display-only caret offset.
std::size_t utf8CharCount(const std::string& text) {
    std::size_t count = 0;
    for (unsigned char byte : text) {
        if ((byte & 0xC0) != 0x80) {
            ++count;
        }
    }
    return count;
}

}  // namespace

bool cursorAtEnd(const ComposingTextWithCursor& parts) {
    return parts.onCursor.empty() && parts.after.empty();
}

std::string composingTextOf(const ComposingTextWithCursor& parts) {
    return parts.before + parts.onCursor + parts.after;
}

std::size_t caretByteOffset(const ComposingTextWithCursor& parts) {
    return parts.before.size();
}

std::size_t caretCharOffset(const ComposingTextWithCursor& parts) {
    return utf8CharCount(parts.before);
}

bool shouldShowAuxText(hazkey::config::Profile_AuxTextMode mode,
                       bool cursorIsAtEnd) {
    switch (mode) {
        case hazkey::config::Profile_AuxTextMode_AUX_TEXT_DISABLED:
            return false;
        case hazkey::config::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS:
            return true;
        case hazkey::config::
            Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END:
            return !cursorIsAtEnd;
        case hazkey::config::Profile_AuxTextMode_AUX_TEXT_MODE_UNSPECIFIED:
            // Unset profiles fall back to the server default
            // (HazkeyServerConfig.genDefaultConfig() writes
            // auxTextShowWhenCursorNotAtEnd).
            return !cursorIsAtEnd;
        default:
            // A value from a newer server than this frontend: behave like the
            // default rather than silently hiding the cursor feedback.
            return !cursorIsAtEnd;
    }
}

}  // namespace hazkey::frontend

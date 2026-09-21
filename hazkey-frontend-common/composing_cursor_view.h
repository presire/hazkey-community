#ifndef HAZKEY_COMPOSING_CURSOR_VIEW_H
#define HAZKEY_COMPOSING_CURSOR_VIEW_H

#include <cstddef>
#include <string>

#include "config.pb.h"
#include "hazkey_frontend_hooks.h"

// Shared presentation rules for the server-reported composition cursor.
//
// Both frontends (fcitx5-hazkey, ibus-hazkey) implement the SAME live
// conversion pause behavior: while the composition cursor is not at the end,
// the live-conversion text is not shown at all. The raw hiragana is shown
// instead with a REAL caret, because a kana offset cannot be mapped into the
// converted text (kana <-> kanji is many-to-many, so no such mapping exists).
// When the cursor returns to the end, live conversion resumes.
//
// The whole mode decision and caret arithmetic lives here so the two
// frontends cannot drift apart: neither of them re-derives these values.
// Everything in this header is pure and framework-independent (no fcitx, IBus
// or GLib types).
namespace hazkey::frontend {

// True when the server cursor sits AFTER the last character of the
// composition, i.e. there is nothing to the right of it.
//
//   empty composition      -> true  (treated as end mode; nothing to show)
//   cursor at the end      -> true  (before = whole text, other two empty)
//   cursor on last char    -> false (onCursor = last char, after empty)
//   cursor in the middle   -> false
bool cursorAtEnd(const ComposingTextWithCursor& parts);

// The full composition text (before + onCursor + after).
std::string composingTextOf(const ComposingTextWithCursor& parts);

// Caret position as a UTF-8 BYTE offset, for fcitx::Text::setCursor()
// (fcitx5 text.h documents its cursor as "by byte").
std::size_t caretByteOffset(const ComposingTextWithCursor& parts);

// Caret position as a UTF-8 CHARACTER offset, for
// ibus_engine_update_preedit_text()'s cursor_pos (characters).
// Counted without GLib so this stays framework-independent; invalid trailing
// bytes are counted as one character each rather than throwing, matching the
// lenient counting both frontends need for a display-only value.
std::size_t caretCharOffset(const ComposingTextWithCursor& parts);

// Whether the raw-hiragana auxiliary text (fcitx AuxUp / the IBus auxiliary
// slot) should be rendered. The gate lives on the frontend side so the
// server's getHiraganaWithCursor() can stay a pure structural API.
//
//   AUX_TEXT_DISABLED                    -> never
//   AUX_TEXT_SHOW_ALWAYS                 -> always
//   AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END -> only when the cursor is not at end
//   AUX_TEXT_MODE_UNSPECIFIED            -> same as the previous one (the
//                                           server default profile value)
bool shouldShowAuxText(hazkey::config::Profile_AuxTextMode mode,
                       bool cursorIsAtEnd);

}  // namespace hazkey::frontend

#endif  // HAZKEY_COMPOSING_CURSOR_VIEW_H

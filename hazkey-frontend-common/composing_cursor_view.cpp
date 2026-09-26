/**
 * @file composing_cursor_view.cpp
 * @brief 組成中カーソルの表示判定とキャレット位置計算を実装する
 *
 * 公開関数の意味は、ヘッダ側の文書を正として、ここでは内部補助だけを文書化する
 * 定義側への重複文書は置かない
 */

#include "composing_cursor_view.h"

namespace hazkey::frontend {

namespace {

/**
 * @brief UTF-8の継続バイト以外を1文字として数える
 *
 * GLibを使わずに数えるための内部補助である
 * 不正な入力も例外にせず、表示用のキャレット位置を返す
 *
 * @param text 数える対象の文字列
 * @return 文字数
 */
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
             // 未設定のプロファイルはサーバの既定値と同じ扱いにする
            return !cursorIsAtEnd;
        default:
             // 新しいサーバの値は既定値と同じ扱いにする
            return !cursorIsAtEnd;
    }
}

}  // namespace hazkey::frontend

    /**
 * @file surrounding_text_snapshot.cpp
 * @brief 周辺テキストの送信スナップショット生成を実装する
 *
 * 公開関数の意味は、ヘッダ側の文書を正とする
 * ここでは不正UTF-8の判定など内部補助だけを文書化する
 */

#include "surrounding_text_snapshot.h"
#include <algorithm>
#include <cstddef>
#include <vector>

namespace hazkey::frontend {

namespace {

/**
 * @brief 先頭バイトから符号点のUTF-8バイト長を返す
 *
 * 不正な先頭バイト(継続バイトや範囲外)には0を返す
 *
 * @param firstByte 先頭バイト
 * @return 符号点のバイト長、または不正なら0
 */
int utf8SequenceLength(unsigned char firstByte) {
    if (firstByte < 0x80) {
        return 1;
    }
    if (firstByte >= 0xC2 && firstByte <= 0xDF) {
        return 2;
    }
    if (firstByte >= 0xE0 && firstByte <= 0xEF) {
        return 3;
    }
    if (firstByte >= 0xF0 && firstByte <= 0xF4) {
        return 4;
    }
    return 0;
}

/**
 * @brief UTF-8の継続バイトか判定する
 */
bool isContinuationByte(unsigned char byte) { return (byte & 0xC0) == 0x80; }

/**
 * @brief 指定長のUTF-8並びが正当な1符号点か判定する
 *
 * 継続バイトの位置と、過長符号やサロゲートやU+10FFFF超過を排除する先頭バイト固有の制約を検査する
 *
 * @param bytes 先頭を指すバイト並び
 * @param length 符号点のバイト長
 * @return 正当ならtrue
 */
bool isValidSequence(const unsigned char* bytes, int length) {
    switch (length) {
        case 1:
            return true;
        case 2:
            return isContinuationByte(bytes[1]);
        case 3:
            if (!isContinuationByte(bytes[1]) || !isContinuationByte(bytes[2])) {
                return false;
            }
            if (bytes[0] == 0xE0) {
                return bytes[1] >= 0xA0;
            }
            if (bytes[0] == 0xED) {
                return bytes[1] <= 0x9F;
            }
            return true;
        case 4:
            if (!isContinuationByte(bytes[1]) || !isContinuationByte(bytes[2]) ||
                !isContinuationByte(bytes[3])) {
                return false;
            }
            if (bytes[0] == 0xF0) {
                return bytes[1] >= 0x90;
            }
            if (bytes[0] == 0xF4) {
                return bytes[1] <= 0x8F;
            }
            return true;
        default:
            return false;
    }
}

/**
 * @brief 文字列を符号点ごとの部分文字列へ分割する
 *
 * 不正なUTF-8が含まれる場合は分割せず偽を返す
 *
 * @param text 分割する対象
 * @param out 符号点ごとの部分文字列の出力先
 * @return 正当なUTF-8ならtrue
 */
bool splitCodePoints(const std::string& text,
                     std::vector<std::string>* out) {
    out->clear();
    const auto* bytes = reinterpret_cast<const unsigned char*>(text.data());
    std::size_t offset = 0;
    while (offset < text.size()) {
        const int length = utf8SequenceLength(bytes[offset]);
        if (length == 0 ||
            offset + static_cast<std::size_t>(length) > text.size()) {
            return false;
        }
        if (!isValidSequence(bytes + offset, length)) {
            return false;
        }
        out->push_back(text.substr(offset, static_cast<std::size_t>(length)));
        offset += static_cast<std::size_t>(length);
    }
    return true;
}

}  // namespace

SurroundingSnapshot buildSurroundingSnapshot(const std::string& text, int cursor,
                                              int anchor,
                                              const std::string& append) {
    std::vector<std::string> textPoints;
    std::vector<std::string> appendPoints;
    if (!splitCodePoints(text, &textPoints) ||
        !splitCodePoints(append, &appendPoints)) {
        return {"", 0};
    }

    const int count = static_cast<int>(textPoints.size());
    const int clampedCursor = std::clamp(cursor, 0, count);
    const int clampedAnchor = std::clamp(anchor, 0, count);
    const int lo = std::min(clampedCursor, clampedAnchor);
    const int hi = std::max(clampedCursor, clampedAnchor);

    std::string result;
    result.reserve(text.size() + append.size());
    for (int i = 0; i < lo; ++i) {
        result += textPoints[static_cast<std::size_t>(i)];
    }
    result += append;
    for (int i = hi; i < count; ++i) {
        result += textPoints[static_cast<std::size_t>(i)];
    }

    return {result, lo + static_cast<int>(appendPoints.size())};
}

bool CompositionSurroundingFreeze::liveLagsBehindCarry(
    const std::string& liveText, int liveCursor, int liveAnchor) const {
    if (liveCursor != liveAnchor || liveText == text_) {
        return false;
    }
    std::vector<std::string> livePoints;
    std::vector<std::string> carriedPoints;
    if (!splitCodePoints(liveText, &livePoints) ||
        !splitCodePoints(text_, &carriedPoints)) {
        return false;
    }
    const int liveLeftCount =
        std::clamp(liveCursor, 0, static_cast<int>(livePoints.size()));
    if (liveLeftCount < baseCursor_ || liveLeftCount >= cursor_) {
        return false;
    }
    return std::equal(livePoints.begin(), livePoints.begin() + liveLeftCount,
                      carriedPoints.begin());
}

SurroundingSnapshot CompositionSurroundingFreeze::resolve(
    const std::string& liveText, int liveCursor, int liveAnchor,
    const std::string& append) {
    // 持ち越し中でも、アプリケーションが終了後に周辺テキストを報告し直していれば、新しいライブ値を優先する
    const bool useStored =
        state_ == State::Frozen ||
        (state_ == State::Carried &&
         ((liveText == carriedLiveText_ && liveCursor == carriedLiveCursor_ &&
           liveAnchor == carriedLiveAnchor_) ||
          liveLagsBehindCarry(liveText, liveCursor, liveAnchor)));
    const SurroundingSnapshot snapshot =
        useStored ? buildSurroundingSnapshot(text_, cursor_, cursor_, append)
                  : buildSurroundingSnapshot(liveText, liveCursor, liveAnchor,
                                             append);
    if (!useStored) {
        baseCursor_ =
            buildSurroundingSnapshot(liveText, liveCursor, liveAnchor, "").anchor;
    }
    state_ = State::Frozen;
    text_ = snapshot.text;
    cursor_ = snapshot.anchor;
    carriedLiveText_.clear();
    carriedLiveCursor_ = 0;
    carriedLiveAnchor_ = 0;
    return snapshot;
}

void CompositionSurroundingFreeze::appendCommitted(
    const std::string& committed) {
    if (state_ == State::Idle || committed.empty()) {
        return;
    }
    const SurroundingSnapshot snapshot =
        buildSurroundingSnapshot(text_, cursor_, cursor_, committed);
    text_ = snapshot.text;
    cursor_ = snapshot.anchor;
}

void CompositionSurroundingFreeze::finish(bool liveAvailable,
                                          const std::string& liveText,
                                          int liveCursor, int liveAnchor) {
    if (!liveAvailable) {
        release();
        return;
    }
    if (state_ == State::Idle) {
        return;
    }
    state_ = State::Carried;
    carriedLiveText_ = liveText;
    carriedLiveCursor_ = liveCursor;
    carriedLiveAnchor_ = liveAnchor;
}

void CompositionSurroundingFreeze::release() {
    state_ = State::Idle;
    text_.clear();
    cursor_ = 0;
    baseCursor_ = 0;
    carriedLiveText_.clear();
    carriedLiveCursor_ = 0;
    carriedLiveAnchor_ = 0;
}

}  // namespace hazkey::frontend

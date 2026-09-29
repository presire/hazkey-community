#include "candidate_annotation.h"

#include <cstdint>

namespace hazkey::frontend {

namespace {

/// 表記と注記の最小間隔 (全角空白2個)
constexpr std::string_view kBaseGap = "\u3000\u3000";
constexpr std::string_view kFullWidthSpace = "\u3000";
constexpr std::string_view kHalfWidthSpace = "\u2002";

bool isZeroWidth(char32_t c) {
    return (c >= 0x0300 && c <= 0x036F) || (c >= 0x200B && c <= 0x200F) ||
           (c >= 0x3099 && c <= 0x309A) || (c >= 0xFE00 && c <= 0xFE0F) ||
           (c >= 0xE0100 && c <= 0xE01EF);
}

bool isWide(char32_t c) {
    return (c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0x303E) ||
           (c >= 0x3041 && c <= 0x33FF) || (c >= 0x3400 && c <= 0x4DBF) ||
           (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xA000 && c <= 0xA4CF) ||
           (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF) ||
           (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60) ||
           (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0x1F300 && c <= 0x1F64F) ||
           (c >= 0x1F900 && c <= 0x1F9FF) || (c >= 0x20000 && c <= 0x3FFFD);
}

}  // namespace

int displayColumns(std::string_view utf8) {
    int columns = 0;
    size_t i = 0;
    while (i < utf8.size()) {
        const auto lead = static_cast<std::uint8_t>(utf8[i]);
        size_t length = 1;
        char32_t codePoint = lead;
        if (lead >= 0xF0 && lead <= 0xF4) {
            length = 4;
            codePoint = lead & 0x07;
        } else if (lead >= 0xE0) {
            length = 3;
            codePoint = lead & 0x0F;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            length = 2;
            codePoint = lead & 0x1F;
        }
        bool valid = length == 1 ? lead < 0x80 : i + length <= utf8.size();
        for (size_t k = 1; valid && k < length; ++k) {
            const auto next = static_cast<std::uint8_t>(utf8[i + k]);
            valid = (next & 0xC0) == 0x80;
            codePoint = (codePoint << 6) | (next & 0x3F);
        }
        if (!valid) {
            columns += 1;
            i += 1;
            continue;
        }
        columns += isZeroWidth(codePoint) ? 0 : isWide(codePoint) ? 2 : 1;
        i += length;
    }
    return columns;
}

std::string annotationGap(std::string_view text, int alignColumns) {
    std::string gap;
    const int padding = alignColumns - displayColumns(text);
    for (int k = 0; k < padding / 2; ++k) {
        gap += kFullWidthSpace;
    }
    if (padding > 0 && padding % 2 == 1) {
        gap += kHalfWidthSpace;
    }
    gap += kBaseGap;
    return gap;
}

}  // namespace hazkey::frontend

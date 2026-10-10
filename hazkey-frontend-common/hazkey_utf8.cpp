#include "hazkey_utf8.h"
#include <cstddef>
#include <string>
#include <string_view>

namespace hazkey::frontend {
namespace {

constexpr std::string_view kReplacement = "\xEF\xBF\xBD";

bool isContinuation(unsigned char byte) {
    return byte >= 0x80 && byte <= 0xBF;
}

std::size_t validSequenceLength(std::string_view input, std::size_t offset) {
    const auto first = static_cast<unsigned char>(input[offset]);
    if (first >= 0x01 && first <= 0x7F) {
        return 1;
    }

    const std::size_t remaining = input.size() - offset;
    if (first >= 0xC2 && first <= 0xDF && remaining >= 2) {
        const auto second = static_cast<unsigned char>(input[offset + 1]);
        return isContinuation(second) ? 2 : 0;
    }

    if (first >= 0xE0 && first <= 0xEF && remaining >= 3) {
        const auto second = static_cast<unsigned char>(input[offset + 1]);
        const auto third = static_cast<unsigned char>(input[offset + 2]);
        const bool validSecond =
            (first == 0xE0) ? (second >= 0xA0 && second <= 0xBF)
            : (first == 0xED) ? (second >= 0x80 && second <= 0x9F)
                              : isContinuation(second);
        return validSecond && isContinuation(third) ? 3 : 0;
    }

    if (first >= 0xF0 && first <= 0xF4 && remaining >= 4) {
        const auto second = static_cast<unsigned char>(input[offset + 1]);
        const auto third = static_cast<unsigned char>(input[offset + 2]);
        const auto fourth = static_cast<unsigned char>(input[offset + 3]);
        const bool validSecond =
            (first == 0xF0) ? (second >= 0x90 && second <= 0xBF)
            : (first == 0xF4) ? (second >= 0x80 && second <= 0x8F)
                              : isContinuation(second);
        return validSecond && isContinuation(third) && isContinuation(fourth)
                   ? 4
                   : 0;
    }

    return 0;
}

bool isValidUtf8(std::string_view input) {
    std::size_t offset = 0;
    while (offset < input.size()) {
        const auto length = validSequenceLength(input, offset);
        if (length == 0) {
            return false;
        }
        offset += length;
    }
    return true;
}

}

std::string makeValidUtf8(std::string_view input) {
    if (isValidUtf8(input)) {
        return std::string(input);
    }

    std::string output;
    output.reserve(input.size());
    std::size_t offset = 0;
    while (offset < input.size()) {
        const auto length = validSequenceLength(input, offset);
        if (length == 0) {
            output.append(kReplacement);
            ++offset;
            continue;
        }
        output.append(input.data() + offset, length);
        offset += length;
    }
    return output;
}

}

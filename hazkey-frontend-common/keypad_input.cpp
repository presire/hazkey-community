#include "keypad_input.h"

#include <string_view>

namespace hazkey::frontend {

namespace {

/**
 * @struct KeypadCharEntry
 * @brief テンキーの文字キー1つ分の対応表の行
 */
struct KeypadCharEntry {
    uint32_t keysym;            ///< テンキーのkeysym
    std::string_view half;      ///< 半角文字
    std::string_view full;      ///< 全角文字 (キーの印字どおり)
};

/// テンキーの文字キー17個の対応表 (keysymはX11の定義値)
constexpr KeypadCharEntry kKeypadChars[] = {
    {0xFFB0, "0", "\uFF10"},    // KP_0 → ０
    {0xFFB1, "1", "\uFF11"},    // KP_1 → １
    {0xFFB2, "2", "\uFF12"},    // KP_2 → ２
    {0xFFB3, "3", "\uFF13"},    // KP_3 → ３
    {0xFFB4, "4", "\uFF14"},    // KP_4 → ４
    {0xFFB5, "5", "\uFF15"},    // KP_5 → ５
    {0xFFB6, "6", "\uFF16"},    // KP_6 → ６
    {0xFFB7, "7", "\uFF17"},    // KP_7 → ７
    {0xFFB8, "8", "\uFF18"},    // KP_8 → ８
    {0xFFB9, "9", "\uFF19"},    // KP_9 → ９
    {0xFFAE, ".", "\uFF0E"},    // KP_Decimal → ．
    {0xFFAB, "+", "\uFF0B"},    // KP_Add → ＋
    {0xFFAD, "-", "\uFF0D"},    // KP_Subtract → －
    {0xFFAA, "*", "\uFF0A"},    // KP_Multiply → ＊
    {0xFFAF, "/", "\uFF0F"},    // KP_Divide → ／
    {0xFFBD, "=", "\uFF1D"},    // KP_Equal → ＝
    {0xFFAC, ",", "\uFF0C"},    // KP_Separator → ，
};

/**
 * @brief keysymに対応する対応表の行を探す
 * @param keysym キーのkeysym
 * @return 対応する行、テンキーの文字キーでなければnullptr
 */
const KeypadCharEntry* findKeypadChar(uint32_t keysym) {
    for (const auto& entry : kKeypadChars) {
        if (entry.keysym == keysym) {
            return &entry;
        }
    }
    return nullptr;
}

}  // namespace

bool isKeypadCharKeySym(uint32_t keysym) {
    return findKeypadChar(keysym) != nullptr;
}

std::optional<std::string> keypadHalfwidthChar(uint32_t keysym) {
    const auto* entry = findKeypadChar(keysym);
    if (entry == nullptr) {
        return std::nullopt;
    }
    return std::string(entry->half);
}

std::optional<std::string> keypadFullwidthChar(uint32_t keysym) {
    const auto* entry = findKeypadChar(keysym);
    if (entry == nullptr) {
        return std::nullopt;
    }
    return std::string(entry->full);
}

std::optional<std::string> keypadCharForMode(
    uint32_t keysym, hazkey::config::Profile::KeypadInputMode mode) {
    switch (mode) {
        case hazkey::config::Profile::KEYPAD_INPUT_HALFWIDTH:
            return keypadHalfwidthChar(keysym);
        case hazkey::config::Profile::KEYPAD_INPUT_FULLWIDTH:
            return keypadFullwidthChar(keysym);
        default:
            // 素通り・未設定・未知の値では、IMEがテンキーの文字を組成へ入力しない
            return std::nullopt;
    }
}

hazkey::config::Profile::KeypadInputMode normalizeKeypadInputMode(
    const hazkey::config::Profile& profile) {
    if (profile.has_keypad_input_mode()) {
        switch (profile.keypad_input_mode()) {
            case hazkey::config::Profile::KEYPAD_INPUT_HALFWIDTH:
            case hazkey::config::Profile::KEYPAD_INPUT_FULLWIDTH:
            case hazkey::config::Profile::KEYPAD_INPUT_PASSTHROUGH:
                return profile.keypad_input_mode();
            default:
                break;
        }
    }
    return hazkey::config::Profile::KEYPAD_INPUT_PASSTHROUGH;
}

}  // namespace hazkey::frontend

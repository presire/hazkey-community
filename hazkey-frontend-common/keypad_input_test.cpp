/**
 * @file keypad_input_test.cpp
 * @brief テンキーの文字キーの分類と、半角・全角の文字への変換の検証をまとめる
 *
 * 対象の17キーの対応表、対象外のテンキー (ナビゲーションキー・KP_Enter等) の非該当、入力方法の補完を確認する
 * サーバやソケットやtoolkitを使用しない純粋関数の検査である
 */

#include "keypad_input.h"

#include <cstdint>
#include <iostream>
#include <optional>
#include <string>

namespace {

using hazkey::config::Profile;
using hazkey::frontend::isKeypadCharKeySym;
using hazkey::frontend::keypadCharForMode;
using hazkey::frontend::keypadFullwidthChar;
using hazkey::frontend::keypadHalfwidthChar;
using hazkey::frontend::normalizeKeypadInputMode;

int failures = 0;

/**
 * @brief 変換結果が期待値と一致するかを確かめる
 * @param label 失敗時に表示する名前
 * @param got 変換結果
 * @param want 期待値 (std::nulloptは対象外を表す)
 */
void expectChar(const std::string& label, const std::optional<std::string>& got,
                const std::optional<std::string>& want) {
    if (got != want) {
        std::cerr << "FAIL [" << label << "] got "
                  << (got ? "\"" + *got + "\"" : std::string("nullopt")) << " want "
                  << (want ? "\"" + *want + "\"" : std::string("nullopt")) << "\n";
        ++failures;
    }
}

/**
 * @brief 条件が成り立つかを確かめる
 * @param label 失敗時に表示する名前
 * @param condition 確かめる条件
 */
void expectTrue(const std::string& label, bool condition) {
    if (!condition) {
        std::cerr << "FAIL [" << label << "]\n";
        ++failures;
    }
}

/**
 * @struct Row
 * @brief 対応表の期待値の行
 */
struct Row {
    uint32_t keysym;        ///< テンキーのkeysym
    const char* name;       ///< 失敗時に表示するkeysym名
    const char* half;       ///< 期待する半角文字
    const char* full;       ///< 期待する全角文字
};

/// 計画書の対応表と同じ17キーの期待値
constexpr Row kRows[] = {
    {0xFFB0, "KP_0", "0", "０"},         {0xFFB1, "KP_1", "1", "１"},
    {0xFFB2, "KP_2", "2", "２"},         {0xFFB3, "KP_3", "3", "３"},
    {0xFFB4, "KP_4", "4", "４"},         {0xFFB5, "KP_5", "5", "５"},
    {0xFFB6, "KP_6", "6", "６"},         {0xFFB7, "KP_7", "7", "７"},
    {0xFFB8, "KP_8", "8", "８"},         {0xFFB9, "KP_9", "9", "９"},
    {0xFFAE, "KP_Decimal", ".", "．"},   {0xFFAB, "KP_Add", "+", "＋"},
    {0xFFAD, "KP_Subtract", "-", "－"},  {0xFFAA, "KP_Multiply", "*", "＊"},
    {0xFFAF, "KP_Divide", "/", "／"},    {0xFFBD, "KP_Equal", "=", "＝"},
    {0xFFAC, "KP_Separator", ",", "，"},
};

/**
 * @brief 対象の17キーが、半角・全角とも対応表どおりに変換されることを確かめる
 */
void testKeypadCharTable() {
    for (const auto& row : kRows) {
        const std::string name = row.name;
        expectTrue(name + " is keypad char", isKeypadCharKeySym(row.keysym));
        expectChar(name + " half", keypadHalfwidthChar(row.keysym), std::string(row.half));
        expectChar(name + " full", keypadFullwidthChar(row.keysym), std::string(row.full));
        expectChar(name + " mode half",
                   keypadCharForMode(row.keysym, Profile::KEYPAD_INPUT_HALFWIDTH),
                   std::string(row.half));
        expectChar(name + " mode full",
                   keypadCharForMode(row.keysym, Profile::KEYPAD_INPUT_FULLWIDTH),
                   std::string(row.full));
        expectChar(name + " mode passthrough",
                   keypadCharForMode(row.keysym, Profile::KEYPAD_INPUT_PASSTHROUGH),
                   std::nullopt);
        expectChar(name + " mode unspecified",
                   keypadCharForMode(row.keysym, Profile::KEYPAD_INPUT_MODE_UNSPECIFIED),
                   std::nullopt);
    }
    // 全角の記号は、メインキーのJapanese Symbolキーマップ (ー ・ 。 、) ではなく印字どおりの文字
    expectChar("KP_Subtract full is U+FF0D", keypadFullwidthChar(0xFFAD), std::string("\uFF0D"));
    expectChar("KP_Divide full is U+FF0F", keypadFullwidthChar(0xFFAF), std::string("\uFF0F"));
    expectChar("KP_Decimal full is U+FF0E", keypadFullwidthChar(0xFFAE), std::string("\uFF0E"));
    expectChar("KP_Separator full is U+FF0C", keypadFullwidthChar(0xFFAC), std::string("\uFF0C"));
}

/**
 * @brief 対象外のテンキー (ナビゲーションキー・制御キー・機能キー) とメインキーが非該当であることを確かめる
 */
void testNonKeypadCharKeySymsAreExcluded() {
    const struct {
        uint32_t keysym;
        const char* name;
    } excluded[] = {
        {0xFF95, "KP_Home"},      {0xFF96, "KP_Left"},   {0xFF97, "KP_Up"},
        {0xFF98, "KP_Right"},     {0xFF99, "KP_Down"},   {0xFF9A, "KP_Page_Up"},
        {0xFF9B, "KP_Page_Down"}, {0xFF9C, "KP_End"},    {0xFF9D, "KP_Begin"},
        {0xFF9E, "KP_Insert"},    {0xFF9F, "KP_Delete"}, {0xFF8D, "KP_Enter"},
        {0xFF80, "KP_Space"},     {0xFF89, "KP_Tab"},    {0xFF91, "KP_F1"},
        {0xFF92, "KP_F2"},        {0xFF93, "KP_F3"},     {0xFF94, "KP_F4"},
        {0x0030, "main 0"},       {0x002D, "main minus"}, {0xFF0D, "Return"},
    };
    for (const auto& key : excluded) {
        const std::string name = key.name;
        expectTrue(name + " is not keypad char", !isKeypadCharKeySym(key.keysym));
        expectChar(name + " half", keypadHalfwidthChar(key.keysym), std::nullopt);
        expectChar(name + " full", keypadFullwidthChar(key.keysym), std::nullopt);
        expectChar(name + " mode full",
                   keypadCharForMode(key.keysym, Profile::KEYPAD_INPUT_FULLWIDTH),
                   std::nullopt);
    }
}

/**
 * @brief プロファイルの入力方法が、欠落・UNSPECIFIED・未知の値で素通りに補完され、明示値は保持されることを確かめる
 */
void testNormalizeKeypadInputMode() {
    Profile missing;
    expectTrue("missing -> passthrough",
               normalizeKeypadInputMode(missing) == Profile::KEYPAD_INPUT_PASSTHROUGH);

    Profile unspecified;
    unspecified.set_keypad_input_mode(Profile::KEYPAD_INPUT_MODE_UNSPECIFIED);
    expectTrue("unspecified -> passthrough",
               normalizeKeypadInputMode(unspecified) == Profile::KEYPAD_INPUT_PASSTHROUGH);

    for (const auto mode : {Profile::KEYPAD_INPUT_PASSTHROUGH, Profile::KEYPAD_INPUT_HALFWIDTH,
                            Profile::KEYPAD_INPUT_FULLWIDTH}) {
        Profile explicitMode;
        explicitMode.set_keypad_input_mode(mode);
        expectTrue("explicit " + std::to_string(static_cast<int>(mode)) + " is kept",
                   normalizeKeypadInputMode(explicitMode) == mode);
    }

    // 新しいサーバが追加した未知の値は、IMEを素通りする扱いにする
    Profile unknown;
    unknown.set_keypad_input_mode(static_cast<Profile::KeypadInputMode>(99));
    expectTrue("unknown -> passthrough",
               normalizeKeypadInputMode(unknown) == Profile::KEYPAD_INPUT_PASSTHROUGH);
}

}  // namespace

int main() {
    testKeypadCharTable();
    testNonKeypadCharKeySymsAreExcluded();
    testNormalizeKeypadInputMode();
    if (failures != 0) {
        std::cerr << failures << " failure(s)\n";
        return 1;
    }
    std::cout << "hazkey_keypad_input_test: all passed\n";
    return 0;
}

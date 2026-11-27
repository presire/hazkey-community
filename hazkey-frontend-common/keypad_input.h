/**
 * @file keypad_input.h
 * @brief テンキーの文字キー (0〜9 . + - * / = ,) の分類と、半角・全角の文字への変換を提供する
 *
 * Fcitx 5とIBusのキー値は、どちらもX11のkeysymと同じ値を使うため、keysymの数値で判定する
 * 文字の実体ではなくkeysymで決めるため、キーボード配列に依らず同じ文字になる
 * 全角はキーの印字どおりの文字 (－ ／ ． ，) で、メインキーのJapanese Symbolキーマップ (ー ・ 。 、) とは異なる
 *
 * @note Fcitx 5、IBus、GLibの型を使わない純粋関数のみを置く
 * @note NumLockがOFFのときのナビゲーションキー (KP_Home等)、KP_Enter、KP_Space、KP_Tab、KP_F1〜KP_F4は対象外
 */

#ifndef HAZKEY_KEYPAD_INPUT_H
#define HAZKEY_KEYPAD_INPUT_H

#include <cstdint>
#include <optional>
#include <string>

#include "config.pb.h"

namespace hazkey::frontend {

/**
 * @brief テンキーの文字キーかどうかを返す
 * @param keysym キーのkeysym (X11 / Fcitx 5 / IBusで共通の値)
 * @return KP_0〜KP_9、KP_Decimal、KP_Add、KP_Subtract、KP_Multiply、KP_Divide、KP_Equal、KP_Separatorならtrue
 */
bool isKeypadCharKeySym(uint32_t keysym);

/**
 * @brief テンキーの文字キーに対応する半角文字を返す
 * @param keysym キーのkeysym
 * @return 半角文字 (例: KP_1 → 1、KP_Subtract → -)、テンキーの文字キーでなければstd::nullopt
 */
std::optional<std::string> keypadHalfwidthChar(uint32_t keysym);

/**
 * @brief テンキーの文字キーに対応する全角文字を返す
 * @param keysym キーのkeysym
 * @return 全角文字 (例: KP_1 → １、KP_Subtract → －)、テンキーの文字キーでなければstd::nullopt
 */
std::optional<std::string> keypadFullwidthChar(uint32_t keysym);

/**
 * @brief 入力方法に従って、組成へ入力するテンキーの文字を返す
 * @param keysym キーのkeysym
 * @param mode テンキーの入力方法
 * @return HALFWIDTHなら半角文字、FULLWIDTHなら全角文字
 *         PASSTHROUGH・UNSPECIFIED・未知の値と、テンキーの文字キーでない場合はstd::nullopt
 */
std::optional<std::string> keypadCharForMode(
    uint32_t keysym, hazkey::config::Profile::KeypadInputMode mode);

/**
 * @brief プロファイルからテンキーの入力方法を読み出す
 * @param profile サーバから読み込んだプロファイル
 * @return HALFWIDTHまたはFULLWIDTHならその値
 *         フィールドが無い場合・UNSPECIFIED・未知の値はKEYPAD_INPUT_PASSTHROUGH
 */
hazkey::config::Profile::KeypadInputMode normalizeKeypadInputMode(
    const hazkey::config::Profile& profile);

}  // namespace hazkey::frontend

#endif  // HAZKEY_KEYPAD_INPUT_H

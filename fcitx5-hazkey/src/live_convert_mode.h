#ifndef _FCITX5_HAZKEY_LIVE_CONVERT_MODE_H_
#define _FCITX5_HAZKEY_LIVE_CONVERT_MODE_H_

#include "config.pb.h"

namespace fcitx {

/// ライブ変換ホットキーによる次の自動変換モードを計算する
/// @param current 現在の自動変換モード
/// @param remembered 無効化前のモードを保持する参照
/// @return 現在が無効なら記憶済みモード、それ以外なら無効モード
/// 有効モード同士を直接切り替えず、無効化前のモードを再有効化する
hazkey::config::Profile_AutoConvertMode computeNextAutoConvertMode(
    hazkey::config::Profile_AutoConvertMode current,
    hazkey::config::Profile_AutoConvertMode& remembered);

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_LIVE_CONVERT_MODE_H_

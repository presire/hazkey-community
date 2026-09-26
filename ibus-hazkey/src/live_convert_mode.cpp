/**
 * @file live_convert_mode.cpp
 * @brief ライブ変換トグル時の次回自動変換モード決定ロジックの実装
 *
 * 公開APIの仕様はヘッダ (live_convert_mode.h) を参照のこと
 */
#include "live_convert_mode.h"

/** @brief IBusフロントエンドのライブ変換トグルロジックの名前空間 */
namespace hazkey::ibus {

hazkey::config::Profile_AutoConvertMode computeNextAutoConvertMode(
    hazkey::config::Profile_AutoConvertMode current,
    hazkey::config::Profile_AutoConvertMode& remembered) {
    using M = hazkey::config::Profile_AutoConvertMode;
    if (current == M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED) {
        return remembered;
    }
    remembered = current;
    return M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED;
}

}  // namespace hazkey::ibus

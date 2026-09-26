#include "live_convert_mode.h"

namespace fcitx {

/// 無効化と最後に使った有効モードへの復帰を交互に計算する
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

}  // namespace fcitx

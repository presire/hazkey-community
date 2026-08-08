#include "live_convert_mode.h"

namespace fcitx {

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

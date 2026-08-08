#ifndef _FCITX5_HAZKEY_LIVE_CONVERT_MODE_H_
#define _FCITX5_HAZKEY_LIVE_CONVERT_MODE_H_

#include "config.pb.h"

namespace fcitx {

// Returns the next auto-convert mode when toggling live conversion via hotkey.
// - If current is DISABLED: returns `remembered` (the last non-DISABLED mode,
//   default ALWAYS).
// - Otherwise: sets `remembered = current` and returns DISABLED.
// The hotkey never switches ALWAYS<->FOR_MULTIPLE_CHARS directly; both are
// reachable from settings UI, and whichever was active is restored on
// toggle-on.
hazkey::config::Profile_AutoConvertMode computeNextAutoConvertMode(
    hazkey::config::Profile_AutoConvertMode current,
    hazkey::config::Profile_AutoConvertMode& remembered);

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_LIVE_CONVERT_MODE_H_

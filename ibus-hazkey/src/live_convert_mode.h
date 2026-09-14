#ifndef IBUS_HAZKEY_LIVE_CONVERT_MODE_H
#define IBUS_HAZKEY_LIVE_CONVERT_MODE_H

#include "config.pb.h"

namespace hazkey::ibus {

// Returns the next auto-convert mode when toggling live conversion via hotkey.
// - If current is DISABLED: returns `remembered` (the last non-DISABLED mode,
//   default ALWAYS).
// - Otherwise: sets `remembered = current` and returns DISABLED.
// The hotkey never switches ALWAYS<->FOR_MULTIPLE_CHARS directly; both are
// reachable from settings UI, and whichever was active is restored on
// toggle-on.
//
// Port of fcitx5-hazkey/src/live_convert_mode.cpp (namespace fcitx); the
// transition is frontend-independent (protobuf enum only), so the IBus
// frontend keeps its own copy in its own namespace rather than linking the
// fcitx addon module.
hazkey::config::Profile_AutoConvertMode computeNextAutoConvertMode(
    hazkey::config::Profile_AutoConvertMode current,
    hazkey::config::Profile_AutoConvertMode& remembered);

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_LIVE_CONVERT_MODE_H

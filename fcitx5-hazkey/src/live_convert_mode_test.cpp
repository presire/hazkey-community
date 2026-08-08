#include <cassert>
#include <iostream>

#include "config.pb.h"
#include "live_convert_mode.h"

using M = hazkey::config::Profile_AutoConvertMode;

int main() {
    // 1. DISABLED + remembered=ALWAYS -> returns ALWAYS, remembered unchanged
    {
        M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
        M result = fcitx::computeNextAutoConvertMode(
            M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED, remembered);
        assert(result == M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);
        assert(remembered == M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);
        std::cout << "[PASS] DISABLED + remembered=ALWAYS -> ALWAYS, "
                     "remembered unchanged\n";
    }

    // 2. ALWAYS + remembered=ALWAYS -> returns DISABLED, remembered becomes
    // ALWAYS
    {
        M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
        M result = fcitx::computeNextAutoConvertMode(
            M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS, remembered);
        assert(result == M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED);
        assert(remembered == M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);
        std::cout << "[PASS] ALWAYS + remembered=ALWAYS -> DISABLED, "
                     "remembered=ALWAYS\n";
    }

    // 3. FOR_MULTIPLE_CHARS + remembered=ALWAYS -> returns DISABLED,
    // remembered becomes FOR_MULTIPLE_CHARS
    {
        M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
        M result = fcitx::computeNextAutoConvertMode(
            M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS,
            remembered);
        assert(result == M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED);
        assert(remembered ==
               M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);
        std::cout << "[PASS] FOR_MULTIPLE_CHARS + remembered=ALWAYS -> DISABLED, "
                     "remembered=FOR_MULTIPLE_CHARS\n";
    }

    // 4. DISABLED + remembered=FOR_MULTIPLE_CHARS -> returns
    // FOR_MULTIPLE_CHARS, remembered unchanged
    {
        M remembered =
            M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;
        M result = fcitx::computeNextAutoConvertMode(
            M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED, remembered);
        assert(result ==
               M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);
        assert(remembered ==
               M::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS);
        std::cout << "[PASS] DISABLED + remembered=FOR_MULTIPLE_CHARS -> "
                     "FOR_MULTIPLE_CHARS, remembered unchanged\n";
    }

    std::cout << "\nAll 4 transitions passed.\n";
    return 0;
}

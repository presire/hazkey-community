#include <cassert>
#include <iostream>
#include "config.pb.h"
#include "live_convert_mode.h"

using M = hazkey::config::Profile_AutoConvertMode;

/** ライブ変換モードの切替と記憶状態の遷移を確認する */
int main() {
    /** [DISABLED]から記憶済みの[ALWAYS]へ復帰する動作を確認する */
    {
        M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
        M result = fcitx::computeNextAutoConvertMode(
            M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED, remembered);
        assert(result == M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);
        assert(remembered == M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);
        std::cout << "[PASS] DISABLED + remembered=ALWAYS -> ALWAYS, "
                     "remembered unchanged\n";
    }

    /** [ALWAYS]から無効化した際に復帰先を記憶する動作を確認する */
    {
        M remembered = M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS;
        M result = fcitx::computeNextAutoConvertMode(
            M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS, remembered);
        assert(result == M::Profile_AutoConvertMode_AUTO_CONVERT_DISABLED);
        assert(remembered == M::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS);
        std::cout << "[PASS] ALWAYS + remembered=ALWAYS -> DISABLED, "
                     "remembered=ALWAYS\n";
    }

    /** [FOR_MULTIPLE_CHARS]から無効化した際に現在モードを記憶する動作を確認する */
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

    /** 記憶済みの[FOR_MULTIPLE_CHARS]へ復帰する動作を確認する */
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

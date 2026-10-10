#ifndef HAZKEY_UTF8_H
#define HAZKEY_UTF8_H

#include <string>
#include <string_view>

namespace hazkey::frontend {

/**
 * @brief サーバから受け取った文字列を正しいUTF-8に修復する
 *
 * @details g_utf8_make_valid()と同じ規則で、正しいUTF-8はそのまま返し、
 *          不正なバイト (NULを含む) は1バイトごとにU+FFFDへ置き換えて次のバイトから復号を続ける
 *          GLibに依存しないため、Fcitx 5とIBusの両フロントエンドから使用することができる
 *
 * @param input 修復する文字列
 * @return 正しいUTF-8の文字列
 */
std::string makeValidUtf8(std::string_view input);

}

#endif

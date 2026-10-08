#ifndef IBUS_HAZKEY_UTF8_H
#define IBUS_HAZKEY_UTF8_H

#include <glib.h>
#include <memory>
#include <string>
#include <string_view>

namespace hazkey::ibus {

inline std::string makeValidUtf8(std::string_view text) {
    if (text.empty()) {
        return {};
    }
    const auto length = static_cast<gssize>(text.size());
    if (g_utf8_validate(text.data(), length, nullptr)) {
        return std::string(text);
    }
    std::unique_ptr<gchar, decltype(&g_free)> valid(
        g_utf8_make_valid(text.data(), length), &g_free);
    return std::string(valid.get());
}

}

#endif

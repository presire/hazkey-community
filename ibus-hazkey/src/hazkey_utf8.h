#ifndef IBUS_HAZKEY_UTF8_H
#define IBUS_HAZKEY_UTF8_H

#include <string>
#include <string_view>
#include "../../hazkey-frontend-common/hazkey_utf8.h"

namespace hazkey::ibus {

inline std::string makeValidUtf8(std::string_view input) {
    return hazkey::frontend::makeValidUtf8(input);
}

}

#endif

#ifndef _FCITX5_HAZKEY_HAZKEY_CONFIG_H_
#define _FCITX5_HAZKEY_HAZKEY_CONFIG_H_

#include <fcitx-config/configuration.h>
#include <fcitx-config/enum.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/library.h>
#include <fcitx/menu.h>

#include "hazkey_constants.h"

namespace fcitx {

/// Fcitx 5側のHazkey設定項目
FCITX_CONFIGURATION(HazkeyEngineConfig,
                    HiddenOption<std::string> lastVersion{
                        this, "LastVersion", "", ""};                             ///< 最後に起動したHazkeyバージョン
                    Option<bool> showTabToSelect{
                        this, "showTabToSelect",
                        _("Show [Press Tab to Select] indicator"), true};         ///< [Tab]キー選択案内の表示
                    ExternalOption openHazkeySettings{
                        this, "openHazkeySettings", _("Open Hazkey Community Settings"),
                        stringutils::concat("hazkey-community-settings")};);      ///< 設定画面の起動項目
}  // namespace fcitx
#endif  // _FCITX5_HAZKEY_HAZKEY_CONFIG_H_

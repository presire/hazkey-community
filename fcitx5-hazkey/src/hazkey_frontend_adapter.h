#ifndef _FCITX5_HAZKEY_HAZKEY_FRONTEND_ADAPTER_H_
#define _FCITX5_HAZKEY_HAZKEY_FRONTEND_ADAPTER_H_

#include <fcitx/text.h>

#include "hazkey_frontend_hooks.h"

namespace fcitx {

// Installs the fcitx5 log sink (FCITX_DEBUG/INFO/WARN/ERROR) and the
// fcitx::startProcess-based server spawner into the shared transport. Must run
// before the first HazkeyServerConnector is constructed: the connector may
// spawn hazkey-server while connecting.
void installHazkeyFrontendHooks();

// Guard member: default-construction installs the hooks. Declare an instance
// BEFORE any HazkeyServerConnector member so member-initialization order (not
// the initializer list) guarantees the hooks are in place first.
class HazkeyFrontendHooksGuard {
   public:
    HazkeyFrontendHooksGuard() { installHazkeyFrontendHooks(); }
};

// Converts the neutral transport result into an underlined fcitx::Text, where
// the underline marks the cursor character. The transport carries no fcitx
// dependency; this is the fcitx-side presentation adapter.
Text composingTextWithCursorToFcitxText(
    const hazkey::frontend::ComposingTextWithCursor& parts);

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_HAZKEY_FRONTEND_ADAPTER_H_

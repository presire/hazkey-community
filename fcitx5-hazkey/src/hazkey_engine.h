#ifndef _FCITX5_HAZKEY_HAZKEY_ENGINE_H_
#define _FCITX5_HAZKEY_HAZKEY_ENGINE_H_

#include <fcitx-config/iniparser.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>
#include <iconv.h>

#include "hazkey_config.h"
#include "hazkey_frontend_adapter.h"
#include "hazkey_server_connector.h"
#include "hazkey_state.h"

namespace fcitx {

class HazkeyEngine : public InputMethodEngineV2 {
   public:
    // constructor
    HazkeyEngine(Instance *instance);

    // handle key event and pass it to HazkeyState
    void keyEvent(const InputMethodEntry &entry, KeyEvent &keyEvent) override;

    // called when input method changes to Hazkey
    void activate(const InputMethodEntry &, InputContextEvent &) override;

    // called when input method changes to another input method
    void deactivate(const InputMethodEntry &, InputContextEvent &) override;

    // called when the input context needs its state reset (InputContextReset,
    // e.g. an application- or framework-initiated reset). Without this override
    // the inherited InputMethodEngine::reset() is a no-op, so HazkeyState (and
    // the pending coalesced candidate refresh timer) would survive the reset and
    // a stale callback could repaint the input panel afterwards.
    void reset(const InputMethodEntry &, InputContextEvent &) override;

    auto factory() const { return &factory_; }
    auto instance() const { return instance_; }

    // Return a reference (not a copy) so callers can bind to member
    // references safely. The previous `auto server() const` returned by
    // value, which made expressions like
    //   auto& r = engine_->server().rememberedOnMode();
    // bind to a destroyed temporary — undefined behavior (dangling pointer).
    HazkeyServerConnector& server() { return server_; }
    const HazkeyServerConnector& server() const { return server_; }

    const Configuration *getConfig() const override { return &config_; }
    void setConfig(const RawConfig &config) override;
    void reloadConfig() override;

    void save() override;

    const HazkeyEngineConfig &config() const { return config_; }

   private:
    HazkeyEngineConfig config_;
    Instance *instance_;
    FactoryFor<HazkeyState> factory_;
    // Declared before server_ on purpose: member-initialization order follows
    // declaration order, so this installs the fcitx frontend hooks (log sink +
    // server spawner) before HazkeyServerConnector is constructed.
    HazkeyFrontendHooksGuard frontendHooksGuard_;
    HazkeyServerConnector server_;
    iconv_t conv_;
};

class HazkeyEngineFactory : public AddonFactory {
    AddonInstance *create(AddonManager *manager) override {
        return new HazkeyEngine(manager->instance());
    }
};

}  // namespace fcitx
#endif  // _FCITX5_HAZKEY_HAZKEY_ENGINE_H_

#include "hazkey_engine.h"

#include <fcitx-utils/macros.h>

#include "hazkey_server_connector.h"
#include "hazkey_state.h"
#include "hazkey_constants.h"

namespace fcitx {

namespace {

/// 表示中のpreeditがあるかをクライアント能力に応じて判定する
bool hasVisiblePreedit(InputContext *inputContext) {
    const auto &inputPanel = inputContext->inputPanel();
    if (inputContext->capabilityFlags().test(CapabilityFlag::Preedit)) {
        return !inputPanel.clientPreedit().toString().empty();
    }
    return !inputPanel.preedit().toString().empty();
}

}  // namespace

/// プロパティを登録し、初期設定を読み込む
HazkeyEngine::HazkeyEngine(Instance *instance)
    : instance_(instance), factory_([this](InputContext &ic) {
          return new HazkeyState(this, &ic);
      }) {
    // server_はメンバ初期化時にデフォルトコンストラクターで接続済み
    // 以前のserver_代入では、接続器をもう1つ生成して、fdを浅く代入して接続をリークしていた
    // 現在は接続器がfdを所有するためコピーできず、該当代入は削除済み
    instance->inputContextManager().registerProperty("hazkeyCommunityState", &factory_);
    reloadConfig();
}

/// キーイベントを状態機械へ渡し、入力パネルを更新する
void HazkeyEngine::keyEvent([[maybe_unused]] const InputMethodEntry &entry,
                            KeyEvent &keyEvent) {
    FCITX_DEBUG() << "keyEvent: " << keyEvent.key().toString();

    auto inputContext = keyEvent.inputContext();
    inputContext->propertyFor(&factory_)->keyEvent(keyEvent);
    if (keyEvent.accepted()) {
        inputContext->updatePreedit();
    }
    inputContext->updateUserInterface(UserInterfaceComponent::InputPanel);
}

/// 有効化時に状態とプロファイルキャッシュを初期化する
void HazkeyEngine::activate([[maybe_unused]] const InputMethodEntry &entry,
                            InputContextEvent &event) {
    FCITX_DEBUG() << &entry;
    FCITX_DEBUG() << "HazkeyEngine activate";
    auto inputContext = event.inputContext();
    auto state = inputContext->propertyFor(&factory_);
    state->reset();
    state->invalidateServerProfile();
    inputContext->updateUserInterface(UserInterfaceComponent::InputPanel);
}

/// 無効化時に表示中のpreeditを確定して状態を消去する
void HazkeyEngine::deactivate([[maybe_unused]] const InputMethodEntry &entry,
                              InputContextEvent &event) {
    FCITX_DEBUG() << "HazkeyEngine deactivate";
    auto inputContext = event.inputContext();
    auto state = inputContext->propertyFor(&factory_);
    bool hadVisiblePreedit = hasVisiblePreedit(inputContext);

    if (hadVisiblePreedit) {
        state->commitPreedit();
    }

    state->reset();

    if (hadVisiblePreedit) {
        inputContext->updatePreedit();
    }

    inputContext->updateUserInterface(UserInterfaceComponent::InputPanel);
}

/// リセット要求時に入力状態と表示を整合させる
void HazkeyEngine::reset([[maybe_unused]] const InputMethodEntry &entry,
                         InputContextEvent &event) {
    FCITX_DEBUG() << "HazkeyEngine reset";
    auto inputContext = event.inputContext();
    auto state = inputContext->propertyFor(&factory_);

    // KeyboardEngine::reset()とIBus側のreset() vfuncに合わせて組成を消去して、保留中の集約更新も明示的に取り消してリセット後の古い描画を防ぐ
    // preedit更新は表示中の文字列がある場合に限る
    // activate() / deactivate()と同じく空の更新で他のクライアント入力を消さない
    bool hadVisiblePreedit = hasVisiblePreedit(inputContext);

    state->reset();

    if (hadVisiblePreedit) {
        inputContext->updatePreedit();
    }

    inputContext->updateUserInterface(UserInterfaceComponent::InputPanel);
}

/// 新しい生設定を適用して保存する
void HazkeyEngine::setConfig(const RawConfig &config) {
    config_.load(config, true);
    safeSaveAsIni(config_, "conf/hazkey-community.conf");
    reloadConfig();
}

/// 設定を再読込して、バージョン変更を検出した場合はサーバを再起動する
void HazkeyEngine::reloadConfig() {
    readAsIni(config_, "conf/hazkey-community.conf");

    std::string lastVersion = config_.lastVersion.value();

    if (lastVersion != HAZKEY_VERSION) {
        FCITX_DEBUG() << "Update detected. restarting server..";
        server_.startHazkeyServer(true);

        config_.lastVersion.setValue(HAZKEY_VERSION);
        safeSaveAsIni(config_, "conf/hazkey-community.conf");
    }
}

/// Fcitx終了時の学習データ保存を依頼する
void HazkeyEngine::save() {
    server_.saveLearningData();
}

FCITX_ADDON_FACTORY(HazkeyEngineFactory);

}  // namespace fcitx

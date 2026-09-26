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

/// Fcitx 5からのイベントを入力状態とサーバへ橋渡しするエンジン
class HazkeyEngine : public InputMethodEngineV2 {
   public:
    /// インスタンスにエンジンを登録して、設定を読み込む
    HazkeyEngine(Instance *instance);

    /// キーイベントを対応する入力コンテキスト状態へ配送する
    void keyEvent(const InputMethodEntry &entry, KeyEvent &keyEvent) override;

    /// 入力メソッドが有効になった時の状態を初期化する
    void activate(const InputMethodEntry &, InputContextEvent &) override;

    /// 入力メソッドが無効になる前に、未確定文字列を確定する
    void deactivate(const InputMethodEntry &, InputContextEvent &) override;

    /// Fcitx 5からのリセット要求に応じて、入力状態を消去する
    void reset(const InputMethodEntry &, InputContextEvent &) override;

    /// 入力コンテキスト状態のプロパティ生成ファクトリを返す
    auto factory() const { return &factory_; }
    /// このエンジンが登録されたFcitxインスタンスを返す
    auto instance() const { return instance_; }

    /// サーバ接続への変更可能な参照を返す
    HazkeyServerConnector& server() { return server_; }
    /// サーバ接続への読み取り専用参照を返す
    const HazkeyServerConnector& server() const { return server_; }

    /// Fcitx設定オブジェクトを返す
    const Configuration *getConfig() const override { return &config_; }
    /// 生設定値を読み込み、設定を再読込する
    void setConfig(const RawConfig &config) override;
    /// 設定ファイルを読み込み、必要ならサーバを再起動する
    void reloadConfig() override;

    /// 学習データの保存をサーバへ依頼する
    void save() override;

    /// 現在のエンジン設定を返す
    const HazkeyEngineConfig &config() const { return config_; }

   private:
    HazkeyEngineConfig config_;                     ///< Fcitx設定値
    Instance *instance_;                            ///< 登録先のFcitxインスタンス
    FactoryFor<HazkeyState> factory_;               ///< 入力コンテキストごとの状態生成器

    // メンバー初期化順は宣言順のためserver_より前に宣言する
    // HazkeyServerConnectorの生成前にFcitxフック（ログ出力とサーバ起動）を登録する
    HazkeyFrontendHooksGuard frontendHooksGuard_;   ///< 共通transport用fcitxフック
    HazkeyServerConnector server_;                  ///< サーバ通信接続
    iconv_t conv_;                                  ///< 予約済み文字コード変換ハンドル
};

/// Fcitx 5アドオンマネージャー向けエンジン生成器
class HazkeyEngineFactory : public AddonFactory {
    /// マネージャーのインスタンスに対応するエンジンを生成する
    AddonInstance *create(AddonManager *manager) override {
        return new HazkeyEngine(manager->instance());
    }
};

}  // namespace fcitx
#endif  // _FCITX5_HAZKEY_HAZKEY_ENGINE_H_

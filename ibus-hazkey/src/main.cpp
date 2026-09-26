#include <ibus.h>
#include <glib.h>
#include "engine_description.h"
#include "hazkey_engine.h"
#include "hazkey_frontend.h"
#include "hazkey_frontend_glib.h"
#include <cstring>
#include <locale.h>

/**
 * @file main.cpp
 * @brief IBusエンジンプロセスの起動処理を定義する
 *
 * エンジンファクトリの型定義とバス接続・名前確保を行い、--xml照会への応答とGLibメインループによる常駐実行を担う
 */

namespace {

/** @brief IBusに登録するエンジン名 */
constexpr const char* kEngineName = "hazkey-community";
/** @brief コンポーネントが確保するバス名 */
constexpr const char* kComponentBusName = "org.freedesktop.IBus.HazkeyCommunity";


/** @brief エンジンファクトリ実体型の別名 */
typedef struct _IBusHazkeyFactory IBusHazkeyFactory;
/** @brief エンジンファクトリクラス型の別名 */
typedef struct _IBusHazkeyFactoryClass IBusHazkeyFactoryClass;

/**
 * @brief Hazkeyエンジンを生成するファクトリの実体構造体
 *
 * IBusFactoryを継承し、追加の実体変数は持たない
 */
struct _IBusHazkeyFactory {
    IBusFactory parent;  ///< 親クラス
                         ///< GObjectの規約により先頭に置く
};

/**
 * @brief Hazkeyエンジンを生成するファクトリのクラス構造体
 *
 * IBusFactoryClassを継承し、追加のクラス変数は持たない
 */
struct _IBusHazkeyFactoryClass {
    IBusFactoryClass parent;  ///< 親クラス
                              ///< GObjectの規約により先頭に置く
};

G_DEFINE_TYPE(IBusHazkeyFactory, ibus_hazkey_factory, IBUS_TYPE_FACTORY)

/** @brief ファクトリ型を示す型マクロ */
#define IBUS_TYPE_HAZKEY_FACTORY (ibus_hazkey_factory_get_type())

/**
 * @brief ファクトリクラスの初期化を受け付ける
 *
 * 追加のクラス初期化は不要のため何も行わない
 *
 * @param factoryClass 初期化対象のファクトリクラス
 */
static void ibus_hazkey_factory_class_init(
    [[maybe_unused]] IBusHazkeyFactoryClass* factoryClass) {}

/**
 * @brief ファクトリへHazkeyエンジンを登録する
 *
 * エンジン名とエンジン型をIBusFactoryへ追加する
 *
 * @param factory 初期化対象のファクトリ実体
 */
static void ibus_hazkey_factory_init(IBusHazkeyFactory* factory) {
    ibus_factory_add_engine(IBUS_FACTORY(factory), kEngineName,
                            IBUS_TYPE_HAZKEY_ENGINE);
}

/**
 * @brief ファクトリ実体を生成する
 *
 * オブジェクトパスと接続を指定してGObjectを生成する
 *
 * @param connection 利用するD-Bus接続
 * @return 生成したファクトリ
 */
static IBusFactory* ibusHazkeyFactoryNew(GDBusConnection* connection) {
    return IBUS_FACTORY(g_object_new(IBUS_TYPE_HAZKEY_FACTORY, "object-path",
                                     IBUS_PATH_FACTORY, "connection", connection,
                                     nullptr));
}

/**
 * @brief バス切断時にメインループを終了する
 *
 * 切断後は常駐を続けられないため、ibus_quitで終了する
 *
 * @param bus 切断されたバス
 * @param userData 未使用の利用者データ
 */
static void onBusDisconnected([[maybe_unused]] IBusBus* bus,
                              [[maybe_unused]] gpointer userData) {
    g_debug("hazkey: disconnected from IBus");
    ibus_quit();
}

}  // namespace

/**
 * @brief IBusエンジンプロセスを起動する
 *
 * ロケールを初期化して翻訳を有効化してから、--xml指定時はエンジン記述XMLを出力して終了する
 * バスへ接続してコンポーネント名を確保し、所有者になれた場合のみGLibメインループで常駐する
 * 0以外の名前応答は成功とは限らず、所有者になれない応答では終了する
 * 終了時は共有ワーカーの合流を待ってからファクトリとバスの参照を解放する
 * setlocaleによるロケール初期化は、状態表示とパネル文言の日本語化のために必須であり、無い場合は英語のmsgidにフォールバックする
 *
 * @param argc コマンドライン引数の個数
 * @param argv コマンドライン引数の配列
 * @return 正常終了時は0、接続や名前確保に失敗した場合は1
 */
int main(int argc, char* argv[]) {
    // hazkey_state.cpp の g_dgettext("ibus-hazkey-community", ...) と、パネル側の<longname>/<description> のdgettextが日本語を返すために必要
    // これが無い場合、gettextは常に英語のmsgidにフォールバックする
    setlocale(LC_ALL, "");
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--xml") == 0) {
            g_print("%s", hazkey::ibus::kEngineDescriptionXml);
            return 0;
        }
    }

    ibus_init();

    IBusBus* bus = ibus_bus_new();
    if (bus != nullptr) {
        g_object_ref_sink(bus);
    }
    if (bus == nullptr || !ibus_bus_is_connected(bus)) {
        g_warning("hazkey: unable to connect to IBus");
        if (bus != nullptr) {
            g_object_unref(bus);
        }
        return 1;
    }

    g_signal_connect(bus, "disconnected", G_CALLBACK(onBusDisconnected), nullptr);
    hazkey::ibus::installGlibFrontendHooks();

    IBusFactory* factory = ibusHazkeyFactoryNew(ibus_bus_get_connection(bus));
    const guint32 result = ibus_bus_request_name(
        bus, kComponentBusName,
        IBUS_BUS_NAME_FLAG_REPLACE_EXISTING | IBUS_BUS_NAME_FLAG_ALLOW_REPLACEMENT);
    // 非ゼロの応答は必ずしも成功ではない
    // IN_QUEUE / EXISTSは、このプロセスがコンポーネント名を所有していないことを意味するため、所有者の場合だけ続行する
    if (result != IBUS_BUS_REQUEST_NAME_REPLY_PRIMARY_OWNER && result != IBUS_BUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        g_warning("hazkey: unable to acquire IBus component name (reply %u)", result);
        g_object_unref(factory);
        g_object_unref(bus);
        return 1;
    }

    ibus_main();

    // プロセスが、関数staticなフック / コネクタを解体する前に非同期ワーカーへ合流する (shutdownSharedExecutor()参照)
    hazkey::ibus::shutdownSharedExecutor();

    g_object_unref(factory);
    g_object_unref(bus);
    return 0;
}

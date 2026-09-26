#include "hazkey_engine.h"
#include <memory>
#include "hazkey_frontend.h"
#include "hazkey_frontend_glib.h"

/**
 * @file hazkey_engine.cpp
 * @brief IBusエンジンGObjectとvfunc振分けを実装する
 *
 * 公開APIの仕様はヘッダ (hazkey_engine.h) を参照のこと
 */

typedef struct _IBusHazkeyEngine IBusHazkeyEngine;
typedef struct _IBusHazkeyEngineClass IBusHazkeyEngineClass;

/**
 * @brief Hazkey入力エンジンのインスタンス構造体
 *
 * IBusEngineSimpleを継承し、入力ファサードの共有所有を間接保持する
 * GObjectインスタンスはC++コンストラクタを実行せずに確保されるため、非自明なメンバを直接置くことはできない
 * ファサードは共有されており、ワーカータスクが終了まで寿命を延ばせる (HazkeyFrontend参照)
 */
struct _IBusHazkeyEngine {
    IBusEngineSimple parent;                                  ///< 親クラス。GObjectの規約により先頭に置く
    std::shared_ptr<hazkey::ibus::HazkeyFrontend>* frontend;  ///< 入力ファサード共有所有へのポインタ。GObject確保方式のため間接保持する
};

/**
 * @brief Hazkey入力エンジンのクラス構造体
 *
 * IBusEngineSimpleClassを継承し、追加のクラス変数は持たない
 */
struct _IBusHazkeyEngineClass {
    IBusEngineSimpleClass parent;  ///< 親クラス。GObjectの規約により先頭に置く
};

G_DEFINE_TYPE(IBusHazkeyEngine, ibus_hazkey_engine, IBUS_TYPE_ENGINE_SIMPLE)

namespace {
/**
 * @brief エンジンから入力ファサードを取り出す
 *
 * @param engine 処理対象のエンジン
 * @return ファサードへのポインタ、未生成時はnullptr
 */
hazkey::ibus::HazkeyFrontend* frontendOf(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->frontend == nullptr) {
        return nullptr;
    }
    return hazkeyEngine->frontend->get();
}
}  // namespace

/**
 * @brief キーイベントをファサードへ振り分ける
 *
 * ファサード未生成時は未処理としてFALSEを返す
 *
 * @param engine 処理対象のエンジン
 * @param keyval キーシンボル
 * @param keycode ハードウェアキーコード
 * @param state 修飾子の状態
 * @return 消費した場合はTRUE、未処理の場合はFALSE
 */
static gboolean ibusHazkeyEngineProcessKeyEvent(IBusEngine* engine,
                                                guint keyval, guint keycode,
                                                guint state) {
    auto* frontend = frontendOf(engine);
    if (frontend == nullptr) {
        return FALSE;
    }
    return frontend->processKeyEvent(keyval, keycode, state);
}

/**
 * @brief フォーカス取得をファサードへ通知する
 *
 * ファサードへfocusInを送った後に親クラスのfocus_inへ連鎖する
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineFocusIn(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->focusIn();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->focus_in != nullptr) {
        parent->focus_in(engine);
    }
}

/**
 * @brief フォーカス喪失をファサードへ通知する
 *
 * ファサードへfocusOutを送った後に親クラスのfocus_outへ連鎖する
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineFocusOut(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->focusOut();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->focus_out != nullptr) {
        parent->focus_out(engine);
    }
}

/**
 * @brief 入力状態のリセットをファサードへ通知する
 *
 * ファサードへresetを送った後に親クラスのresetへ連鎖する
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineReset(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->reset();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->reset != nullptr) {
        parent->reset(engine);
    }
}

/**
 * @brief エンジン有効化をファサードへ通知する
 *
 * ファサードへenableを送った後に親クラスのenableへ連鎖する
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineEnable(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->enable();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->enable != nullptr) {
        parent->enable(engine);
    }
}

/**
 * @brief クライアント機能通知をファサードへ伝える
 *
 * ファサードへsetCapabilitiesを送った後に親クラスのset_capabilitiesへ連鎖する
 *
 * @param engine 処理対象のエンジン
 * @param caps クライアントが申告した機能フラグ
 */
static void ibusHazkeyEngineSetCapabilities(IBusEngine* engine, guint caps) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->setCapabilities(caps);
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_capabilities != nullptr) {
        parent->set_capabilities(engine, caps);
    }
}

/**
 * @brief パネル操作をファサード優先で処理する
 *
 * ファサードが処理した場合は親へ委譲せず、未処理の場合だけ親クラスのproperty_activateへ連鎖する
 *
 * @param engine 処理対象のエンジン
 * @param propName 操作対象のプロパティ名
 * @param propState プロパティの状態値
 */
static void ibusHazkeyEnginePropertyActivate(IBusEngine* engine,
                                             const gchar* propName,
                                             guint propState) {
    auto* frontend = frontendOf(engine);
    const bool handled =
        frontend != nullptr && frontend->activateProperty(propName, propState);
    if (!handled) {
        IBusEngineClass* parent =
            IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
        if (parent->property_activate != nullptr) {
            parent->property_activate(engine, propName, propState);
        }
    }
}

/**
 * @brief エンジン無効化をファサードへ通知する
 *
 * ファサードへdisableを送った後に親クラスのdisableへ連鎖する
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineDisable(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->disable();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->disable != nullptr) {
        parent->disable(engine);
    }
}

/**
 * @brief カーソル位置通知をファサードへ伝える
 *
 * ファサードへsetCursorLocationを送った後に親クラスのset_cursor_locationへ連鎖する
 *
 * @param engine 処理対象のエンジン
 * @param x カーソル矩形のX座標
 * @param y カーソル矩形のY座標
 * @param width カーソル矩形の幅
 * @param height カーソル矩形の高さ
 */
static void ibusHazkeyEngineSetCursorLocation(IBusEngine* engine, gint x,
                                              gint y, gint width, gint height) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->setCursorLocation(x, y, width, height);
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_cursor_location != nullptr) {
        parent->set_cursor_location(engine, x, y, width, height);
    }
}

/**
 * @brief 周囲テキスト通知を両方の保持先へ同期する
 *
 * 自前のフロントエンドはテキストを単なる文字列に複写して保持するため、IBus側が持つ周囲テキストのキャッシュも同期させる
 * IBus側はテキストをg_object_ref_sink経由で所有する
 *
 * @param engine 処理対象のエンジン
 * @param text 周囲テキスト
 * @param cursorIndex カーソル位置
 * @param anchorPos アンカー位置
 * @note 自前保持は文字列複写のためIBus_engine_get_surrounding_textとdelete_surrounding_textにしか影響しない
 */
static void ibusHazkeyEngineSetSurroundingText(IBusEngine* engine,
                                               IBusText* text,
                                               guint cursorIndex,
                                               guint anchorPos) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->setSurroundingText(text, cursorIndex, anchorPos);
    }
    // IBus側が持つ周囲テキストのキャッシュも同期させる (IBus側はテキストをg_object_ref_sink経由で所有する)
    // 自前のfrontendは、テキストを単なる文字列に複写して保持するため、ここはIBus_engine_get_surrounding_text()/delete_surrounding_text()にしか影響しない
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_surrounding_text != nullptr) {
        parent->set_surrounding_text(engine, text, cursorIndex, anchorPos);
    }
}

/**
 * @brief 候補ページ上移動をファサードへ通知する
 *
 * 親クラスへの連鎖は行わず、ファサードへの転送だけを行う
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEnginePageUp(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->pageUp();
    }
}

/**
 * @brief 候補ページ下移動をファサードへ通知する
 *
 * 親クラスへの連鎖は行わず、ファサードへの転送だけを行う
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEnginePageDown(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->pageDown();
    }
}

/**
 * @brief 候補カーソル上移動をファサードへ通知する
 *
 * 親クラスへの連鎖は行わず、ファサードへの転送だけを行う
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineCursorUp(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->cursorUp();
    }
}

/**
 * @brief 候補カーソル下移動をファサードへ通知する
 *
 * 親クラスへの連鎖は行わず、ファサードへの転送だけを行う
 *
 * @param engine 処理対象のエンジン
 */
static void ibusHazkeyEngineCursorDown(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->cursorDown();
    }
}

/**
 * @brief 候補クリックをファサードへ通知する
 *
 * 親クラスへの連鎖は行わず、ファサードへの転送だけを行う
 *
 * @param engine 処理対象のエンジン
 * @param index 選択された候補の索引
 * @param button 押下されたマウスボタン
 * @param state 修飾子の状態
 */
static void ibusHazkeyEngineCandidateClicked(IBusEngine* engine, guint index,
                                             guint button, guint state) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->candidateClicked(index, button, state);
    }
}

/**
 * @brief エンジン破棄時にファサード所有資源を解放する
 *
 * engineのファイナライズ前に、この (メイン) スレッド上でレンダラが所有するIBusとGObjectを全て解放する
 * ファサードとstateを掴んだままのワーカータスクは、UIが破棄済みのため無害に終了する
 * 解放後に親クラスのdestroyへ連鎖する
 *
 * @param object 破棄対象のオブジェクト
 */
static void ibusHazkeyEngineDestroy(IBusObject* object) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(object);
    if (hazkeyEngine->frontend != nullptr) {
        // engineのファイナライズ前に、この (メイン) スレッド上でレンダラが所有するIBus / GObjectを全て解放する
        // ファサード / stateを掴んだままのワーカータスクは、UIが破棄済みのため無害に終了する
        hazkeyEngine->frontend->get()->retire();
        delete hazkeyEngine->frontend;
        hazkeyEngine->frontend = nullptr;
    }
    IBUS_OBJECT_CLASS(ibus_hazkey_engine_parent_class)->destroy(object);
}

/**
 * @brief エンジンクラスのvfuncテーブルを登録する
 *
 * 各IBusEngine仮想関数へ本ファイルのシムを割り当て、IBusObjectのdestroyを上書きする
 *
 * @param engineClass 初期化対象のエンジンクラス
 */
static void ibus_hazkey_engine_class_init(IBusHazkeyEngineClass* engineClass) {
    IBusEngineClass* engine = IBUS_ENGINE_CLASS(engineClass);
    engine->process_key_event = ibusHazkeyEngineProcessKeyEvent;
    engine->focus_in = ibusHazkeyEngineFocusIn;
    engine->focus_out = ibusHazkeyEngineFocusOut;
    engine->reset = ibusHazkeyEngineReset;
    engine->enable = ibusHazkeyEngineEnable;
    engine->disable = ibusHazkeyEngineDisable;
    engine->set_capabilities = ibusHazkeyEngineSetCapabilities;
    engine->property_activate = ibusHazkeyEnginePropertyActivate;
    engine->set_cursor_location = ibusHazkeyEngineSetCursorLocation;
    engine->set_surrounding_text = ibusHazkeyEngineSetSurroundingText;
    engine->page_up = ibusHazkeyEnginePageUp;
    engine->page_down = ibusHazkeyEnginePageDown;
    engine->cursor_up = ibusHazkeyEngineCursorUp;
    engine->cursor_down = ibusHazkeyEngineCursorDown;
    engine->candidate_clicked = ibusHazkeyEngineCandidateClicked;
    IBusObjectClass* objectClass = IBUS_OBJECT_CLASS(engineClass);
    objectClass->destroy = ibusHazkeyEngineDestroy;
}

/**
 * @brief エンジン実体を初期化してファサードを生成する
 *
 * GLib用フックを導入してから入力ファサードの共有所有を生成し、エンジンに結び付ける
 *
 * @param engine 初期化対象のエンジン実体
 */
static void ibus_hazkey_engine_init(IBusHazkeyEngine* engine) {
    hazkey::ibus::installGlibFrontendHooks();
    engine->frontend = new std::shared_ptr<hazkey::ibus::HazkeyFrontend>(
        std::make_shared<hazkey::ibus::HazkeyFrontend>(IBUS_ENGINE(engine)));
    g_debug("hazkey: IBus engine initialized");
}

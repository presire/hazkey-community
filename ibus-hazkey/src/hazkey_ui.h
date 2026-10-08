#ifndef IBUS_HAZKEY_HAZKEY_UI_H
#define IBUS_HAZKEY_HAZKEY_UI_H

/**
 * @file hazkey_ui.h
 * @brief IBus入力コンテキスト向けのメインループ専用描画クラスを宣言する
 *
 * ワーカースレッドで動作する入力状態機械 (HazkeyState) と対になり、IBus / GObjectに触れる描画処理だけをGLibメインループ上で実行する
 */

#include <ibus.h>
#include <cstdint>
#include <string>
#include <vector>

/** @brief IBusフロントエンドの描画と入力状態を担う名前空間 */
namespace hazkey::ibus {

/**
 * @brief 候補テーブルへ渡す1件の候補
 *
 * 確定・preeditには表記 (text) だけを使い、注記は表示にだけ付ける
 */
struct LookupCandidate {
    std::string text;               ///< 候補の表記
    bool isTypoCorrection = false;  ///< 誤字の訂正候補なら、true
};

/**
 * @brief 候補テーブルに表示する文字列と注記の文字範囲
 *
 * annotationStart == annotationEnd のときは注記なしである
 */
struct LookupDisplayText {
    std::string text;           ///< 表示文字列 (表記、訂正候補は位置揃えの空白・全角空白2個・注記を連結)
    glong annotationStart = 0;  ///< 注記の開始位置 (UTF-8文字数)
    glong annotationEnd = 0;    ///< 注記の終了位置 (UTF-8文字数、排他的)
};

/**
 * @brief 候補テーブルの表示文字列を組み立てる
 *
 * 訂正候補は「表記 + 位置揃えの空白 + 全角空白2個 + 注記」とし、注記部分の文字範囲を返す
 * 通常候補、または注記が空の場合は表記をそのまま返す
 *
 * @param text 候補の表記
 * @param isTypoCorrection 誤字の訂正候補なら、true
 * @param annotation 注記 (翻訳済みの「*[訂正]*」)
 * @param annotationAlignColumns 注記の位置を揃える表記の表示桁数 (一覧内の訂正候補の表記の最大桁数)
 * @return 表示文字列と注記の文字範囲
 */
LookupDisplayText lookupDisplayText(const std::string& text,
                                    bool isTypoCorrection,
                                    const std::string& annotation,
                                    int annotationAlignColumns = 0);

/**
 * @class HazkeyUi
 * @brief 1つのIBus入力コンテキストに対するメインループ専用の描画エンドポイント
 *
 * 入力状態機械 (HazkeyState) はワーカースレッドで動作するため、遅いhazkey-serverがprocess_key_eventをブロックすることはない
 * IBus/GObjectの状態に触れる処理は全てこちら側に置く
 * 全てのメソッドは、hazkey::frontend::postToMainLoop()経由でGLibメインループ上 (エンジンを所有するスレッド) で呼び出さなければならない
 *
 * 候補テーブルの数字ラベルは表示中のIBusページ内でのローカル番号である
 * HazkeyStateとフロントエンド側のラダーが"shared_ptr<HazkeyUi>"を保持するため、投稿済みクロージャが参照している間はこのオブジェクト自体が解放されることはない
 * 保持する素のIBus/GObjectポインタは、メインループ上のretire()で解放しなければならず、漏れた場合は~HazkeyUiが警告するがunrefしてはならない
 */
class HazkeyUi {
   public:
    /**
     * @brief 描画対象のエンジンに結び付けられた描画エンドポイントを構築する
     * @param engine 描画先のIBusエンジン (HazkeyUiより長く生存する必要がある)
     */
    explicit HazkeyUi(IBusEngine* engine);
    /**
     * @brief 保持するIBusオブジェクトの解放漏れを警告して破棄する
     * @note 解放自体は、retire() (メインループ) が担当し、ここではunrefしない
     *       最後のshared_ptrがワーカースレッド上で解放される可能性があるためである
     */
    ~HazkeyUi();
    /** @brief コピー構築を禁止する (IBusオブジェクトの所有権を単一に保つ) */
    HazkeyUi(const HazkeyUi&) = delete;
    /** @brief コピー代入を禁止する (IBusオブジェクトの所有権を単一に保つ) */
    HazkeyUi& operator=(const HazkeyUi&) = delete;

    /**
     * @brief 保持する全てのIBus/GObjectを解放して描画を無効化する
     * @note メインループ専用であり、何度呼んでも安全である
     *       実行後は全ての描画メソッドがNOPになる
     */
    void retire();

    /**
     * @brief 安全入力の状態を設定する
     *
     * 安全入力中は確定・preedit・候補・補助テキストの表示と周辺テキストの要求をNOPにし、
     * 切替より前にワーカーが投稿した描画を安全入力欄へ出さない
     * 有効化時は表示中のpreedit・候補・補助テキストを即座に隠す
     *
     * @param secure 安全入力なら、true
     * @note メインループ専用である
     */
    void setSecureInput(bool secure);

    /**
     * @brief ハイライト/下線付き区間を1つ持つpreeditを表示する
     *
     * 候補モードでは変換対象区間を示し、subHiraganaが空の場合は文字列全体を選択する
     *
     * @param text 表示するpreedit文字列
     * @param selectionLen ハイライト/下線を付ける先頭からの文字数 (UTF-8文字数)
     * @note カーソルは0に固定する
     */
    void updatePreeditSelection(const std::string& text, glong selectionLen);
    /**
     * @brief 下線範囲とカーソル位置を明示した装飾なしpreeditを表示する
     * @param text 表示するpreedit文字列
     * @param startChar 下線開始位置 (文字数単位)
     * @param endChar 下線終了位置 (文字数単位)
     * @param cursorChar カーソル位置 (文字数単位)
     */
    void updatePreeditRange(const std::string& text, glong startChar,
                            glong endChar, guint cursorChar);
    /**
     * @brief 文字列全体をハイライトするpreeditを表示する
     * @param text 表示するpreedit文字列
     * @note 直接変換 ([F6]〜[F10]キー向け) で用いる
     */
    void updatePreeditHighlighted(const std::string& text);
    /** @brief preedit表示を隠す */
    void hidePreedit();
    /**
     * @brief 確定文字列をクライアントへコミットする
     * @param text コミットする文字列
     */
    void commitText(const std::string& text);

    /**
     * @brief 縦向きの候補テーブルを作り直して送出する
     *
     * 後のクリックをこのスナップショットと突き合わせて解決するために世代番号で印を付ける
     *
     * 訂正候補には灰色 (IBUS_ATTR_TYPE_FOREGROUND) の注記「*[訂正]*」を付ける (IBusには斜体の属性が無いため色のみ)
     *
     * @param candidates 表示する候補 (表記と訂正フラグ) の一覧
     * @param pageSize 1ページ当たりの表示件数
     * @param cursorIndex フォーカス中の候補の全体番号 (-1は未フォーカス)
     * @param generation この描画に付ける世代番号
     */
    void updateLookupTable(const std::vector<LookupCandidate>& candidates,
                           int pageSize, int cursorIndex, int generation);
    /**
     * @brief 候補テーブルを隠す
     * @param generation 非表示後のスナップショットに付ける世代番号
     */
    void hideLookupTable(int generation);

    /**
     * @brief 補助テキストを装飾なしで更新する
     * @param text 表示する補助テキスト (空なら非表示になる)
     */
    void updateAuxiliaryTextPlain(const std::string& text);
    /**
     * @brief カーソル位置の下線付きで補助テキストを更新する
     * @param auxUp 上段の補助テキスト
     * @param underlineStart 下線開始位置 (文字数単位、負なら下線なし)
     * @param underlineEnd 下線終了位置 (文字数単位)
     * @param auxDown 下段の補助テキスト
     */
    void updateAuxiliaryTextWithCursor(const std::string& auxUp,
                                       glong underlineStart,
                                       glong underlineEnd,
                                       const std::string& auxDown);

    /**
     * @brief パネル用プロパティを登録して初期状態を反映する
     * @param directInput 直接入力モードなら、true
     * @param zenzaiEnabled ニューラル変換が有効なら、true
     * @param liveConvertEnabled ライブ変換が有効なら、true
     */
    void registerProperties(bool directInput, bool zenzaiEnabled,
                            bool liveConvertEnabled);
    /**
     * @brief 入力モード表示 (あ/A) を更新する
     * @param directInput 直接入力モードなら、true
     */
    void updateInputModeProperty(bool directInput);
    /**
     * @brief ニューラル変換の表示状態を更新する
     * @param enabled ニューラル変換が有効なら、true
     */
    void updateZenzaiProperty(bool enabled);
    /**
     * @brief ライブ変換の表示状態を更新する
     * @param enabled ライブ変換が有効なら、true
     */
    void updateLiveConvertProperty(bool enabled);

    /** @brief クライアントへsurrounding textを要求する */
    void requestSurroundingText();

    /**
     * @brief 暫定消費後に未処理と判明したキーを転送する
     *
     * 判断の経緯は、HazkeyFrontendを参照のこと
     *
     * @param keyval 元のIBusイベントのkeyval
     * @param keycode 元のIBusイベントのkeycode
     * @param state 元のIBusイベントのstate
     * @note メインループ専用である
     */
    void forwardKeyEvent(guint keyval, guint keycode, guint state);

    /**
     * @brief パネルの候補テーブルが現在表示している内容
     *
     * メインループ上のcandidate_clickedハンドラが読み取り、ページ内ローカル番号をユーザがクリックした描画そのものと突き合わせて解決するためのものである
     */
    struct LookupSnapshot {
        int generation = 0;    ///< 描画の世代番号
        int pageSize = 0;      ///< 1ページ当たりの表示件数
        int pageStart = 0;     ///< 先頭に表示中の候補のグローバル番号
        int total = 0;         ///< 候補の総数
        int cursorPos = 0;     ///< グローバルなカーソル位置 (-1: 未フォーカス)
        bool visible = false;  ///< テーブルを表示中なら、true
    };
    /** @brief パネルが表示中の候補テーブルのスナップショットを返す */
    LookupSnapshot lookupSnapshot() const { return snapshot_; }

   private:
    IBusEngine* engine_;                             ///< 描画先のエンジン (所有しない)

    // IBus/GObject所有 (retire()で解放)
    IBusLookupTable* lookupTable_        = nullptr;  ///< 表示中の候補テーブル
    IBusPropList* propertyList_          = nullptr;  ///< 登録済みプロパティの一覧
    IBusProperty* inputModeProperty_     = nullptr;  ///< 入力モード表示 (あ/A)
    IBusProperty* zenzaiProperty_        = nullptr;  ///< ニューラル変換の切替表示
    IBusProperty* liveConvertProperty_   = nullptr;  ///< ライブ変換の切替表示
    /**
     * @brief プロパティ変化時にトレイメニュー向けに再登録する
     *
     * 登録後にプロパティが変化したら、propertyList_を再送する
     *
     * @param changed プロパティ内容が変化したなら、true
     * @note StatusNotifierItemモード (KDE) のibus-ui-gtk3は、register_propertiesでのみエクスポート済みトレイメニューを作り直し、
     *       update_propertyでは作り直さないため、更新だけではメニューのラベル/チェックが古いままになる
     */
    void reregisterPropertiesIfChanged(bool changed);

    // プロパティ状態 (再登録判定用)
    bool propertiesRegistered_ = false;  ///< プロパティを登録済みなら、true
    bool inputModeDirect_ = false;       ///< 直接入力モードなら、true
    bool zenzaiChecked_ = false;         ///< ニューラル変換が有効なら、true
    bool liveConvertChecked_ = false;    ///< ライブ変換が有効なら、true

    // 寿命・描画スナップショット
    bool retired_ = false;               ///< retire()済みで描画が無効なら、true
    bool secureInput_ = false;           ///< 安全入力中で表示と確定を抑止するなら、true
    LookupSnapshot snapshot_{};          ///< 現在表示中の候補テーブルの内容
};

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_UI_H

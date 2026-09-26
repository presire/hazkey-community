/**
 * @file hazkey_state.h
 * @brief IBusワーカースレッド側の入力状態機械を宣言する
 *
 * 1つのIBus入力コンテキストに対応するHazkeyStateと候補表示用のスナップショット型を定義する
 * IBusEngineやGObjectには触れず共有HazkeyUi経由で描画を依頼する
 */

#ifndef IBUS_HAZKEY_HAZKEY_STATE_H
#define IBUS_HAZKEY_HAZKEY_STATE_H

#include <ibus.h>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "candidate_refresh_coalescer.h"
#include "commands.pb.h"
#include "config.pb.h"
#include "hazkey_server_connector.h"
#include "hazkey_ui.h"
#include "serial_task_executor.h"

/**
 * @brief IBusフロントエンドの入力状態機械とUI描画を担う名前空間
 */
namespace hazkey::ibus {

/**
 * @brief Shift単体押下相当のモディファイア状態かを判定する
 *
 * [Shift]キー以外のモディファイアを含まないときに真を返す
 * 修飾キー自身のKeyPressはその修飾が適用される前の時点で採取したstateとともに報告される場合があるためSHIFTビット自体は要求しない
 * [Shift]キーリリースでサブ入力モードをトグルするかの判定に使用する
 *
 * @param state IBusモディファイア状態
 * @return Shift単体相当ならtrue
 */
bool isLoneShiftModifierState(guint state);

/**
 * @brief 候補一覧の1件を表す
 *
 * サーバ応答CandidatesResultの1要素に対応する表示用スナップショットである
 */
struct HazkeyCandidate {
    std::string text;               ///< 候補の表記
    std::string subHiragana;        ///< 末尾に残る読み
    bool hasLearningEntry = false;  ///< 学習エントリの有無
};

/**
 * @class HazkeyState
 * @brief 1つのIBus入力コンテキストに対応するワーカースレッド側IMEロジック
 *
 * GLibメインループ上で生成された後はコンストラクタに渡したシリアルワーカー上でのみ全メソッドを実行する
 * 単一スレッドが共有HazkeyServerConnectorと全フィールドを所有するためtransactの順序や再接続の意味論は変わらない
 * IBusEngineや他のIBusオブジェクトに一切触れず値を計算して、共有HazkeyUiへ送りメインループ専用レンダラが描画する
 *
 * 寿命は参照カウントで管理し、ワーカータスクがshared_ptrを捕捉するためタスクがオブジェクトより長生きすることはない
 * executor_は所有せず、プロセス共有ワーカーを借用し、ui_の指す先のオブジェクトが全IBusとGObjectを所有する
 */
class HazkeyState : public std::enable_shared_from_this<HazkeyState> {
 public:
    /**
     * @brief 共有UIとシリアルワーカーを受けて状態機械を構築する
     *
     * サーバ組成はここでは初期化せずフォーカスインや有効化時のresetStateに委ねる
     * 初回プロファイル取得前にホットキーが効くよう組込み既定値を種として入れる
     *
     * @param ui メインループ側レンダラへの共有端点
     * @param executor 動作するプロセス共有シリアルワーカーで所有しない
     */
    HazkeyState(std::shared_ptr<HazkeyUi> ui,
                hazkey::frontend::SerialTaskExecutor* executor);
    /**
     * @brief 保留中の遅延リフレッシュとヒントを取り消して破棄する
     *
     * ワーカータスクがshared_ptrを保持するため破棄後にタスクが走ることはない
     * IBusとGObjectは所有しないためここでは破棄しない
     */
    ~HazkeyState();
    /** @brief 複写を禁止する */
    HazkeyState(const HazkeyState&) = delete;
    /** @brief 代入を禁止する */
    HazkeyState& operator=(const HazkeyState&) = delete;

    /**
     * @brief IBusキーイベントを振り分けて消費可否を返す
     *
     * release時の[Shift]キー単体タップでサブ入力モードをトグルし、press時の[Shift]キー単体記録を行う
     * サーバプロファイルの遅延読込と各種ホットキーの照合を先に行い組成有無で候補系と素入力系へ振り分ける
     * 処理済みの場合は補助テキストを再計算する
     *
     * @param keyval IBusキーシンボル
     * @param keycode ハードウェアキーコードで使用しない
     * @param state IBusモディファイア状態
     * @return 消費した場合はTRUE
     */
    gboolean processKeyEvent(guint keyval, guint keycode, guint state);
    /** @brief 組成を初期化しプロファイルを再読込してプロパティを再登録する */
    void focusIn();
    /**
     * @brief 保留表示を解決して組成を確定し周囲テキストを捨てて初期化する
     */
    void focusOut();

    /** @brief キャッシュしたサーバプロファイルを破棄し次回に再読込させる */
    void invalidateServerProfile() { serverProfileLoaded_ = false; }
    /** @brief 周囲テキストを捨てて状態を初期化する */
    void reset();
    /**
     * @brief 状態を初期化し、プロパティを登録して周囲テキスト取得を要求する
     */
    void enable();
    /**
     * @brief 保留表示を解決して組成を確定し、周囲テキストを捨てて初期化する
     */
    void disable();
    /**
     * @brief IBusケーパビリティを記録し、周囲テキスト可否に反映する
     *
     * IBusEngineのset_capabilitiesに対応する実在の仮想関数経路で呼ばれる
     * 周囲テキスト非対応になった場合は記録済みの周囲テキストを捨てる
     *
     * @param caps IBusが通知したケーパビリティ集合
     */
    void setCapabilities(guint caps);
    /**
     * @brief パネルプロパティ操作を対応するトグル経路へ振り分ける
     *
     * 入力モードはサーバ側Shift単体タップ経路を使い回しZenzaiとライブ変換は各トグルと同じ経路で処理する
     *
     * @param propName 操作対象のプロパティ名
     * @param propState プロパティ状態で使用しない
     * @return 処理したプロパティならtrue
     */
    bool activateProperty(const gchar* propName, guint propState);
    /**
     * @brief カーソル位置を記録する
     *
     * @param x カーソルのX座標
     * @param y カーソルのY座標
     * @param w カーソルの幅
     * @param h カーソルの高さ
     */
    void setCursorLocation(gint x, gint y, gint w, gint h);
    /**
     * @brief 周囲テキストとカーソル位置を記録する
     *
     * メインループ側の呼び出し元は、IBusTextをenqueue前にstd::stringへ複写するためIBusオブジェクトを受け取らない
     * 周囲テキスト非対応の場合は記録せず破棄する
     *
     * @param text カーソル周辺のテキスト
     * @param cursorIndex カーソル位置で使用しない
     * @param anchorPos テキスト先頭からの文字単位アンカー位置
     */
    void setSurroundingText(const std::string& text, guint cursorIndex,
                            guint anchorPos);
    /** @brief 保留表示を解決して前ページへ移動し補助表示を更新する */
    void pageUp();
    /** @brief 保留表示を解決して次ページへ移動し補助表示を更新する */
    void pageDown();
    /** @brief 保留表示を解決して候補カーソルを戻し補助表示を更新する */
    void cursorUp();
    /** @brief 保留表示を解決して候補カーソルを進め補助表示を更新する */
    void cursorDown();
    /**
     * @brief メインループが写像済みの候補クリックを描画世代と照合して解決する
     *
     * 世代不一致はクリックの下でリストが変わった意味でありクリックを破棄する
     * 保留表示が残る古い描画へのクリックは、表示を解決して捨て更新後リストへの再クリックを促す
     *
     * @param globalIndex 全体候補インデックス
     * @param generation クリック時の描画世代
     */
    void candidateClickedGlobal(int globalIndex, int generation);

    /**
     * @brief 遅延中の表示リフレッシュを破棄し合流ポリシーを初期化する
     *
     * フォーカス移動や無効化や有効化やリセットとデストラクタから呼び出す
     * 破棄後や新しい組成エポックをまたいで古い表示がUIを書き換えないようにする
     */
    void cancelPendingRefresh();

    /**
     * @brief ページ内相対位置を全体候補位置へ写像する
     *
     * ページは現在の全体カーソル位置から解決する
     * ページ内に実在する候補数で上限を切り最終の部分ページに無い枠への数字キーが後ろのページの候補を選ばないようにする
     * 不正入力や範囲外では、-1を返す
     *
     * @param pageSize 1ページの候補数
     * @param totalSize 候補総数
     * @param cursorPos 現在の全体カーソル位置
     * @param localIndex ページ内相対位置
     * @return 全体候補位置で不正入力や範囲外では、-1
     */
    static int pageLocalToGlobalIndex(int pageSize, int totalSize,
                                      int cursorPos, int localIndex);

    /**
     * @brief パース済みキーボードショートカットを表す
     *
     * キー自体と同時押しが必要なモディファイア集合を持つ
     * hazkey-community-settingsが書いたFcitx5形式のプロファイルホットキー文字列を、入力コンテキストごとにloadServerProfileで1回だけパースする
     */
    struct HotkeySpec {
        guint keyval = 0;     ///< 照合するキーシンボルで0は未設定を表す
        guint modifiers = 0;  ///< 同時押下が必要なIBusモディファイアマスク
    };

    /**
     * @brief Fcitx 5形式ホットキー文字列をパースする
     *
     * 空文字ならfallback文字列を代わりにパースする
     * 非モディファイアキーが無い場合や複数ある場合や未知キー名の場合は未設定を返して閉鎖側に倒す
     *
     * @param keyString パース対象のホットキー文字列
     * @param fallback keyStringが空のときに代わりにパースする文字列
     * @return パース済みホットキー仕様で不正時は未設定
     */
    static HotkeySpec parseHotkey(const std::string& keyString,
                                  const std::string& fallback);
    /**
     * @brief IBusキーイベントをホットキー仕様と照合する
     *
     * 大文字小文字を区別せず比較しMod4をSuperへ畳み込みロックキーを無視する
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @param hotkey 照合対象のホットキー仕様
     * @return 一致した場合はtrue
     */
    static bool hotkeyMatches(guint keyval, guint state,
                              const HotkeySpec& hotkey);

    /**
     * @brief [Alt]と数字1から9の厳密な組み合わせかを判定する
     *
     * FcitxのisAltDigitKeyEventに対応する
     * Altと0の組み合わせは選択にならず余分なモディファイアがあればアプリケーション側のキーになる
     * ロックキーは他のホットキー述語と同様に無視する
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @return [Alt]と数字1から9の厳密な組み合わせならtrue
     */
    static bool isAltDigitKey(guint keyval, guint state);

    /**
     * @brief [Ctrl]と[U] / [I] / [O] / [P] / [T]のいずれかの厳密な組み合わせかを判定する
     *
     * FcitxのctrlShortcutHandlerの直接変換ショートカットに対応する
     * Fcitxは厳密に[Ctrl]のみを要求するため、[Ctrl]と[Shift]等の組み合わせはショートカットにならずアプリケーション側に残る
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @return 直接変換ショートカットならtrue
     */
    static bool isDirectConversionShortcut(guint keyval, guint state);

    /**
     * @brief 候補モードにおける[Alt]と[Shift]と[Space]や[Tab]の無操作組み合わせかを判定する
     *
     * [Shift]と[Tab]がIBUS_KEY_ISO_Left_Tabとして報告される場合も含める
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @return 無操作として消費すべき組み合わせならtrue
     */
    static bool isAltShiftSpaceOrTab(guint keyval, guint state);

    /**
     * @brief 候補テーブル枠向けの数字ラベルを返す
     *
     * FcitxのdefaultSelectionKeysに対応し1から9と0だけにラベルを付けそれ以外の枠にはあえて付けない
     *
     * @param localIndex ページ内相対位置
     * @return 枠に対応する数字ラベルで対象外は空文字列
     */
    static std::string selectionLabelForIndex(int localIndex);

    /**
     * @brief IBusケーパビリティが利用可能かを判定する
     *
     * IBusがケーパビリティを報告する前は全ケーパビリティを利用可能扱いして従来挙動を保つ
     *
     * @param caps 記録済みケーパビリティ集合
     * @param capsKnown ケーパビリティ通知を受け取ったか
     * @param capability 判定対象ケーパビリティ
     * @return 利用可能ならtrue
     */
    static bool capabilityIsAvailable(guint caps, bool capsKnown,
                                      guint capability);

    /**
     * @brief FcitxのAuxUpとAuxDownの組をIBus単一補助テキスト枠へ結合する
     *
     * 両方が非空のときだけ半角空白1つで区切る
     * 空の生ひらがなAuxUpがAuxDownの前に先行空白を残すことはない
     *
     * @param auxUp 上段補助テキスト
     * @param auxDown 下段補助テキスト
     * @return 結合した補助テキスト
     */
    static std::string joinAuxiliaryText(const std::string& auxUp,
                                         const std::string& auxDown);

    /**
     * @brief 状態機械と同じ印字可能入力キー述語を返す
     *
     * facadeの同期的消費判定とテスト用に公開する
     *
     * @param keyval IBusキーシンボル
     * @return 印字可能な入力キーならtrue
     */
    static bool isInputableKey(guint keyval);

    /**
     * @brief IBusLookupTableの循環なしカーソル前進を再実装する
     *
     * 候補テーブルをワーカーが直接操作せずメインループ上で構築するようになったため前進処理が使用する
     *
     * @param cursorIndex 現在の全体カーソル位置
     * @param total 候補総数
     * @return 移動後の全体カーソル位置
     */
    static int advanceCursorIndex(int cursorIndex, int total);
    /**
     * @brief IBusLookupTableの循環なしカーソル後退を再実装する
     *
     * 候補テーブルをワーカーが直接操作せずメインループ上で構築するようになったため後退処理が使用する
     *
     * @param cursorIndex 現在の全体カーソル位置
     * @param total 候補総数
     * @return 移動後の全体カーソル位置
     */
    static int backCursorIndex(int cursorIndex, int total);
    /**
     * @brief IBusLookupTableのページ前進開始位置を再実装する
     *
     * 最終ページでは現在ページ先頭に留まる
     *
     * @param cursorIndex 現在の全体カーソル位置
     * @param pageSize 1ページの候補数
     * @param total 候補総数
     * @return 移動後のページ開始位置
     */
    static int nextPageStart(int cursorIndex, int pageSize, int total);
    /**
     * @brief IBusLookupTableのページ後退開始位置を再実装する
     *
     * 先頭ページでは先頭に留まる
     *
     * @param cursorIndex 現在の全体カーソル位置
     * @param pageSize 1ページの候補数
     * @return 移動後のページ開始位置
     */
    static int prevPageStart(int cursorIndex, int pageSize);

    /**
     * @brief ワーカ側組成状態の平易な要約を表す
     *
     * 処理済み操作のたびに送りfacadeがRPCなしでキー消費可否を決められるようにする
     */
    struct IngressSnapshot {
        bool composing = false;         ///< 組成中か
        bool listFocused = false;       ///< 候補にフォーカス中か
        bool profileLoaded = false;     ///< サーバプロファイルを読込済みか
        HotkeySpec liveConvert{};       ///< ライブ変換トグルホットキー
        HotkeySpec zenzaiToggle{};      ///< Zenzaiトグルホットキー
        HotkeySpec acceptPrediction{};  ///< 予測受入ホットキー
        HotkeySpec deleteLearning{};    ///< 学習削除ホットキー
    };
    /**
     * @brief 現在のワーカ側組成状態の要約を返す
     *
     * @return メインループが消費できる状態要約
     */
    IngressSnapshot ingressSnapshot() const;

 private:
    /**
     * @brief 直接文字変換の対象を表す
     *
     * FcitxのHazkeyStateのConversionModeに対応する
     */
    enum class ConversionMode {
        Hiragana,           ///< ひらがなへ変換する
        KatakanaFullwidth,  ///< 全角カタカナへ変換する
        KatakanaHalfwidth,  ///< 半角カタカナへ変換する
        RawFullwidth,       ///< 全角英数へ変換する
        RawHalfwidth,       ///< 半角英数へ変換する
    };

    /**
     * @brief 組成が無い時のキーイベントを処理する
     *
     * 空白はそのまま確定し印字可能キーはサーバへ入力して表示専用リフレッシュを予約する
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @return 消費した場合はTRUE
     */
    gboolean noPreeditKeyEvent(guint keyval, guint state);
    /**
     * @brief 組成中のキーイベントを処理する
     *
     * 確定や削除や[F6]〜[F10]キーや無変換キーや候補表示やカーソル移動を振り分け印字可能キーは直接変換中なら確定後にサーバへ入力する
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @return 消費した場合はTRUE
     */
    gboolean preeditKeyEvent(guint keyval, guint state);
    /**
     * @brief 候補フォーカス中のキーイベントを処理する
     *
     * 学習削除と予測受入と[Alt] + 数字選択と[Alt]と[Shift]の無操作を透過より先に検査する
     * 印字可能キーは保留表示を解決してから確定と再入力を行う
     *
     * @param keyval IBusキーシンボル
     * @param state IBusモディファイア状態
     * @return 消費した場合はTRUE
     */
    gboolean candidateKeyEvent(guint keyval, guint state);

    /**
     * @brief サーバプロファイルを入力コンテキストごとに1回だけ遅延読込する
     *
     * FcitxのloadServerProfileに対応する
     * サーバ未準備時は組込み既定値を維持する
     * 非無効モードのときだけ記憶中の有効モードを更新する
     */
    void loadServerProfile();
    /**
     * @brief ホットキーでライブ変換をトグルする
     *
     * FcitxのhandleLiveConvertToggleに対応する
     * 同期取得と変更と保存で処理し失敗時は直前状態へ戻す
     * 組成があれば候補表示を作り直す
     */
    void handleLiveConvertToggle();
    /**
     * @brief ホットキーでZenzaiをトグルする
     *
     * 新しい状態はサーバが永続化する
     * 永続プロパティ更新に加えて新状態を一時的ヒントで表示する
     */
    void handleZenzaiToggle();
    /**
     * @brief 一時的なトグル通知を補助テキスト枠へ表示する
     *
     * IBusには全パネルが描画するFcitx 5式ポップアップが無いためibus-rimeと同じ方式で短時間だけ表示する
     * ワーカースレッド専用である
     *
     * @param text 表示するヒント文言
     */
    void showTransientHint(const std::string& text);
    /** @brief 表示中の一時的ヒント文言を消して補助表示を作り直す */
    void clearTransientHint();
    /**
     * @brief 保留中のヒント自動消去を取り消しヒント文言も捨てる
     *
     * リセットやフォーカス移動で古いヒントが次の補助テキスト更新時に蘇らないようにする
     */
    void cancelPendingHint();
    /**
     * @brief フォーカス中候補の学習メモリエントリを削除して同表示モードで作り直す
     *
     * @param globalIndex 削除対象の全体候補位置
     */
    void handleDeleteCandidateLearningData(int globalIndex);

    /**
     * @brief [F6]〜[F10]の組成変換を振り分けて直接変換モードに入る
     *
     * @param keyval IBusキーシンボル
     */
    void functionKeyHandler(guint keyval);
    /**
     * @brief 組成を指定文字種へ変換して候補表示を閉じる
     *
     * 保留表示を解決してから変換し直接変換突入後の確定に備えて強調preeditで表示する
     *
     * @param mode 変換対象の文字種
     */
    void directCharactorConversion(ConversionMode mode);
    /**
     * @brief [Ctrl]と[U] / [I] / [O] / [P] / [T]の直接変換を処理する
     *
     * FcitxのctrlShortcutHandlerに対応する
     * 対象キーなら直接変換モードに入り、それ以外の[Ctrl]キーは呼び出し元が転送できるよう偽を返す
     *
     * @param keyval IBusキーシンボル
     * @return 直接変換として消費した場合はtrue
     */
    bool ctrlShortcutHandler(guint keyval);
    /**
     * @brief リスト表示中にページ内[Alt]数字候補を選択する
     *
     * flushFirstは、Fcitxの素入力時分岐に対応し選択前に遅延合流表示を解決する
     * フォーカス済み分岐は振り分け時リストから選ぶため解決しない
     *
     * @param keyval IBusキーシンボル
     * @param flushFirst 選択前に保留表示を解決するならtrue
     */
    void selectPageLocalAltDigit(guint keyval, bool flushFirst);

    /**
     * @brief [Shift]と左右で文節境界を移動する
     *
     * 素入力モードと候補モードの両方で使う
     *
     * @param expand 境界を広げるならtrue
     */
    void moveSegmentBoundary(bool expand);

    /**
     * @brief 補助テキストをFcitx相当から畳んで再計算する
     *
     * AuxUpは候補フォーカス中は件数表示それ以外は下線付き生ひらがなである
     * AuxDownは直接入力表示と削除可否表示と[Tab]選択促しである
     */
    void updateAuxiliaryText();
    /**
     * @brief 結合済み補助テキストを送る
     *
     * @param text 表示する補助テキスト
     */
    void setAuxiliaryText(const std::string& text);
    /**
     * @brief 下線付きAuxUpとAuxDown接尾辞を結合した補助テキストを送る
     *
     * AuxUpのonCursor文字に任意の下線範囲を付け、Fcitxの下線指定のIBus相当として描画する
     *
     * @param auxUp 上段補助テキスト
     * @param underlineStart 下線開始の文字単位位置
     * @param underlineEnd 下線終了の文字単位位置
     * @param auxDown 下段補助テキスト接尾辞
     */
    void setAuxiliaryTextWithCursor(const std::string& auxUp,
                                    glong underlineStart, glong underlineEnd,
                                     const std::string& auxDown);
    /**
     * @brief 入力モードとZenzaiとライブ変換のプロパティを再登録する
     *
     * 登録前にサーバプロファイルを読み込み保存済み設定を即反映する
     */
    void registerProperties();
    /** @brief 現在の直接入力状態を入力モードプロパティへ送る */
    void updateInputModeProperty();
    /**
     * @brief Zenzai有効状態を記録してプロパティへ送る
     *
     * @param enabled Zenzaiが有効ならtrue
     */
    void updateZenzaiProperty(bool enabled);
    /**
     * @brief 記録済み自動変換モードからライブ変換トグルプロパティを送る
     *
     * 無効以外では点検付きで送る
     */
    void updateLiveConvertProperty();

    /**
     * @brief 候補表示要求を予測と非予測で振り分ける
     *
     * ライブ変換表示だけが一時停止の対象であり、非予測変換は対象外である
     *
     * @param isSuggest 予測表示ならtrue
     * @return 候補表示を出した場合はtrue
     */
    bool showCandidateList(bool isSuggest);
    /**
     * @brief サーバ候補応答を状態とpreeditと候補テーブルへ反映する
     *
     * 有効モードでlive_textがある場合だけその表示を使えなければ、代替文言か生ひらがなを使用する
     * preeditカーソルは先頭に固定してライブ変換幅の変動でパネルがばたつかないようにする
     *
     * @param response サーバ候補応答
     * @param fallback live_textが無い時に使用する代替表示で無ければ生ひらがなを使う
     * @param isSuggest 予測表示ならtrue
     * @return 候補表示を出した場合はtrue
     */
    bool applyCandidateResponse(
        const hazkey::commands::CandidatesResult& response,
        const std::optional<std::string>& fallback, bool isSuggest);
    /**
     * @brief 組成が残る場合だけ予測候補表示を作る
     *
     * 組成が空になった場合は状態を初期化する
     */
    void showPreeditCandidateList();

    // ライブ変換の一時停止 (組成カーソルが末尾に無い場合)
    //
    // かなオフセットは変換後テキストへ写像できない (かな <-> 漢字は多対多) ため、推測位置にキャレットを描く代わりにライブ変換表示を止める:
    // カーソルが末尾へ戻るまで生かなを本物のキャレット付きで表示する
    // モード判定とキャレット計算は、"hazkey-frontend-common/composing_cursor_view.h"経由でfcitx5-hazkeyと共有し、両フロントエンドの乖離を防ぐ
    //
    // "fcitx5-hazkey/src/hazkey_state.h"内の同名ブロックと厳密に対応する

    /**
     * @brief 一時停止中の表示を描く
     *
     * 生かなと本物キャレットを表示し候補テーブルを出さない
     * livePreeditIndexを-1にして確定が画面どおりになるようにする
     *
     * @param parts サーバ側カーソル付き生ひらがな
     */
    void showPausedRawPreedit(
        const hazkey::frontend::ComposingTextWithCursor& parts);
    /**
     * @brief カーソルが末尾に無い時に一時停止表示を描く
     *
     * 描いたら真を返し呼び出し元が変換を実行しないようにする
     *
     * @return 一時停止表示を描いた場合はtrue
     */
    bool showPausedPreeditIfCursorInside();
    /**
     * @brief 組成カーソルを移動して再描画する
     *
     * 末尾到達で同期再変換ちょうど1回によりライブ変換へ復帰する
     * 既に末尾にいる前進移動はRPC無しで消費する
     *
     * @param offset 移動量で負は前向き正は後向き
     */
    void moveComposingCursor(int offset);
    /**
     * @brief 組成変更後の編集に続けて再描画する
     *
     * 末尾では通常の合流ライブ変換表示を予約する
     * 一時停止中は誰も見ない変換を計算せず一時停止表示だけ描き直す
     */
    void refreshAfterComposingEdit();

    /**
     * @brief 入力可能キー打鍵に続く表示専用リフレッシュの合流入口
     *
     * fcitx5-hazkey-communityのscheduleCandidateRefreshに対応する
     * バースト先頭要求は即時実行し速い連続要求は、最新優先の30[ms]後縁間引きで1回の遅延実行へ畳む
     * 純粋な方針は、Fcitx 5と共有しタイマ適合層だけが異なる
     * 各呼び出しに先立つ状態変更inputCharのRPCは同期で順序付きのままであり、遅延するのは候補表示の送出だけである
     *
     * @param isSuggest 予測表示ならtrue
     */
    void scheduleCandidateRefresh(bool isSuggest);
    /** @brief 遅延期限に達した保留表示リフレッシュを実行する */
    void firePendingCandidateRefresh();
    /**
     * @brief 最新に要求された表示種別を実行する
     *
     * 立ち上がり縁経路と遅延経路で共有する
     */
    void runPendingCandidateRefresh();
    /**
     * @brief 保留中の合流表示を捨てず即時実行する
     *
     * preeditを消費しようとする呼び出し元が古い最終同期値ではなく最新サーバ状態に基づいて動くようにする
     */
    void flushPendingRefresh();

    /**
     * @brief 非予測候補表示を作り先頭へフォーカスする
     *
     * 保留の遅延予測表示が後から上書きしないよう取り消す
     * サーバ側カーソルを末尾へ寄せてから取得する
     */
    void showNonPredictCandidateList();
    /**
     * @brief 受け取った応答で非予測候補表示を作り先頭へフォーカスする
     *
     * 保留の遅延予測表示が後から上書きしないよう取り消す
     *
     * @param response サーバ候補応答
     * @param hiragana live_textが無い時に使用する生ひらがな表示
     */
    void showNonPredictCandidateList(
        const hazkey::commands::CandidatesResult& response,
        const std::string& hiragana);
    /**
     * @brief 未フォーカス表示へフォーカスし無ければ非予測変換へ切り替える
     *
     * 遅延表示を先に解決して全打鍵を反映させる
     */
    void focusCandidates();
    /**
     * @brief 指定全体位置の候補を確定する
     *
     * 末尾読みが残る候補では非予測表示へ続け残らない候補では状態を初期化する
     *
     * @param globalIndex 確定対象の全体候補位置
     */
    void completeCandidate(int globalIndex);
    /**
     * @brief 現在フォーカス候補をpreeditへ反映して候補テーブルを送り直す
     */
    void updateCandidateCursor();
    /**
     * @brief 候補カーソルを進めて末尾の次は先頭へ回す
     *
     * 未フォーカス表示では先頭へフォーカスする
     */
    void advanceCandidateCursor();
    /**
     * @brief 候補カーソルを戻して先頭の前は末尾へ回す
     *
     * 未フォーカス表示では先頭へフォーカスする
     */
    void backCandidateCursor();
    /** @brief 次ページ開始位置へ移動する */
    void nextPage();
    /** @brief 前ページ開始位置へ移動する */
    void prevPage();
    /**
     * @brief 数字キーによるページ内候補選択を処理する
     *
     * @param keyval IBusキーシンボル
     * @return 数字選択として消費した場合はtrue
     */
    bool selectDigit(guint keyval);
    /**
     * @brief 現在の候補スナップショットを世代付きでメインループへ送る
     *
     * テーブルは素朴なスナップショットからメインループ上でのみ構築するため、ワーカーはIBusLookupTableを所有しない
     */
    void pushLookupTable();
    /**
     * @brief 世代を進めて候補テーブル非表示をメインループへ送る
     */
    void clearLookupTable();
    /**
     * @brief 保留表示を取り消して全表示状態と組成を初期化する
     *
     * サーバへ新規組成を送る
     */
    void resetState();
    /**
     * @brief 保留表示を解決して現在のpreeditを確定する
     */
    void commitPreedit();
    /**
     * @brief 指定テキストを確定としてメインループへ送る
     *
     * @param text 確定するテキスト
     */
    void commitText(const std::string& text);
    /** @brief preedit非表示をメインループへ送る */
    void hidePreedit();
    /**
     * @brief 下線付きpreeditをメインループへ送る
     *
     * @param text 表示するpreedit文字列
     * @param startChar 下線開始の文字単位位置
     * @param endChar 下線終了の文字単位位置
     * @param cursorChar カーソルの文字単位位置
     */
    void setPreeditUnderline(const std::string& text, glong startChar,
                             glong endChar, guint cursorChar);
    /**
     * @brief 文字列全体を強調したpreeditを送る
     *
     * 直接文字変換用でありFcitxの強調表示に対応する
     *
     * @param text 表示するpreedit文字列
     */
    void setPreeditHighlighted(const std::string& text);
    /**
     * @brief 周囲テキスト追記付きでサーバ文脈を更新する
     *
     * 周囲テキスト非対応時は空文脈を送る
     *
     * @param append 追記する確定文字列で空なら現状のまま送る
     */
    void updateSurroundingText(const std::string& append = "");
    /** @brief 記録済み周囲テキストを破棄する */
    void clearSurroundingText();
    /**
     * @brief UI変更をメインループ側レンダラへ送る
     *
     * クロージャは共有端点を値捕捉しthisを捕捉しないため滞留したクロージャが破棄済み状態に触れることはない
     *
     * @param fn メインループ上で実行するUI操作
     */
    void postUi(std::function<void(HazkeyUi&)> fn);
    /**
     * @brief IBusキーシンボルをUTF-8文字列へ変換する
     *
     * @param keyval IBusキーシンボル
     * @return 対応するUTF-8文字列で変換不能時は空文字列
     */
    static std::string utf8FromKeyval(guint keyval);
    /**
     * @brief 直接変換対象からサーバ用文字種を求める
     *
     * @param mode 直接変換対象
     * @return サーバ組成取得用の文字種
     */
    static hazkey::commands::GetComposingString::CharType charTypeFor(
        ConversionMode mode);

    // --- 協調オブジェクト ---
    std::shared_ptr<HazkeyUi> ui_;                              ///< メインループ側レンダラへの共有端点
    hazkey::frontend::SerialTaskExecutor* executor_ = nullptr;  ///< 動作する共有シリアルワーカーで所有しない
    HazkeyServerConnector& server_;                             ///< 共有サーバコネクタへの参照

    // --- 候補リスト状態 ---
    std::vector<HazkeyCandidate> candidates_;                   ///< 候補一覧のスナップショット
    int pageSize_ = 0;                                          ///< 1ページの候補数
    int cursorIndex_ = -1;                                      ///< 全体カーソル位置で未フォーカス時は負
    bool listVisible_ = false;                                  ///< 候補テーブルを表示中か
    bool currentListIsSuggest_ = false;                         ///< 表示中リストが予測変換か

    // --- 候補リフレッシュ合流 ---
    hazkey::frontend::CandidateRefreshCoalescer refreshCoalescer_;                                                   ///< 表示間引き方針で単一ワーカー上でのみ触る
    hazkey::frontend::SerialTaskExecutor::Token refreshToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken; ///< 予約済み遅延表示タスクのトークン
    bool pendingRefreshIsSuggest_ = true;                                                                            ///< 保留表示の種別で真は予測表示
    bool executingPendingRefresh_ = false;                                                                           ///< 保留表示の実行中だけ真
    uint64_t lookupGeneration_ = 0;                                                                                  ///< 候補描画世代でクリック照合に使う
    std::string transientHintText_;                                                                                  ///< 一時的トグルヒント文言で空は無し
    hazkey::frontend::SerialTaskExecutor::Token hintToken_ = hazkey::frontend::SerialTaskExecutor::kInvalidToken;    ///< ヒント自動消去タスクのトークン

    // --- 組成 ---
    std::string preeditText_;                   ///< 表示中のpreedit文字列
    int livePreeditIndex_ = -1;                 ///< 表示中live_textの候補位置で非表示時は負
    bool isDirectConversionMode_ = false;       ///< 直接文字変換の表示中か

    // --- モディファイア・文節境界 ---
    bool shiftPressedAlone_ = false;            ///< Shift単体押下を記録中か
    bool isClauseBoundaryAdjusting_ = false;    ///< 文節境界調整の表示中か

    // --- 周囲テキスト・ケーパビリティ・カーソル ---
    std::string surroundingText_;               ///< 記録済み周囲テキスト
    guint surroundingAnchor_ = 0;               ///< 周囲テキスト先頭からの文字単位アンカー位置
    bool hasSurroundingText_ = false;           ///< 周囲テキストを保持中か
    guint caps_ = 0;                            ///< 通知済みIBusケーパビリティ集合
    bool capsKnown_ = false;                    ///< ケーパビリティ通知を受け取ったか
    gint cursorX_ = 0;                          ///< カーソルのX座標
    gint cursorY_ = 0;                          ///< カーソルのY座標
    gint cursorW_ = 0;                          ///< カーソルの幅
    gint cursorH_ = 0;                          ///< カーソルの高さ

    // --- ホットキー・プロファイル ---
    HotkeySpec liveConvertHotkey_{};            ///< ライブ変換トグルホットキー
    HotkeySpec zenzaiToggleHotkey_{};           ///< Zenzaiトグルホットキー
    HotkeySpec acceptPredictionHotkey_{};       ///< 予測受入ホットキー
    HotkeySpec deleteLearningHotkey_{};         ///< 学習削除ホットキー
    bool serverProfileLoaded_ = false;          ///< サーバプロファイルを読込済みか

    // --- キャッシュ ---
    bool cachedZenzaiEnabled_ = false;          ///< 記録済みZenzai有効状態
    ///< 記録済み自動変換モード
    hazkey::config::Profile_AutoConvertMode cachedAutoConvertMode_ = hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;
    ///< 記録済み生ひらがな補助表示モード
    hazkey::config::Profile_AuxTextMode cachedAuxTextMode_ = hazkey::config::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END;
};

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_STATE_H

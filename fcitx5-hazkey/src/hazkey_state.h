#ifndef _FCITX5_HAZKEY_HAZKEY_STATE_H_
#define _FCITX5_HAZKEY_HAZKEY_STATE_H_

#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/surroundingtext.h>
#include <memory>
#include "candidate_refresh_coalescer.h"
#include "config.pb.h"
#include "hazkey_candidate.h"
#include "hazkey_frontend_hooks.h"
#include "hazkey_preedit.h"

namespace fcitx {

class HazkeyEngine;

/**
 * @brief 入力コンテキストごとの変換状態とキー入力を管理する
 *
 * サーバ状態とFcitx 5の入力パネルを同期して、入力・変換・候補選択を処理する
 */
class HazkeyState : public InputContextProperty {
   public:
    /** @brief 入力状態を初期化して、サーバ側の組成を開始する
     *  @param engine エンジンへの参照
     *  @param ic 対象の入力コンテキスト
     *  @note 引数の所有権は移さない
     */
    HazkeyState(HazkeyEngine* engine, InputContext* ic);

    /** @brief 選択候補の先頭文節を確定して、残りの組成を更新する
     *  @param candidateList 現在表示中の候補リスト
     */
    void candidateCompleteHandler(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    /** @brief 現在のpreeditを入力先へ確定する */
    void commitPreedit();
    /** @brief 入力状態に応じて、キーイベントを処理する
     *  @param keyEvent Fcitx 5から受け取ったイベント
     */
    void keyEvent(KeyEvent& keyEvent);
    /** @brief 組成・候補表示・保留中の表示更新を初期状態へ戻す */
    void reset();

    /** @brief サーバプロファイルのキャッシュを破棄する
     *  @note 次のキーイベントでプロファイルを再取得する
     */
    void invalidateServerProfile() { serverProfileLoaded_ = false; }

   private:
    /** @brief 直接変換で指定する出力文字種 */
    enum class ConversionMode {
        Hiragana,             ///< ひらがな
        KatakanaFullwidth,    ///< 全角カタカナ
        KatakanaHalfwidth,    ///< 半角カタカナ
        RawFullwidth,         ///< 全角英数字
        RawHalfwidth,         ///< 半角英数字
    };

    /** @brief 候補表示時にpreeditへ反映する内容 */
    enum class showCandidateMode {
        PredictWithLivePreedit,       ///< 予測候補とライブ変換結果を表示
        NonPredictWithFirstPreedit,   ///< 非予測候補と先頭候補の読みを表示
    };

    /** @brief 入力先の周辺テキストをサーバへ反映する
     *  @param appendText 確定直前の文字列として末尾へ加える文字
     */
    void updateSurroundingText(std::string appendText = "");

    /** @brief サーバプロファイルからホットキーと表示設定を読み込む */
    void loadServerProfile();
    /** @brief ホットキーでライブ変換モードを切り替える
     *  @param event 切替を起こしたキーイベント
     */
    void handleLiveConvertToggle([[maybe_unused]] KeyEvent& event);
    /** @brief サーバのニューラル変換設定を切り替える */
    void handleZenzaiToggle();
    /** @brief フォーカス候補の学習データを削除して、同じ表示種別で再構築する
     *  @param candidateList フォーカス中の候補リスト
     */
    void handleDeleteCandidateLearningData(
        std::shared_ptr<HazkeyCandidateList> candidateList);

    /** @brief [Ctrl]系ショートカットを処理する
     *  @param keyEvent 対象イベント
     *  @return 対応するショートカットを処理した場合はtrue
     */
    bool ctrlShortcutHandler(KeyEvent& keyEvent);
    /** @brief ファンクションキーによる直接変換を処理する
     *  @param keyEvent 対象イベント
     */
    void functionKeyHandler(KeyEvent& keyEvent);
    /** @brief 組成文字列を指定した文字種へ直接変換する
     *  @param mode 出力文字種
     */
    void directCharactorConversion(ConversionMode mode);
    /** @brief preeditがない状態のキーイベントを処理する
     *  @param keyEvent 対象イベント
     */
    void noPreeditKeyEvent(KeyEvent& keyEvent);
    /** @brief 候補リストにフォーカスがある状態のキーイベントを処理する
     *  @param keyEvent 対象イベント
     *  @param candidateList フォーカス中の候補リスト
     */
    void candidateKeyEvent(KeyEvent& keyEvent,
                           std::shared_ptr<HazkeyCandidateList> candidateList);
    /** @brief 組成中のキーイベントを処理する
     *  @param keyEvent 対象イベント
     *  @param PreeditCandidateList 現在の予測候補リスト
     *  @note 存在しない場合はnullptr
     */
    void preeditKeyEvent(KeyEvent& keyEvent, std::shared_ptr<HazkeyCandidateList> PreeditCandidateList);
    /** @brief サーバから候補を取得して入力パネルへ設定する
     *  @param isSuggest 予測候補を取得する場合はtrue
     *  @return 候補リストを表示できた場合はtrue
     */
    bool showCandidateList(bool isSuggest);
    /** @brief 応答済み候補を入力パネルへ設定する
     *  @param response サーバから受け取った候補応答
     *  @param fallbackPreedit 応答の変換結果を使わない場合の表示文字列
     *  @return 候補リストを表示できた場合はtrue
     */
    bool showCandidateList(
        const hazkey::commands::CandidatesResult& response,
        std::optional<std::string> fallbackPreedit = std::nullopt);
    /** @brief 候補データから候補リストを生成する
     *  @param candidates 候補ごとの文字列データ
     *  @param preeditSegments 候補のpreedit文節
     *  @return 生成した候補リスト
     *  @note この宣言に対応する定義は現在の実装に存在しない
     */
    std::unique_ptr<HazkeyCandidateList> createCandidateList(
        std::vector<std::vector<std::string>> candidates,
        std::shared_ptr<std::vector<std::string>> preeditSegments);

    // キャレットが組成末尾以外にある場合はライブ変換表示を一時停止する
    //
    // かなの位置は変換後の文字列へ一意に対応付けられない
    // 推測した位置にキャレットを描画せず、末尾へ戻るまで生かなと実際のキャレットを表示する
    // モード判定とキャレット位置の計算は共通ヘッダでIBus版と共有する

    /** @brief 変換を一時停止し、生かなとキャレットを表示する
     *  @param parts 生かなとキャレット位置
     */
    void showPausedRawPreedit(const hazkey::frontend::ComposingTextWithCursor& parts);
    /** @brief キャレットが末尾以外なら一時停止表示へ切り替える
     *  @return 表示を切り替えた場合はtrue
     */
    bool showPausedPreeditIfCursorInside();
    /** @brief 組成カーソルを移動し、位置に応じた表示へ更新する
     *  @param offset サーバへ渡すカーソル移動量
     */
    void moveComposingCursor(int offset);
    /** @brief 組成編集後にライブ変換または一時停止表示を更新する */
    void refreshAfterComposingEdit();

    /** @brief 非予測変換候補を取得して表示する
     *  @param preserveTarget 現在のカーソル位置を維持する場合はtrue
     */
    void showNonPredictCandidateList(bool preserveTarget = false);
    /** @brief 応答済みの非予測候補を表示する
     *  @param response サーバから受け取った候補応答
     *  @param hiragana 表示するひらがな文字列
     */
    void showNonPredictCandidateList(const hazkey::commands::CandidatesResult& response, const std::string& hiragana);
    /** @brief 予測候補リストを取得して表示する */
    void showPreeditCandidateList();

    /** @brief 表示専用の候補更新を間引いて、実行または予約する
     *  @param isSuggest 予測候補の更新ならtrue
     *  @note 状態変更RPC自体は遅延せず、候補表示更新のみを対象とする
     */
    void scheduleCandidateRefresh(bool isSuggest);
    /** @brief タイマから期限到来した候補更新を実行する */
    void firePendingCandidateRefresh();
    /** @brief 最新の予約候補更新を実行する */
    void runPendingCandidateRefresh();
    /** @brief タイマと間引き器の保留状態を破棄する */
    void cancelPendingRefresh();
    /** @brief 保留中の候補更新を直ちに実行する */
    void flushPendingRefresh();

    /** @brief カーソル候補に合わせて、補助表示とpreeditを更新する
     *  @param candidateList 現在の候補リスト
     */
    void updateCandidateCursor(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    /** @brief 候補カーソルを次へ進めて、表示を更新する
     *  @param candidateList 対象の候補リスト
     */
    void advanceCandidateCursor(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    /** @brief 候補カーソルを前へ戻して、表示を更新する
     *  @param candidateList 対象の候補リスト
     */
    void backCandidateCursor(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    /** @brief 変換文節の境界を移動する
     *  @param expand 境界を右へ広げる場合はtrue
     */
    void moveSegmentBoundary(bool expand);
    /** @brief 候補位置と学習データ削除可否を補助表示へ反映する
     *  @param candidateList 表示中の候補リスト
     */
    void setCandidateCursorAUX(
        std::shared_ptr<HazkeyCandidateList> candidateList);
    /** @brief AuxDownへ状態に応じた文字列を設定する
     *  @param text 表示する文字列
     *  @note nulloptの場合は状態表示のみ
     */
    void setAuxDownText(std::optional<std::string>);
    /** @brief 未変換ひらがなをAuxUpへ表示する */
    void setHiraganaAUX();
    /** @brief キーイベントが文字入力として扱えるか判定する
     *  @param keyEvent 判定対象のイベント
     *  @return 入力可能なキーならtrue
     */
    bool isInputableEvent(const KeyEvent& keyEvent);

    /** @brief [Alt] + [数字]による候補選択キーか判定する
     *  @param keyEvent 判定対象のイベント
     *  @return [Alt] + [1]から[Alt] + [9]ならtrue
     */
    bool isAltDigitKeyEvent(const KeyEvent& keyEvent);

    // 入力・候補状態
    bool isClauseBoundaryAdjusting_ = false;  ///< 文節境界を調整中か
    bool isDirectConversionMode_ = false;     ///< 直接変換後の入力状態か
    bool shiftPressedAlone_ = false;          ///< [Shift]単独押下を追跡中か
    int livePreeditIndex_ = -1;               ///< 表示中ライブ変換候補の番号
    bool currentListIsSuggest_ = false;       ///< 表示中リストが予測候補か

    // プロファイル・ホットキー状態
    fcitx::Key liveConvertHotkey_{"Control+Shift+L"};  ///< [Ctrl] + [Shift] + [L]ライブ変換切替ホットキー
    fcitx::Key zenzaiToggleHotkey_{"Control+Alt+Z"};   ///< [Ctrl] + [Alt] + [Z]ニューラル変換切替ホットキー
    fcitx::Key acceptPredictionHotkey_{"F5"};          ///< [F5]予測候補受入ホットキー
    fcitx::Key deleteLearningHotkey_{"Control+D"};     ///< [Ctrl] + [D]学習データ削除ホットキー
    hazkey::config::Profile_AutoConvertMode cachedAutoConvertMode_ =
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;  ///< キャッシュした自動変換モード
    hazkey::config::Profile_AuxTextMode cachedAuxTextMode_ =
        hazkey::config::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END; ///< キャッシュした補助テキスト表示モード
    bool serverProfileLoaded_ = false;                 ///< サーバプロファイル取得済みか

    // 更新スケジューリング、間引き器とタイマは隣接させる
    hazkey::frontend::CandidateRefreshCoalescer coalescer_;  ///< 候補更新の間引き状態
    std::unique_ptr<EventSourceTime> refreshTimer_;          ///< 保留更新のイベントタイマ
    bool pendingRefreshIsSuggest_ = true;                    ///< 保留更新が予測候補か
    bool executingPendingRefresh_ = false;                   ///< 保留更新を実行中か

    // フレームワーク参照とpreeditアダプタ、宣言順は初期化順と一致させる
    HazkeyEngine* engine_;       ///< 非所有のエンジン参照
    InputContext* ic_;           ///< 非所有の入力コンテキスト参照
    HazkeyPreedit preedit_;      ///< preedit表示のアダプタ
};

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_HAZKEY_STATE_H_

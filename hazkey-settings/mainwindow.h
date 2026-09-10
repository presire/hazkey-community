#ifndef MAINWINDOW_H
#define MAINWINDOW_H

/**
 * @file mainwindow.h
 * @brief hazkey-settingsのメイン設定ウィンドウを宣言する
 *
 * サーバ設定、入力方式、ユーザ辞書、およびZenzaiモデル管理を1つのQWidgetに集約する
 * 編集内容は、[Apply] または [OK]ボタンを押下するまでサーバへ送信せず、
 * 設定UIは、常にprofiles[0]のみを対象とする
 */

#include <QAbstractButton>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QProgressDialog>
#include <QPushButton>
#include <QString>
#include <QVector>
#include <QWidget>
#include "serverconnector.h"
#include "userdict_model.h"
#include "zenzai_models.h"

class LearningHistoryDialog;

QT_BEGIN_NAMESPACE
namespace Ui {
class MainWindow;
}
QT_END_NAMESPACE

/**
 * @class MainWindow
 * @brief hazkey-serverの現在設定を編集するメインウィンドウ
 *
 * currentConfig_を編集用の作業コピーとして保持し、currentProfile_は常にそのprofiles[0]を借用する
 * このUIにはプロファイル切替・追加・削除はない
 * [Apply]ボタンは現在の編集を保存してウィンドウを開いたままにし、[OK]ボタンは保存に成功した場合だけ閉じる
 * [Cancel]ボタンは未保存の作業コピーを破棄して閉じ、[Reset]ボタンはサーバ提供の既定設定をプレビューする
 *
 * ui_ : 生成されたUIを所有し、デストラクタで明示的に削除する
 * networkManager_ : Qt親子関係により本ウィンドウが所有する
 *                   一時ダイアログはQPointerで追跡するため、Qtにより破棄されると自動的にnullになり、破棄後のポインタを使用しない
 */
class MainWindow : public QWidget {
    Q_OBJECT

   public:
    /**
     * @brief 親ウィジェットを設定してUIとサーバ設定を初期化する
     * @param parent このウィンドウを所有する親ウィジェット、なければnullptr
     */
    MainWindow(QWidget* parent = nullptr);
    /** @brief 進行中のダウンロードを中止し、所有する生成UIを破棄する */
    ~MainWindow();

   private slots:
    /**
     * @brief ダイアログボタン種別に応じて[Apply]、[OK]、[Cancel]ボタンの操作を実行する
     * @param button 押下されたダイアログボタン
     */
    void onButtonClicked(QAbstractButton* button);
    /**
     * @brief 履歴利用の有効状態に従って関連コントロールを切り替える
     * @param enabled 履歴利用を有効にする場合はtrue
     */
    void onUseHistoryToggled(bool enabled);
    /**
     * @brief カスタムZenzai重みの利用状態に従ってパス入力を切り替える
     * @param enabled カスタム重みを利用する場合はtrue
     */
    void onUseZenzaiCustomWeightToggled(bool enabled);
    /** @brief Zenzai重みファイルの選択ダイアログを開く */
    void onBrowseZenzaiWeightPath();
    /** @brief 選択済み入力テーブルを有効一覧へ移動する */
    void onEnableTable();
    /** @brief 選択済み入力テーブルを利用可能一覧へ戻す */
    void onDisableTable();
    /** @brief 有効入力テーブルの選択項目を上へ移動する */
    void onTableMoveUp();
    /** @brief 有効入力テーブルの選択項目を下へ移動する */
    void onTableMoveDown();
    /** @brief 有効入力テーブルの選択に合わせて操作ボタンを更新する */
    void onEnabledTableSelectionChanged();
    /** @brief 利用可能入力テーブルの選択に合わせて操作ボタンを更新する */
    void onAvailableTableSelectionChanged();
    /** @brief 選択済みキーマップを有効一覧へ移動する */
    void onEnableKeymap();
    /** @brief 選択済みキーマップを利用可能一覧へ戻す */
    void onDisableKeymap();
    /** @brief 有効キーマップの選択項目を上へ移動する */
    void onKeymapMoveUp();
    /** @brief 有効キーマップの選択項目を下へ移動する */
    void onKeymapMoveDown();
    /** @brief 有効キーマップの選択に合わせて操作ボタンを更新する */
    void onEnabledKeymapSelectionChanged();
    /** @brief 利用可能キーマップの選択に合わせて操作ボタンを更新する */
    void onAvailableKeymapSelectionChanged();
    /** @brief サブモード開始文字の変更をBasicとAdvancedの状態へ反映する */
    void onSubmodeEntryChanged();
    /** @brief Basic入力方式の選択をAdvanced設定へ同期する */
    void onBasicInputStyleChanged();
    /** @brief Basic形式の各設定変更をAdvanced設定へ同期する */
    void onBasicSettingChanged();
    /** @brief 入力方式設定をサーバ既定値へ戻す */
    void resetInputStyleToDefault();
    /** @brief 特殊変換の全チェックを有効にする */
    void onCheckAllConversion();
    /** @brief 特殊変換の全チェックを無効にする */
    void onUncheckAllConversion();
    /** @brief 現在のプロファイルの学習履歴を確認後に全削除する */
    void onClearLearningData();
    /** @brief 学習履歴を選択削除するダイアログを表示する */
    void onSelectiveLearningHistory();
    /** @brief ユーザ辞書の新規エントリを追加する */
    void onUserDictAdd();
    /** @brief 選択中のユーザ辞書エントリを編集する */
    void onUserDictEdit();
    /** @brief 選択中のユーザ辞書エントリを確認後に削除する */
    void onUserDictDelete();
    /** @brief TSV ファイルからユーザ辞書エントリを統合する */
    void onUserDictImport();
    /** @brief 現在のユーザ辞書エントリをTSVへ書き出す */
    void onUserDictExport();
    /** @brief ユーザ辞書の選択状態に合わせて削除ボタンを更新する */
    void onUserDictSelectionChanged();
    /**
     * @brief ユーザ辞書利用の有効状態に従って、辞書UIを切り替える
     * @param enabled ユーザ辞書を利用する場合はtrue
     */
    void onUseUserDictToggled(bool enabled);
    /** @brief Zenzaiモデルの選択、ダウンロード、削除ダイアログを開く */
    void onDownloadZenzaiModel();
    /**
     * @brief 現在のモデルダウンロード進捗を表示する
     * @param bytesReceived 受信済みバイト数
     * @param bytesTotal サーバが通知した総バイト数
     */
    void onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal);
    /** @brief 完了したモデルをSHA256検証して管理先へ保存する */
    void onDownloadFinished();
    /**
     * @brief モデルダウンロード失敗または取消後のUI状態を復旧する
     * @param error 発生したネットワークエラー種別
     */
    void onDownloadError(QNetworkReply::NetworkError error);
    /** @brief サーバ既定設定を取得して保存前のプレビューとして反映する */
    void onResetConfiguration();

   private:
    /** @brief UIのシグナルと各スロットを1箇所で接続する */
    void connectSignals();
    /**
     * @brief サーバ設定または既存作業コピーをUIへ読み込む
     * @param fetchConfig trueならサーバから作業コピーを再取得する
     * @return 設定の取得とUIへの反映に成功した場合はtrue
     */
    bool loadCurrentConfig(bool fetchConfig = true);
    /**
     * @brief UIの作業コピーをサーバへ保存し、成功時に基準状態を更新する
     * @return サーバへの保存と基準状態の更新に成功した場合はtrue
     */
    bool saveCurrentConfig();
    /** @brief 入力テーブル一覧の操作シグナルと初期ボタン状態を準備する */
    void setupInputTableLists();
    /** @brief プロファイルの入力テーブルを有効・利用可能一覧へ展開する */
    void loadInputTables();
    /** @brief 有効入力テーブル一覧の順序をプロファイルへ書き戻す */
    void saveInputTables();
    /** @brief 入力テーブルの選択と順序に応じて操作ボタンを更新する */
    void updateTableButtonStates();
    /** @brief キーマップ一覧の操作シグナルと初期ボタン状態を準備する */
    void setupKeymapLists();
    /** @brief プロファイルのキーマップを有効・利用可能一覧へ展開する */
    void loadKeymaps();
    /** @brief 有効キーマップ一覧の順序をプロファイルへ書き戻す */
    void saveKeymaps();
    /** @brief キーマップの選択と順序に応じて操作ボタンを更新する */
    void updateKeymapButtonStates();
    /** @brief Basicの選択値からAdvancedのキーマップと入力テーブルを再構成する */
    void syncBasicToAdvanced();
    /** @brief Advanced設定がBasicで表現できる場合に選択値へ逆同期する */
    void syncAdvancedToBasic();
    /**
     * @brief 現在のAdvanced設定がBasic UIで表現可能か判定する
     * @return Basic UIの選択値へ損失なく対応付けられる場合はtrue
     */
    bool isBasicModeCompatible();
    /** @brief Basic UIで表現不能な Advanced 設定の警告を表示する */
    void showBasicModeWarning();
    /** @brief Basic UIの互換性警告を非表示にする */
    void hideBasicModeWarning();
    /**
     * @brief Basic設定タブと関連操作の有効状態を切り替える
     * @param enabled Basic 設定タブを操作可能にする場合は true
     */
    void setBasicTabEnabled(bool enabled);
    /** @brief Basic入力方式から基礎キーマップと入力テーブルを適用する */
    void applyBasicInputStyle();
    /** @brief Basic句読点設定から対応キーマップを適用する */
    void applyBasicPunctuationStyle();
    /** @brief Basic数字設定から対応キーマップを適用する */
    void applyBasicNumberStyle();
    /** @brief Basic記号設定から対応キーマップを適用する */
    void applyBasicSymbolStyle();
    /** @brief Basic空白設定から対応キーマップを適用する */
    void applyBasicSpaceStyle();
    /**
     * @brief 利用可能なキーマップだけを有効一覧へ追加する
     * @param keymapName 追加候補のキーマップ名
     * @param isBuiltIn 組み込みキーマップならtrue
     */
    void addKeymapIfAvailable(const QString& keymapName, bool isBuiltIn);
    /**
     * @brief 利用可能な入力テーブルだけを有効一覧へ追加する
     * @param tableName 追加候補の入力テーブル名
     * @param isBuiltIn 組み込み入力テーブルならtrue
     */
    void addInputTableIfAvailable(const QString& tableName, bool isBuiltIn);
    /** @brief Basic同期に先立ちキーマップと入力テーブルの一覧を空にする */
    void clearKeymapsAndTables();
    /**
     * @brief 組み込みキーマップ名をUI用に翻訳する
     * @param keymapName 翻訳候補のキーマップ名
     * @param isBuiltin 組み込みキーマップならtrue
     * @return 組み込み名は翻訳済み文字列、それ以外は元の名前
     */
    QString translateKeymapName(const QString& keymapName, bool isBuiltin);
    /**
     * @brief 組み込み入力テーブル名をUI用に翻訳する
     * @param tableName 翻訳候補の入力テーブル名
     * @param isBuiltin 組み込み入力テーブルならtrue
     * @return 組み込み名は翻訳済み文字列、それ以外は元の名前
     */
    QString translateTableName(const QString& tableName, bool isBuiltin);
    /**
     * @brief 任意の操作ボタンを含む警告表示用ウィジェットを生成する
     * @param message 表示する警告本文
     * @param backgroundColor 背景に適用する色指定
     * @param buttonText 追加操作ボタンの表示文字列、空ならボタンを追加しない
     * @param buttonCallback 追加ボタン押下時の処理、空ならボタンを追加しない
     * @return 呼び出し元がレイアウトへ追加する新しい警告ウィジェット
     */
    QWidget* createWarningWidget(
        const QString& message, const QString& backgroundColor,
        const QString& buttonText = QString(),
        std::function<void()> buttonCallback = nullptr);
    /**
     * @brief XDG設定ディレクトリ配下のユーザ辞書TSVパスを返す
     * @return 作成済み設定ディレクトリ配下のユーザ辞書ファイルパス
     */
    static QString userDictFilePath();
    /** @brief ユーザ辞書TSVを読み込み、メモリ上のエントリ一覧を置き換える */
    void loadUserDictFromDisk();
    /**
     * @brief メモリ上のユーザ辞書をアトミックにTSVへ保存する
     * @return ファイルの書込みと置換に成功した場合はtrue
     */
    bool saveUserDictToDisk();
    /** @brief メモリ上のユーザ辞書を表ウィジェットへ再描画する */
    void refreshUserDictTable();
    /**
     * @brief ユーザ辞書エントリ編集ダイアログで入力を検証して反映する
     * @param entry 編集対象であり、確定時には検証済みの内容へ更新されるエントリ
     * @param title ダイアログタイトル
     * @return 入力が確定され、entryを更新した場合はtrue
     */
    bool editUserDictEntryDialog(UserDictEntry& entry, const QString& title);
    /** @brief ユーザ辞書タブの表とファイル由来の初期状態を準備する */
    void setupUserDict();
    /** @brief ディスク状態とダウンロード状態からモデル管理ダイアログのボタンを復元する */
    void refreshZenzaiDialogButtonStates();
    /**
     * @brief 存在するモデル管理ダイアログを優先してメッセージボックスの親にする
     * @return 有効なモデル管理ダイアログ、なければこのMainWindow
     */
    QWidget* zenzaiDialogParent() const;
    /**
     * @brief UI読込中のdirty判定を抑止するガードを設定する
     * @param loading 設定読込または内部同期中ならtrue
     */
    void setConfigLoading(bool loading);
    /** @brief 現在のUI状態を保存済み設定との比較基準として記録する */
    void updateBaseline();
    /** @brief 基準との差分から[Apply]ボタンの有効状態を再計算する */
    void recomputeDirtyState();
    /**
     * @brief UIが表す通常設定と一覧順序を構造的な比較キーへ直列化する
     * @return dirty判定で比較するコンパクトJSON形式の状態キー
     */
    QString uiStateKey() const;
    /**
     * @brief ダイアログボックスに属する[Apply]ボタンを取得する
     * @return [Apply]ボタン、ダイアログボックスがなければnullptr
     */
    QPushButton* applyButton() const;
    /** @brief AUTOUICが生成するUIを所有し、デストラクタで明示的に削除する */
    Ui::MainWindow* ui_;
    /** @brief 設定RPC、学習履歴操作、モデル再読込に使う値所有のコネクター */
    ServerConnector server_;
    /** @brief サーバから取得した設定の編集用作業コピー */
    hazkey::config::CurrentConfig currentConfig_;
    /** @brief currentConfig_のprofiles[0]を借用する非所有ポインタ */
    hazkey::config::Profile* currentProfile_;
    /** @brief Advancedからの反映中にBasic側の再入同期を防ぐガード */
    bool isUpdatingFromAdvanced_;
    /** @brief 設定読込と内部同期中にdirty基準を変更しないためのガード */
    bool isLoadingConfig_;
    /** @brief 最後に正常取得または正常保存されたUI状態の比較キー */
    QString baselineKey_;
    /** @brief 本ウィンドウを親に持ち、Qt親子関係で破棄される通信マネージャー */
    QNetworkAccessManager* networkManager_;
    /** @brief 実行中のモデル取得を表すreplyで、完了またはエラー時に解放する */
    QNetworkReply* currentDownload_;
    /** @brief モデル取得中だけ表示する進捗ダイアログで、終了時に破棄する */
    QProgressDialog* downloadProgressDialog_;
    /** @brief 選択または取得中のZenzaiモデルパス */
    QString zenzaiModelPath_;
    /** @brief 開いているモデル管理ダイアログを非所有で追跡し、破棄時は自動でnullになる */
    QPointer<QDialog> zenzaiModelDialog_;
    /** @brief 開いている学習履歴ダイアログを非所有で追跡し、破棄時は自動でnullになる */
    QPointer<LearningHistoryDialog> learningHistoryDialog_;
    /** @brief モデル選択ダイアログで取得開始前に選ばれたダウンロードURL */
    QString currentDownloadUrl_;
    /** @brief 取得完了後に検証する期待SHA256値 */
    QString currentDownloadExpectedSha256_;
    /** @brief 取得完了後の保存先と選択状態に使うモデルキー */
    QString currentDownloadKey_;
    /** @brief ユーザ辞書TSVと表ウィジェット間で共有する編集用エントリ一覧 */
    QVector<UserDictEntry> userDictEntries_;
};
#endif  // MAINWINDOW_H

/**
 * @file mainwindow.cpp
 * @brief MainWindowの設定編集、辞書、Zenzai管理実装を定義する
 *
 * ヘッダで宣言したMainWindow APIの実装と、この翻訳単位だけで使う辞書品詞およびdirty状態用の補助処理を配置する
 */

#include <qlabel.h>
#include <qnamespace.h>
#include <QAbstractButton>
#include <QButtonGroup>
#include <QCheckBox>
#include <QComboBox>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QListWidgetItem>
#include <QMenu>
#include <QMessageBox>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPushButton>
#include <QRadioButton>
#include <QScopedValueRollback>
#include <QStandardPaths>
#include <QTableWidget>
#include <QTableWidgetItem>
#include <QTextStream>
#include <QThread>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include "mainwindow.h"
#include "zenzai_family_row.h"
#include "./ui_mainwindow.h"
#include "config_definitions.h"
#include "config_macros.h"
#include "constants.h"
#include "constants.h.in"
#include "learninghistorydialog.h"
#include "keysequence_util.h"
#include "serverconnector.h"
#include "userdict_model.h"
#include "zenzai_dialog_selection.h"
#include "zenzai_download_validation.h"
#include "zenzai_models.h"

namespace {

class OverrideCursorGuard {
   public:
    OverrideCursorGuard() { QApplication::setOverrideCursor(Qt::WaitCursor); }
    ~OverrideCursorGuard() { QApplication::restoreOverrideCursor(); }
};

/**
 * @brief 現在チェックされている系列/バリアントを返す
 * @param group 系列ごとのラジオボタンを束ねるボタングループ
 * @return チェック中の選択。未チェックならnullopt
 */
std::optional<ZenzaiDialogSelection> currentZenzaiDialogSelection(QButtonGroup* group) {
    if (!group || !group->checkedButton()) {
        return std::nullopt;
    }

    const int familyIndex = group->id(group->checkedButton());
    ZenzaiFamilyRow* row = qobject_cast<ZenzaiFamilyRow*>(group->checkedButton()->parentWidget());
    if (!row || familyIndex < 0) {
        return std::nullopt;
    }

    return ZenzaiDialogSelection{familyIndex, row->variantIndex()};
}

void clearZenzaiDialogSelection(QButtonGroup* group) {
    if (!group || !group->checkedButton()) {
        return;
    }
    group->setExclusive(false);
    group->checkedButton()->setChecked(false);
    group->setExclusive(true);
}

/**
 * @brief ユーザ辞書TSVで許可する正規化済み品詞トークン
 * @internal この翻訳単位の読込と編集ダイアログだけで使用する
 */
const QStringList POS_TOKENS = QStringLiteral("noun,person,place,verb").split(',');

/**
 * @brief 入力品詞を許可済みの小文字トークンへ正規化する
 * @param t TSV または編集結果から得た品詞文字列
 * @return 許可済みトークン、空または未知値はnoun
 * @internal 不正値は警告して安全な既定品詞へフォールバックする
 */
QString normalizePosToken(QString t) {
    t = t.trimmed().toLower();
    if (t.isEmpty() || !POS_TOKENS.contains(t)) {
        if (!t.isEmpty()) {
            qWarning("Unknown POS token '%s', defaulting to noun", qPrintable(t));
        }
        return QStringLiteral("noun");
    }
    return t;
}

/**
 * @brief 品詞トークンを翻訳済みの表示名へ変換する
 * @param pos 正規化済みの品詞トークン
 * @return ユーザ辞書表と編集コンボボックスに表示する名前
 * @internal nounと未知値は固有名詞の表示へ対応付ける
 */
QString posToDisplay(const QString& pos) {
    if (pos == QStringLiteral("person")) return QCoreApplication::translate("MainWindow", "人名");
    if (pos == QStringLiteral("place")) return QCoreApplication::translate("MainWindow", "地名");
    if (pos == QStringLiteral("verb")) return QCoreApplication::translate("MainWindow", "動詞");
    return QCoreApplication::translate("MainWindow", "固有名詞");
}

/**
 * @section zenzai_download_catalog Zenzaiダウンロードカタログ
 * @brief モデル一覧は、zenzai_models.hの固定カタログを利用する
 * @internal ダウンロード前にユーザが選択し、SHA256を完了時に照合する
 */
// GUIがダウンロードできるZenzai GGUFモデルのカタログ
// 推奨モデルを先頭に並べ、ダウンロード前に選択ダイアログで任意のエントリを選択する。
//
// sha256はurlからダウンロードしたファイルのSHA256 (実バイトから計算した値であり、HuggingFace LFSのoidではない)
// isLegacyGenは、インストール時に「更新」警告を表示すべき既知の旧世代モデルに設定する
// 現行世代の非推奨バリアント (例: xsmall) は、推奨の既定値でなくても警告を表示しない

/**
 * @brief 有効入力テーブルまたはキーマップ一覧を構造的JSON状態へ変換する
 * @param list 有効項目を順序付きで保持する一覧
 * @return 項目名と組み込みフラグから成るJSON配列
 * @internal uiStateKeyのdirty比較で区切り文字衝突を避けるために使用する
 */
QJsonArray enabledListState(const QListWidget* list) {
    QJsonArray entries;
    for (int i = 0; i < list->count(); ++i) {
        const QListWidgetItem* item = list->item(i);
        QJsonArray entry;
        entry.append(item->data(Qt::UserRole).toString());
        entry.append(item->data(Qt::UserRole + 1).toBool());
        entries.append(entry);
    }
    return entries;
}

}  // namespace

MainWindow::MainWindow(QWidget* parent)
    : QWidget(parent),
      ui_(new Ui::MainWindow),
      server_(ServerConnector()),
      isUpdatingFromAdvanced_(false),
      isLoadingConfig_(false),
      networkManager_(new QNetworkAccessManager(this)),
      currentDownload_(nullptr),
      downloadProgressDialog_(nullptr) {
    ui_->setupUi(this);

    // 入力テーブル設定のモード切替タブを均等幅にする
    ui_->inputTableConfigModeTabWidget->tabBar()->setExpanding(true);

    // [リセット]ボタンでサーバ提供の既定設定をプレビューする
    QPushButton* resetButton = ui_->dialogButtonBox->button(QDialogButtonBox::Reset);
    if (resetButton) {
        resetButton->setText(tr("Reset"));
        QIcon reloadIcon = QApplication::style()->standardIcon(QStyle::SP_BrowserReload);
        resetButton->setIcon(reloadIcon);
    }

    // バージョン表示を設定する
    QString hazkeyVersionText =
        QString(
            "<html><head/><body><p><span "
            "style=\"font-size:18pt\">%1</span></p></body></html>")
            .arg(HAZKEY_VERSION_STR);
    ui_->aboutHazkeyTitleVersionText->setText(hazkeyVersionText);

    // ユーザ辞書タブを初期化する
    setupUserDict();

    // UIシグナルを接続する
    connectSignals();

    // 入力テーブル一覧を初期化する
    setupInputTableLists();

    // キーマップ一覧を初期化する
    setupKeymapLists();

    // 必要に応じて旧形式Zenzaiモデルを移行する
    ZenzaiModelManager::migrateLegacyModel();

    // 設定を読み込む
    if (!loadCurrentConfig()) {
        // 設定読込に失敗した場合はUI要素を無効化する
        setEnabled(false);
        QMessageBox::critical(
            this, tr("Configuration Error"),
            tr("Failed to load configuration. Please check your "
               "connection to the hazkey server."));
    }
}

void MainWindow::setConfigLoading(bool loading) {
    isLoadingConfig_ = loading;
}

QPushButton* MainWindow::applyButton() const {
    if (!ui_->dialogButtonBox) {
        return nullptr;
    }
    return ui_->dialogButtonBox->button(QDialogButtonBox::Apply);
}

// UIが現在表す通常設定を漏れなく表す正規キーを構築する
// Profile由来の全コントロールと有効な入力テーブル/キーマップの順序付き状態を含む
// 保存済み基準値との比較で未保存の編集有無を検出するために使用する
//
// 状態はコンパクトなJSON文書として直列化する
// JSONの文字列エスケープにより構造的な符号化になるため、ユーザ入力の任意テキスト (プロファイルのテキスト欄やカスタムのテーブル/キーマップ名) が、
// 場当たり的な区切り文字連結のようにフィールド間で衝突することはない
QString MainWindow::uiStateKey() const {
    QJsonObject state;

    state.insert("autoConvertMode", ui_->autoConvertion->currentIndex());
    state.insert("auxiliaryText", ui_->auxiliaryText->currentIndex());
    state.insert("suggestionList", ui_->suggestionList->currentIndex());
    state.insert("numSuggestion", ui_->numSuggestion->value());
    state.insert("autoConvertMinChars", ui_->autoConvertMinChars->value());
    state.insert("numCandidatesPerPage", ui_->numCandidatesPerPage->value());
    state.insert("zenzaiInferenceLimit", ui_->zenzaiInferenceLimit->value());
    state.insert("useHistory", ui_->useHistory->isChecked());
    state.insert("stopStoreNewHistory", ui_->stopStoreNewHistory->isChecked());
    state.insert("useProfileIndependentHistory", ui_->useProfileIndependentHistory->isChecked());
    state.insert("useRichSuggestion", ui_->useRichSuggestion->isChecked());
    state.insert("useRichCandidates", ui_->useRichCandidates->isChecked());
    state.insert("enableZenzai", ui_->enableZenzai->isChecked());
    state.insert("zenzaiContextualConversion", ui_->zenzaiContextualConversion->isChecked());
    state.insert("useZenzaiCustomWeight", ui_->useZenzaiCustomWeight->isChecked());
    state.insert("useUserDict", ui_->useUserDict->isChecked());
    state.insert("halfwidthKatakanaConversion", ui_->halfwidthKatakanaConversion->isChecked());
    state.insert("extendedEmojiConversion", ui_->extendedEmojiConversion->isChecked());
    state.insert("commaSeparatedNumCoversion", ui_->commaSeparatedNumCoversion->isChecked());
    state.insert("calendarConversion", ui_->calendarConversion->isChecked());
    state.insert("timeConversion", ui_->timeConversion->isChecked());
    state.insert("mailDomainConversion", ui_->mailDomainConversion->isChecked());
    state.insert("unicodeCodePointConversion", ui_->unicodeCodePointConversion->isChecked());
    state.insert("romanTypographyConversion", ui_->romanTypographyConversion->isChecked());
    state.insert("hazkeyVersionConversion", ui_->hazkeyVersionConversion->isChecked());
    state.insert("relativeDateConversion", ui_->relativeDateConversion->isChecked());
    state.insert("submodeEntryPointChars", ui_->submodeEntryPointChars->text());
    state.insert("zenzaiUserPlofile", ui_->zenzaiUserPlofile->text());
    state.insert("zenzaiTopic", ui_->zenzaiTopic->text());
    state.insert("zenzaiStyle", ui_->zenzaiStyle->text());
    state.insert("zenzaiPreference", ui_->zenzaiPreference->text());
    state.insert("zenzaiWeightPath", ui_->zenzaiWeightPath->text());
    state.insert("liveConvertHotkey", ui_->liveConvertHotkey->keySequence().toString());
    state.insert("deleteLearningHotkey", ui_->deleteLearningHotkey->keySequence().toString());
    state.insert("acceptPredictionHotkey", ui_->acceptPredictionHotkey->keySequence().toString());
    state.insert("zenzaiToggleHotkey", ui_->zenzaiToggleHotkey->keySequence().toString());
    state.insert("zenzaiBackendDevice", ui_->zenzaiBackendDevice->currentData().toString());
    // 有効な入力テーブルを順序付きで格納する (名前+組込フラグ)
    state.insert("enabledTables", enabledListState(ui_->enabledTableList));
    // 有効なキーマップを順序付きで格納する (名前+組込フラグ)
    state.insert("enabledKeymaps", enabledListState(ui_->enabledKeymapList));

    return QString::fromUtf8(QJsonDocument(state).toJson(QJsonDocument::Compact));
}

void MainWindow::updateBaseline() {
    baselineKey_ = uiStateKey();
}

void MainWindow::recomputeDirtyState() {
    // 設定からUIへ値を流し込んでいる間は、プログラムによる変更をユーザの未保存編集として扱わない
    if (isLoadingConfig_) {
        return;
    }

    const bool dirty = (uiStateKey() != baselineKey_);

    if (QPushButton* apply = applyButton()) {
        apply->setEnabled(dirty);
    }
}

void MainWindow::connectSignals() {
    // ダイアログボタンを接続する
    // [OK]ボタンは、単一のclicked → onButtonClicked経路にのみ接続して、最大1回の保存だけが起きるようにする
    // QDialogButtonBox::acceptedシグナルは意図的にここでは接続しない
    connect(ui_->dialogButtonBox, &QDialogButtonBox::clicked, this, &MainWindow::onButtonClicked);

    // [リセット]ボタンを接続する
    QPushButton* resetButton = ui_->dialogButtonBox->button(QDialogButtonBox::Reset);
    if (resetButton) {
        connect(resetButton, &QPushButton::clicked, this, &MainWindow::onResetConfiguration);
    }

    connect(ui_->useHistory, &QCheckBox::toggled, this, &MainWindow::onUseHistoryToggled);
    connect(ui_->useZenzaiCustomWeight, &QCheckBox::toggled, this, &MainWindow::onUseZenzaiCustomWeightToggled);
    connect(ui_->browseZenzaiWeightPath, &QPushButton::clicked, this, &MainWindow::onBrowseZenzaiWeightPath);
    connect(ui_->useUserDict, &QCheckBox::toggled, this, &MainWindow::onUseUserDictToggled);

    // 入力テーブル管理ボタンを接続する
    connect(ui_->enableTable, &QToolButton::clicked, this, &MainWindow::onEnableTable);
    connect(ui_->disableTable, &QToolButton::clicked, this, &MainWindow::onDisableTable);
    connect(ui_->tableMoveUp, &QToolButton::clicked, this, &MainWindow::onTableMoveUp);
    connect(ui_->tableMoveDown, &QToolButton::clicked, this, &MainWindow::onTableMoveDown);

    // 一覧の選択変更をボタン状態の更新につなげる
    connect(ui_->enabledTableList, &QListWidget::itemSelectionChanged, this, &MainWindow::onEnabledTableSelectionChanged);
    connect(ui_->availableTableList, &QListWidget::itemSelectionChanged, this, &MainWindow::onAvailableTableSelectionChanged);

    // キーマップ管理ボタンを接続する
    connect(ui_->enableKeymap, &QToolButton::clicked, this, &MainWindow::onEnableKeymap);
    connect(ui_->disableKeymap, &QToolButton::clicked, this, &MainWindow::onDisableKeymap);
    connect(ui_->keymapMoveUp, &QToolButton::clicked, this, &MainWindow::onKeymapMoveUp);
    connect(ui_->keymapMoveDown, &QToolButton::clicked, this, &MainWindow::onKeymapMoveDown);

    // キーマップ一覧の選択変更をボタン状態の更新につなげる
    connect(ui_->enabledKeymapList, &QListWidget::itemSelectionChanged, this, &MainWindow::onEnabledKeymapSelectionChanged);
    connect(ui_->availableKeymapList, &QListWidget::itemSelectionChanged, this, &MainWindow::onAvailableKeymapSelectionChanged);

    // Basicタブの入力形式変更を接続する
    connect(ui_->mainInputStyle,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            &MainWindow::onBasicInputStyleChanged);
    connect(ui_->punctuationStyle,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            &MainWindow::onBasicSettingChanged);
    connect(ui_->numberStyle,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            &MainWindow::onBasicSettingChanged);
    connect(ui_->commonSymbolStyle,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            &MainWindow::onBasicSettingChanged);
    connect(ui_->spaceStyleLabel,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            &MainWindow::onBasicSettingChanged);

    // サブモード入口文字の変更をBasicタブとの同期につなげる
    connect(ui_->submodeEntryPointChars, &QLineEdit::textChanged, this, &MainWindow::onSubmodeEntryChanged);

    // 特殊変換ボタンを接続する
    connect(ui_->checkAllConversion, &QPushButton::clicked, this, &MainWindow::onCheckAllConversion);
    connect(ui_->uncheckAllConversion, &QPushButton::clicked, this, &MainWindow::onUncheckAllConversion);

    // 学習データ消去ボタンを接続する
    connect(ui_->clearLearningData, &QPushButton::clicked, this, &MainWindow::onClearLearningData);
    connect(ui_->selectiveLearningHistory, &QPushButton::clicked, this, &MainWindow::onSelectiveLearningHistory);

    // Zenzaiモデル管理ボタンを接続する
    connect(ui_->manageZenzaiModels, &QPushButton::clicked, this, &MainWindow::onDownloadZenzaiModel);

    // ユーザ辞書ボタンとテーブルシグナルを接続する
    connect(ui_->userDictNewEntry, &QPushButton::clicked, this, &MainWindow::onUserDictAdd);
    connect(ui_->userDictDeleteEntry, &QPushButton::clicked, this, &MainWindow::onUserDictDelete);
    connect(ui_->userDictImport, &QPushButton::clicked, this, &MainWindow::onUserDictImport);
    connect(ui_->userDictExport, &QPushButton::clicked, this, &MainWindow::onUserDictExport);
    connect(ui_->userDictTable, &QTableWidget::itemSelectionChanged, this, &MainWindow::onUserDictSelectionChanged);
    connect(ui_->userDictTable, &QTableWidget::itemDoubleClicked, this, [this](QTableWidgetItem*) { onUserDictEdit(); });

    // 通常設定の未保存編集を追跡し、UIが保存済み基準値と異なる間だけ[Apply]ボタンを有効化する
    // プログラムによる流し込みは、recomputeDirtyState()内でisLoadingConfig_ により抑止される
    connect(ui_->autoConvertion,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            [this](int) { recomputeDirtyState(); });
    connect(ui_->auxiliaryText,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            [this](int) { recomputeDirtyState(); });
    connect(ui_->suggestionList,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            [this](int) { recomputeDirtyState(); });
    connect(ui_->zenzaiBackendDevice,
            QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            [this](int) { recomputeDirtyState(); });

    connect(ui_->numSuggestion,
            QOverload<int>::of(&QSpinBox::valueChanged), this,
            [this](int) { recomputeDirtyState(); });
    connect(ui_->autoConvertMinChars,
            QOverload<int>::of(&QSpinBox::valueChanged), this,
            [this](int) { recomputeDirtyState(); });
    connect(ui_->numCandidatesPerPage,
            QOverload<int>::of(&QSpinBox::valueChanged), this,
            [this](int) { recomputeDirtyState(); });
    connect(ui_->zenzaiInferenceLimit,
            QOverload<int>::of(&QSpinBox::valueChanged), this,
            [this](int) { recomputeDirtyState(); });

    connect(ui_->stopStoreNewHistory, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->useProfileIndependentHistory, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->useRichSuggestion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->useRichCandidates, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->enableZenzai, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->zenzaiContextualConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->halfwidthKatakanaConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->extendedEmojiConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->commaSeparatedNumCoversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->calendarConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->timeConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->mailDomainConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->unicodeCodePointConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->romanTypographyConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->hazkeyVersionConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });
    connect(ui_->relativeDateConversion, &QCheckBox::toggled, this,
            [this](bool) { recomputeDirtyState(); });

    connect(ui_->zenzaiUserPlofile, &QLineEdit::textChanged, this,
            [this](const QString&) { recomputeDirtyState(); });
    connect(ui_->zenzaiTopic, &QLineEdit::textChanged, this,
            [this](const QString&) { recomputeDirtyState(); });
    connect(ui_->zenzaiStyle, &QLineEdit::textChanged, this,
            [this](const QString&) { recomputeDirtyState(); });
    connect(ui_->zenzaiPreference, &QLineEdit::textChanged, this,
            [this](const QString&) { recomputeDirtyState(); });
    connect(ui_->zenzaiWeightPath, &QLineEdit::textChanged, this,
            [this](const QString&) {
                updateConditioningUi();
                recomputeDirtyState();
            });

    connect(ui_->liveConvertHotkey, &QKeySequenceEdit::keySequenceChanged, this,
            [this](const QKeySequence&) { recomputeDirtyState(); });
    connect(ui_->deleteLearningHotkey, &QKeySequenceEdit::keySequenceChanged,
            this, [this](const QKeySequence&) { recomputeDirtyState(); });
    connect(ui_->acceptPredictionHotkey,
            &QKeySequenceEdit::keySequenceChanged, this,
            [this](const QKeySequence&) { recomputeDirtyState(); });
    connect(ui_->zenzaiToggleHotkey, &QKeySequenceEdit::keySequenceChanged,
            this, [this](const QKeySequence&) { recomputeDirtyState(); });
}

void MainWindow::onButtonClicked(QAbstractButton* button) {
    QDialogButtonBox::StandardButton standardButton = ui_->dialogButtonBox->standardButton(button);

    switch (standardButton) {
        case QDialogButtonBox::Ok:
            if (saveCurrentConfig()) {
                close();
            }
            break;
        case QDialogButtonBox::Apply:
            saveCurrentConfig();
            break;
        case QDialogButtonBox::Cancel:
            close();
            break;
        default:
            break;
    }
}

void MainWindow::onUseHistoryToggled(bool enabled) {
    ui_->stopStoreNewHistory->setEnabled(enabled);
    recomputeDirtyState();
}

void MainWindow::onUseZenzaiCustomWeightToggled(bool enabled) {
    const bool customWeightEnabled =
        enabled && ui_->useZenzaiCustomWeight->isEnabled();
    ui_->zenzaiWeightPath->setEnabled(customWeightEnabled);
    ui_->browseZenzaiWeightPath->setEnabled(customWeightEnabled);
    updateConditioningUi();
    recomputeDirtyState();
}

void MainWindow::onBrowseZenzaiWeightPath() {
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Select custom weight"), ui_->zenzaiWeightPath->text(),
        tr("GGUF files (*.gguf)"));
    if (!path.isEmpty()) {
        ui_->zenzaiWeightPath->setText(path);
    }
}

void MainWindow::onUseUserDictToggled(bool enabled) {
    ui_->userDictTable->setEnabled(enabled);
    ui_->userDictImport->setEnabled(enabled);
    ui_->userDictExport->setEnabled(enabled);
    ui_->userDictNewEntry->setEnabled(enabled);
    onUserDictSelectionChanged();
    recomputeDirtyState();
}

void MainWindow::updateZenzaiAvailabilityUi() {
    // AIタブ上の既存の警告ウィジェットを除去する
    if (ui_->aiTabScrollContentsLayout->count() > 1) {
        QLayoutItem* item = ui_->aiTabScrollContentsLayout->itemAt(1);
        if (item && item->widget()) {
            QWidget* widget = item->widget();
            if (widget->styleSheet().contains("background-color: yellow") ||
                widget->styleSheet().contains("background-color: lightblue")) {
                ui_->aiTabScrollContentsLayout->removeWidget(widget);
                widget->deleteLater();
            }
        }
    }

    if (currentConfig_.available_zenzai_backend_devices_size() <= 0) {
        ui_->enableZenzai->setEnabled(false);
        ui_->zenzaiContextualConversion->setEnabled(false);
        ui_->zenzaiInferenceLimit->setEnabled(false);
        ui_->zenzaiUserPlofile->setEnabled(false);
        ui_->zenzaiTopic->setEnabled(false);
        ui_->zenzaiStyle->setEnabled(false);
        ui_->zenzaiPreference->setEnabled(false);
        ui_->zenzaiUserProfileLabel->setEnabled(false);
        ui_->zenzaiTopicLabel->setEnabled(false);
        ui_->zenzaiStyleLabel->setEnabled(false);
        ui_->zenzaiPreferenceLabel->setEnabled(false);
        ui_->useZenzaiCustomWeight->setEnabled(false);
        ui_->zenzaiWeightPath->setEnabled(false);
        ui_->browseZenzaiWeightPath->setEnabled(false);
        ui_->zenzaiBackendDevice->setEnabled(false);
        ui_->zenzaiToggleHotkey->setEnabled(false);
        ui_->manageZenzaiModels->setEnabled(false);
        ui_->manageZenzaiModels->setVisible(false);

        QWidget* warningWidget = createWarningWidget(
            tr("<b>Warning:</b> Neural conversion support not installed."), "yellow");
        ui_->aiTabScrollContentsLayout->insertWidget(1, warningWidget);
    }
    else if (!currentConfig_.zenzai_model_available()) {
        ui_->enableZenzai->setEnabled(false);
        ui_->zenzaiContextualConversion->setEnabled(false);
        ui_->zenzaiInferenceLimit->setEnabled(false);
        ui_->zenzaiUserPlofile->setEnabled(false);
        ui_->zenzaiTopic->setEnabled(false);
        ui_->zenzaiStyle->setEnabled(false);
        ui_->zenzaiPreference->setEnabled(false);
        ui_->zenzaiUserProfileLabel->setEnabled(false);
        ui_->zenzaiTopicLabel->setEnabled(false);
        ui_->zenzaiStyleLabel->setEnabled(false);
        ui_->zenzaiPreferenceLabel->setEnabled(false);
        ui_->useZenzaiCustomWeight->setEnabled(false);
        ui_->zenzaiWeightPath->setEnabled(false);
        ui_->browseZenzaiWeightPath->setEnabled(false);
        ui_->zenzaiBackendDevice->setEnabled(false);
        ui_->zenzaiToggleHotkey->setEnabled(false);
        ui_->manageZenzaiModels->setEnabled(true);
        ui_->manageZenzaiModels->setVisible(false);

        QWidget* warningWidget = createWarningWidget(tr("<b>Warning:</b> Neural conversion model not found."),
                                                     "yellow",
                                                     tr("Download Model"),
                                                     [this]() { onDownloadZenzaiModel(); });
        ui_->aiTabScrollContentsLayout->insertWidget(1, warningWidget);
    }
    else {
        ui_->enableZenzai->setEnabled(true);
        ui_->zenzaiContextualConversion->setEnabled(true);
        ui_->zenzaiInferenceLimit->setEnabled(true);
        ui_->zenzaiUserPlofile->setEnabled(true);
        ui_->zenzaiTopic->setEnabled(true);
        ui_->zenzaiStyle->setEnabled(true);
        ui_->zenzaiPreference->setEnabled(true);
        ui_->zenzaiUserProfileLabel->setEnabled(true);
        ui_->zenzaiTopicLabel->setEnabled(true);
        ui_->zenzaiStyleLabel->setEnabled(true);
        ui_->zenzaiPreferenceLabel->setEnabled(true);
        ui_->useZenzaiCustomWeight->setEnabled(true);
        ui_->zenzaiBackendDevice->setEnabled(true);
        ui_->zenzaiToggleHotkey->setEnabled(true);
        ui_->manageZenzaiModels->setEnabled(true);
        ui_->manageZenzaiModels->setVisible(true);

        // 条件付け非対応モデル (Jinen系等) では条件4項目だけを追加で無効化する
        updateConditioningUi();

        // チェックサム比較でモデルの更新要否を判定する
        // インストール済みモデルが既知の旧世代エントリ (例: zenz-v3.1) と一致した場合のみユーザに通知する
        // カスタムモデルや現行世代モデル (推奨モデルやxsmall等の正規バリアント含む) には何も表示しない
        QString modelPath = QString::fromStdString(currentConfig_.zenzai_model_path());
        if (!modelPath.isEmpty()) {
            const QString currentChecksum = ZenzaiModelManager::calculateSHA256(modelPath);
            if (!currentChecksum.isEmpty()) {
                const QVector<ZenzaiModelOption>& models = availableZenzaiModels();
                bool isLegacyGen = false;
                for (const ZenzaiModelOption& m : models) {
                    if (m.sha256.compare(currentChecksum, Qt::CaseInsensitive) == 0) {
                        isLegacyGen = m.isLegacyGen;
                        break;
                    }
                }
                if (isLegacyGen) {
                    QWidget* warningWidget = createWarningWidget(tr("The current model is not the latest version."),
                                                                 "lightblue", tr("Download Update"),
                                                                 [this]() { onDownloadZenzaiModel(); });
                    ui_->aiTabScrollContentsLayout->insertWidget(1, warningWidget);
                }
            }
        }
    }
}

void MainWindow::updateConditioningUi() {
    // AIタブ全体が無効な場合はupdateZenzaiAvailabilityUi()が全項目を無効化済み
    if (!ui_->enableZenzai->isEnabled()) {
        return;
    }

    const QString customPath   = ui_->zenzaiWeightPath->text().trimmed();
    const bool useCustomWeight = ui_->useZenzaiCustomWeight->isChecked() && !customPath.isEmpty();
    bool supported = true;

    if (useCustomWeight) {
        // カタログ外のカスタム重みはファイル名で推定する
        supported = !isJinenModelPath(customPath);
    }
    else {
        supported = zenzaiModelSupportsConditioning(ZenzaiModelManager::getActiveModelKey());
    }

    ui_->zenzaiUserPlofile->setEnabled(supported);
    ui_->zenzaiTopic->setEnabled(supported);
    ui_->zenzaiStyle->setEnabled(supported);
    ui_->zenzaiPreference->setEnabled(supported);
    ui_->zenzaiUserProfileLabel->setEnabled(supported);
    ui_->zenzaiTopicLabel->setEnabled(supported);
    ui_->zenzaiStyleLabel->setEnabled(supported);
    ui_->zenzaiPreferenceLabel->setEnabled(supported);

    const QString reason = supported ? QString() : tr("Not supported by the active model.");

    ui_->zenzaiUserPlofile->setToolTip(reason);
    ui_->zenzaiTopic->setToolTip(reason);
    ui_->zenzaiStyle->setToolTip(reason);
    ui_->zenzaiPreference->setToolTip(reason);
}

bool MainWindow::loadCurrentConfig(bool fetchConfig) {
    if (fetchConfig) {
        auto configOpt = server_.getConfig();
        if (!configOpt.has_value()) {
            return false;
        }

        currentConfig_ = configOpt.value();
        if (currentConfig_.profiles_size() == 0) {
            return false;
        }

        currentProfile_ = currentConfig_.mutable_profiles(0);
        if (!currentProfile_) {
            return false;
        }
    }

    // 設定からUIへの流し込みはプログラムの動作であり、シグナルハンドラがユーザの未保存編集として報告してはならない
    setConfigLoading(true);

    updateZenzaiAvailabilityUi();

    // Zenzaiバックエンドデバイスを読み込む
    ui_->zenzaiBackendDevice->clear();
    for (int i = 0; i < currentConfig_.available_zenzai_backend_devices_size();
         ++i) {
        const auto& device = currentConfig_.available_zenzai_backend_devices(i);
        QString deviceName = QString::fromStdString(device.name());
        QString deviceDesc = QString::fromStdString(device.desc());
        QString displayText = deviceName;
        if (!deviceDesc.isEmpty()) {
            displayText += " : " + deviceDesc;
        }
        ui_->zenzaiBackendDevice->addItem(displayText, deviceName);
    }

    // 現在のデバイス選択を設定する
    QString currentDevice =
        QString::fromStdString(currentProfile_->zenzai_backend_device_name());
    if (!currentDevice.isEmpty()) {
        int index = ui_->zenzaiBackendDevice->findData(currentDevice);
        if (index >= 0) {
            ui_->zenzaiBackendDevice->setCurrentIndex(index);
        }
    }

    SET_COMBO_FROM_CONFIG(ConfigDefs::AutoConvertMode, ui_->autoConvertion, currentProfile_->auto_convert_mode());
    SET_COMBO_FROM_CONFIG(ConfigDefs::AuxTextMode, ui_->auxiliaryText, currentProfile_->aux_text_mode());
    SET_COMBO_FROM_CONFIG(ConfigDefs::SuggestionListMode, ui_->suggestionList, currentProfile_->suggestion_list_mode());

    SET_SPINBOX(ui_->numSuggestion, currentProfile_->num_suggestions(), ConfigDefs::SpinboxDefaults::NUM_SUGGESTIONS);
    const int autoConvertMinChars = currentProfile_->auto_convert_min_chars();
    SET_SPINBOX(ui_->autoConvertMinChars,
                autoConvertMinChars > 0
                    ? autoConvertMinChars
                    : ConfigDefs::SpinboxDefaults::AUTO_CONVERT_MIN_CHARS,
                ConfigDefs::SpinboxDefaults::AUTO_CONVERT_MIN_CHARS);
    SET_SPINBOX(ui_->numCandidatesPerPage,
                currentProfile_->num_candidates_per_page(),
                ConfigDefs::SpinboxDefaults::NUM_CANDIDATES_PER_PAGE);
    SET_SPINBOX(ui_->zenzaiInferenceLimit,
                currentProfile_->zenzai_infer_limit(),
                ConfigDefs::SpinboxDefaults::ZENZAI_INFERENCE_LIMIT);

    SET_CHECKBOX(ui_->useHistory, currentProfile_->use_input_history(),
                 ConfigDefs::CheckboxDefaults::USE_HISTORY);
    SET_CHECKBOX(ui_->stopStoreNewHistory,
                 currentProfile_->stop_store_new_history(),
                 ConfigDefs::CheckboxDefaults::STOP_STORE_NEW_HISTORY);
    SET_CHECKBOX(ui_->useProfileIndependentHistory,
                 currentProfile_->use_profile_independent_history(),
                 ConfigDefs::CheckboxDefaults::USE_PROFILE_INDEPENDENT_HISTORY);
    SET_CHECKBOX(ui_->useRichSuggestion, currentProfile_->use_rich_suggestion(),
                 ConfigDefs::CheckboxDefaults::USE_RICH_SUGGESTION);
    SET_CHECKBOX(ui_->useRichCandidates, currentProfile_->use_rich_candidates(),
                 ConfigDefs::CheckboxDefaults::USE_RICH_CANDIDATES);
    SET_CHECKBOX(ui_->enableZenzai, currentProfile_->zenzai_enable(),
                 ConfigDefs::CheckboxDefaults::ENABLE_ZENZAI);
    SET_CHECKBOX(ui_->zenzaiContextualConversion,
                 currentProfile_->zenzai_contextual_mode(),
                 ConfigDefs::CheckboxDefaults::ZENZAI_CONTEXTUAL);
    SET_CHECKBOX(ui_->useZenzaiCustomWeight,
                 currentProfile_->use_zenzai_custom_weight(),
                 ConfigDefs::CheckboxDefaults::USE_ZENZAI_CUSTOM_WEIGHT);

    const bool useUserDict = currentProfile_->has_use_user_dictionary()
                                 ? currentProfile_->use_user_dictionary()
                                 : true;
    SET_CHECKBOX(ui_->useUserDict, useUserDict, true);
    onUseUserDictToggled(useUserDict);

    auto specialConversions = &currentProfile_->special_conversion_mode();
    SET_CHECKBOX(ui_->halfwidthKatakanaConversion,
                 specialConversions->halfwidth_katakana(),
                 ConfigDefs::CheckboxDefaults::HALFWIDTH_KATAKANA);
    const bool extendedEmoji = specialConversions->has_extended_emoji()
                                   ? specialConversions->extended_emoji()
                                   : ConfigDefs::CheckboxDefaults::EXTENDED_EMOJI;
    SET_CHECKBOX(ui_->extendedEmojiConversion, extendedEmoji,
                 ConfigDefs::CheckboxDefaults::EXTENDED_EMOJI);
    SET_CHECKBOX(ui_->commaSeparatedNumCoversion,
                 specialConversions->comma_separated_number(),
                 ConfigDefs::CheckboxDefaults::COMMA_SEPARATED_NUMBER);
    SET_CHECKBOX(ui_->calendarConversion, specialConversions->calendar(),
                 ConfigDefs::CheckboxDefaults::CALENDER);
    SET_CHECKBOX(ui_->timeConversion, specialConversions->time(),
                 ConfigDefs::CheckboxDefaults::TIME);
    SET_CHECKBOX(ui_->mailDomainConversion, specialConversions->mail_domain(),
                 ConfigDefs::CheckboxDefaults::MAIL_DOMAIN);
    SET_CHECKBOX(ui_->unicodeCodePointConversion,
                 specialConversions->unicode_codepoint(),
                 ConfigDefs::CheckboxDefaults::UNICODE_CODEPOINT);
    SET_CHECKBOX(ui_->romanTypographyConversion,
                 specialConversions->roman_typography(),
                 ConfigDefs::CheckboxDefaults::ROMAN_TYPOGRAPHY);
    SET_CHECKBOX(ui_->hazkeyVersionConversion,
                 specialConversions->hazkey_version(),
                 ConfigDefs::CheckboxDefaults::HAZKEY_VERSION);
    SET_CHECKBOX(ui_->relativeDateConversion,
                 specialConversions->relative_date(),
                 ConfigDefs::CheckboxDefaults::RELATIVE_DATE);

    ui_->stopStoreNewHistory->setEnabled(currentProfile_->use_input_history());
    onUseZenzaiCustomWeightToggled(ui_->useZenzaiCustomWeight->isChecked());

    SET_LINEEDIT(ui_->submodeEntryPointChars,
                 currentProfile_->submode_entry_point_chars(),
                 "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    SET_LINEEDIT(ui_->zenzaiUserPlofile, currentProfile_->zenzai_profile(), "");
    SET_LINEEDIT(ui_->zenzaiTopic, currentProfile_->zenzai_topic(), "");
    SET_LINEEDIT(ui_->zenzaiStyle, currentProfile_->zenzai_style(), "");
    SET_LINEEDIT(ui_->zenzaiPreference, currentProfile_->zenzai_preference(), "");
    SET_LINEEDIT(ui_->zenzaiWeightPath, currentProfile_->zenzai_weight_path(), "");

    {
        const std::string storedHotkey = currentProfile_->auto_convert_hotkey();
        const QString fcitxStr = QString::fromStdString(
            storedHotkey.empty() ? "Control+Shift+L" : storedHotkey);
        ui_->liveConvertHotkey->setKeySequence(
            qKeySequenceFromFcitxKeyString(fcitxStr));
    }

    {
        // 学習データ削除ホットキー
        // 空の場合はクライアント内蔵の既定値を使用する
        const std::string storedDeleteHotkey = currentProfile_->delete_learning_hotkey();
        const QString fcitxStr = QString::fromStdString(
        storedDeleteHotkey.empty() ? "Control+D" : storedDeleteHotkey);
        ui_->deleteLearningHotkey->setKeySequence(qKeySequenceFromFcitxKeyString(fcitxStr));
    }

    {
        // 予測候補確定ホットキー
        // 空の場合はクライアント内蔵の既定値を使用する
        const std::string storedAcceptHotkey = currentProfile_->accept_prediction_hotkey();
        const QString fcitxAcceptStr = QString::fromStdString(storedAcceptHotkey.empty() ? "F5" : storedAcceptHotkey);
        ui_->acceptPredictionHotkey->setKeySequence(qKeySequenceFromFcitxKeyString(fcitxAcceptStr));
    }

    {
        // ニューラル変換切替ホットキー
        // 空の場合はクライアント内蔵の既定値を使用する
        const std::string storedZenzaiToggleHotkey = currentProfile_->zenzai_toggle_hotkey();
        const QString fcitxZenzaiToggleStr = QString::fromStdString(storedZenzaiToggleHotkey.empty() ? "Control+Alt+Z"
                                                                                                     : storedZenzaiToggleHotkey);
        ui_->zenzaiToggleHotkey->setKeySequence(qKeySequenceFromFcitxKeyString(fcitxZenzaiToggleStr));
    }

    // 入力テーブル設定を読み込む
    loadInputTables();

    // キーマップ設定を読み込む
    loadKeymaps();

    // 注記ラベル内のXDG_CONFIG_HOMEを更新する
    QString xdgConfigHome = QString::fromStdString(currentConfig_.xdg_config_home_path());
    if (!xdgConfigHome.isEmpty()) {
        // 末尾のスラッシュを除去して二重スラッシュを避ける
        if (xdgConfigHome.endsWith('/')) {
            xdgConfigHome.chop(1);
        }

        QString keymapNoteText = ui_->keymapAdvancedNote->text();
        keymapNoteText.replace("$XDG_CONFIG_HOME/hazkey", xdgConfigHome);
        ui_->keymapAdvancedNote->setText(keymapNoteText);

        QString inputTableNoteText = ui_->inputTableAdvancedNote->text();
        inputTableNoteText.replace("$XDG_CONFIG_HOME/hazkey", xdgConfigHome);
        ui_->inputTableAdvancedNote->setText(inputTableNoteText);
    }

    // Advancedタブの設定をBasicタブへ同期する
    syncAdvancedToBasic();

    setConfigLoading(false);

    // サーバからの新規取得で保存済み基準値を確立する
    // Resetプレビュー (fetchConfig == false) では更新しないため、保存済み設定と異なる既定プレビューでもApplyが有効のままになる
    if (fetchConfig) {
        updateBaseline();
    }

    recomputeDirtyState();

    return true;
}

bool MainWindow::saveCurrentConfig() {
    if (!currentProfile_) {
        QMessageBox::warning(this, tr("Error"), tr("No configuration profile loaded."));
        return false;
    }

    currentProfile_->set_auto_convert_mode(
        GET_COMBO_TO_CONFIG(ConfigDefs::AutoConvertMode, ui_->autoConvertion));
    currentProfile_->set_aux_text_mode(
        GET_COMBO_TO_CONFIG(ConfigDefs::AuxTextMode, ui_->auxiliaryText));
    currentProfile_->set_suggestion_list_mode(GET_COMBO_TO_CONFIG(
        ConfigDefs::SuggestionListMode, ui_->suggestionList));

    currentProfile_->set_num_suggestions(GET_SPINBOX_INT(ui_->numSuggestion));
    currentProfile_->set_auto_convert_min_chars(
        GET_SPINBOX_INT(ui_->autoConvertMinChars));
    currentProfile_->set_num_candidates_per_page(
        GET_SPINBOX_INT(ui_->numCandidatesPerPage));
    currentProfile_->set_zenzai_infer_limit(
        GET_SPINBOX_INT(ui_->zenzaiInferenceLimit));

    currentProfile_->set_use_input_history(GET_CHECKBOX_BOOL(ui_->useHistory));
    currentProfile_->set_stop_store_new_history(
        GET_CHECKBOX_BOOL(ui_->stopStoreNewHistory));
    currentProfile_->set_use_profile_independent_history(
        GET_CHECKBOX_BOOL(ui_->useProfileIndependentHistory));
    currentProfile_->set_use_rich_suggestion(
        GET_CHECKBOX_BOOL(ui_->useRichSuggestion));
    currentProfile_->set_use_rich_candidates(
        GET_CHECKBOX_BOOL(ui_->useRichCandidates));
    currentProfile_->set_zenzai_enable(GET_CHECKBOX_BOOL(ui_->enableZenzai));
    currentProfile_->set_zenzai_contextual_mode(
        GET_CHECKBOX_BOOL(ui_->zenzaiContextualConversion));
    currentProfile_->set_use_zenzai_custom_weight(
        GET_CHECKBOX_BOOL(ui_->useZenzaiCustomWeight));
    currentProfile_->set_use_user_dictionary(GET_CHECKBOX_BOOL(ui_->useUserDict));

    auto* specialConversions =
        currentProfile_->mutable_special_conversion_mode();
    specialConversions->set_halfwidth_katakana(
        GET_CHECKBOX_BOOL(ui_->halfwidthKatakanaConversion));
    specialConversions->set_extended_emoji(
        GET_CHECKBOX_BOOL(ui_->extendedEmojiConversion));
    specialConversions->set_comma_separated_number(
        GET_CHECKBOX_BOOL(ui_->commaSeparatedNumCoversion));
    specialConversions->set_calendar(
        GET_CHECKBOX_BOOL(ui_->calendarConversion));
    specialConversions->set_time(GET_CHECKBOX_BOOL(ui_->timeConversion));
    specialConversions->set_mail_domain(
        GET_CHECKBOX_BOOL(ui_->mailDomainConversion));
    specialConversions->set_unicode_codepoint(
        GET_CHECKBOX_BOOL(ui_->unicodeCodePointConversion));
    specialConversions->set_roman_typography(
        GET_CHECKBOX_BOOL(ui_->romanTypographyConversion));
    specialConversions->set_hazkey_version(
        GET_CHECKBOX_BOOL(ui_->hazkeyVersionConversion));
    specialConversions->set_relative_date(
        GET_CHECKBOX_BOOL(ui_->relativeDateConversion));

    currentProfile_->set_submode_entry_point_chars(
        GET_LINEEDIT_STRING(ui_->submodeEntryPointChars));
    currentProfile_->set_zenzai_profile(
        GET_LINEEDIT_STRING(ui_->zenzaiUserPlofile));
    currentProfile_->set_zenzai_topic(GET_LINEEDIT_STRING(ui_->zenzaiTopic));
    currentProfile_->set_zenzai_style(GET_LINEEDIT_STRING(ui_->zenzaiStyle));
    currentProfile_->set_zenzai_preference(
        GET_LINEEDIT_STRING(ui_->zenzaiPreference));
    currentProfile_->set_zenzai_weight_path(
        GET_LINEEDIT_STRING(ui_->zenzaiWeightPath));
    currentProfile_->set_auto_convert_hotkey(
        fcitxKeyStringFromQKeySequence(ui_->liveConvertHotkey->keySequence())
            .toStdString());
    currentProfile_->set_delete_learning_hotkey(
        fcitxKeyStringFromQKeySequence(
            ui_->deleteLearningHotkey->keySequence())
            .toStdString());
    currentProfile_->set_accept_prediction_hotkey(
        fcitxKeyStringFromQKeySequence(
            ui_->acceptPredictionHotkey->keySequence())
            .toStdString());
    currentProfile_->set_zenzai_toggle_hotkey(
        fcitxKeyStringFromQKeySequence(ui_->zenzaiToggleHotkey->keySequence())
            .toStdString());

    // AIモデルバックエンドデバイスを保存する
    QString selectedDevice = ui_->zenzaiBackendDevice->currentData().toString();
    currentProfile_->set_zenzai_backend_device_name(selectedDevice.toStdString());

    // 入力テーブル設定を保存する
    saveInputTables();

    // キーマップ設定を保存する
    saveKeymaps();

    // サーバへ保存する
    try {
        server_.setCurrentConfig(currentConfig_);
        // 成功した保存でのみ基準値を更新する
        // 失敗時は基準値と[Apply]ボタンをそのままにしてユーザが再試行できるようにする
        updateBaseline();
        recomputeDirtyState();
        return true;
    }
    catch (const std::exception& e) {
        QMessageBox::critical(this, tr("Save Error"), tr("Failed to save configuration: %1").arg(e.what()));
        return false;
    }
    catch (...) {
        QMessageBox::critical(this, tr("Save Error"), tr("An unknown error occurred while saving configuration."));
        return false;
    }
}

void MainWindow::setupInputTableLists() {
    // ダブルクリックで一覧間を移動できるようにする
    connect(ui_->enabledTableList, &QListWidget::itemDoubleClicked, this, &MainWindow::onDisableTable);
    connect(ui_->availableTableList, &QListWidget::itemDoubleClicked, this, &MainWindow::onEnableTable);

    // 初期のボタン状態を更新する
    updateTableButtonStates();
}

void MainWindow::loadInputTables() {
    if (!currentProfile_) {
        return;
    }

    // 既存の項目を消去する
    ui_->enabledTableList->clear();
    ui_->availableTableList->clear();

    // 高速照合用の集合を作る
    // 一意性には (名前, 組込フラグ) の組を使用する
    QSet<QPair<QString, bool>> enabledTableKeys;

    // 有効なテーブルを読み込む
    for (int i = 0; i < currentProfile_->enabled_tables_size(); ++i) {
        const auto& enabledTable = currentProfile_->enabled_tables(i);
        QString tableName        = QString::fromStdString(enabledTable.name());
        bool isBuiltIn           = enabledTable.is_built_in();
        enabledTableKeys.insert(QPair<QString, bool>(tableName, isBuiltIn));

        QString displayName = translateTableName(tableName, enabledTable.is_built_in());
        QListWidgetItem* item = new QListWidgetItem(displayName);

        // このテーブルが利用可能か確認する
        bool isAvailable = false;

        for (int j = 0; j < currentConfig_.available_tables_size(); ++j) {
            const auto& availableTable = currentConfig_.available_tables(j);
            if (availableTable.name() == enabledTable.name() &&
                availableTable.is_built_in() == enabledTable.is_built_in()) {
                isAvailable = true;
                break;
            }
        }

        // 状態に応じて項目の見た目を設定する
        if (isBuiltIn) {
            displayName = displayName + " " + tr("[built-in]");
        }

        if (!isAvailable) {
            displayName = displayName + " " + tr("[not found]");
            item->setForeground(QColor(Qt::red));
        }

        item->setText(displayName);

        // 元の名前とメタ情報を保持する
        item->setData(Qt::UserRole, tableName);
        item->setData(Qt::UserRole + 1, isBuiltIn);
        item->setData(Qt::UserRole + 2, isAvailable);

        ui_->enabledTableList->addItem(item);
    }

    // 利用可能なテーブルを読み込む (有効化済みを除く)
    for (int i = 0; i < currentConfig_.available_tables_size(); ++i) {
        const auto& availableTable = currentConfig_.available_tables(i);
        QString tableName = QString::fromStdString(availableTable.name());
        bool isBuiltIn = availableTable.is_built_in();
        QPair<QString, bool> tableKey(tableName, isBuiltIn);

        if (!enabledTableKeys.contains(tableKey)) {
            QString displayName = translateTableName(tableName, availableTable.is_built_in());
            QListWidgetItem* item = new QListWidgetItem(displayName);

            if (availableTable.is_built_in()) {
                item->setText(displayName + " " + tr("[built-in]"));
            }

            // メタ情報を保持する
            item->setData(Qt::UserRole, tableName);
            item->setData(Qt::UserRole + 1, availableTable.is_built_in());
            item->setData(Qt::UserRole + 2, true);  // 利用可能

            ui_->availableTableList->addItem(item);
        }
    }

    updateTableButtonStates();
}

void MainWindow::saveInputTables() {
    if (!currentProfile_) {
        return;
    }

    // 既存の有効テーブルを消去する
    currentProfile_->clear_enabled_tables();

    // 有効なテーブルを順序通りに保存する
    for (int i = 0; i < ui_->enabledTableList->count(); ++i) {
        QListWidgetItem* item = ui_->enabledTableList->item(i);
        QString tableName = item->data(Qt::UserRole).toString();
        bool isBuiltIn = item->data(Qt::UserRole + 1).toBool();
        bool isAvailable = item->data(Qt::UserRole + 2).toBool();

        auto* enabledTable = currentProfile_->add_enabled_tables();
        enabledTable->set_name(tableName.toStdString());
        enabledTable->set_is_built_in(isBuiltIn);

        // 利用可能なら利用可能テーブルからファイル名を探す
        if (isAvailable) {
            for (int j = 0; j < currentConfig_.available_tables_size(); ++j) {
                const auto& availableTable = currentConfig_.available_tables(j);
                if (availableTable.name() == tableName.toStdString() &&
                    availableTable.is_built_in() == isBuiltIn) {
                    enabledTable->set_filename(availableTable.filename());
                    break;
                }
            }
        }
    }
}

void MainWindow::onEnableTable() {
    QListWidgetItem* item = ui_->availableTableList->currentItem();
    if (!item) {
        return;
    }

    // 項目を利用可能一覧から有効一覧へ移動する
    int row = ui_->availableTableList->row(item);
    ui_->availableTableList->takeItem(row);
    ui_->enabledTableList->addItem(item);

    updateTableButtonStates();
    saveInputTables();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onDisableTable() {
    QListWidgetItem* item = ui_->enabledTableList->currentItem();
    if (!item) {
        return;
    }

    // テーブルが実際に利用可能な場合のみ利用可能一覧へ戻す
    bool isAvailable = item->data(Qt::UserRole + 2).toBool();

    int row = ui_->enabledTableList->row(item);
    ui_->enabledTableList->takeItem(row);

    if (isAvailable) {
        // 利用可能一覧向けに表示テキストを戻す
        QString tableName = item->data(Qt::UserRole).toString();
        bool isBuiltIn = item->data(Qt::UserRole + 1).toBool();
        QString displayName = translateTableName(tableName, isBuiltIn);

        if (isBuiltIn) {
            item->setText(displayName + " " + tr("[built-in]"));
        }
        else {
            item->setText(displayName);
        }

        item->setForeground(QColor());  // 色を戻す

        ui_->availableTableList->addItem(item);
    }
    else {
        // テーブルが利用可能でなければ項目を削除する
        delete item;
    }

    updateTableButtonStates();
    saveInputTables();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onTableMoveUp() {
    QListWidgetItem* item = ui_->enabledTableList->currentItem();
    if (!item) {
        return;
    }

    int row = ui_->enabledTableList->row(item);
    if (row > 0) {
        ui_->enabledTableList->takeItem(row);
        ui_->enabledTableList->insertItem(row - 1, item);
        ui_->enabledTableList->setCurrentItem(item);
    }

    updateTableButtonStates();
    saveInputTables();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onTableMoveDown() {
    QListWidgetItem* item = ui_->enabledTableList->currentItem();
    if (!item) {
        return;
    }

    int row = ui_->enabledTableList->row(item);
    if (row < ui_->enabledTableList->count() - 1) {
        ui_->enabledTableList->takeItem(row);
        ui_->enabledTableList->insertItem(row + 1, item);
        ui_->enabledTableList->setCurrentItem(item);
    }

    updateTableButtonStates();
    saveInputTables();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onEnabledTableSelectionChanged() { updateTableButtonStates(); }

void MainWindow::onAvailableTableSelectionChanged() {
    updateTableButtonStates();
}

void MainWindow::updateTableButtonStates() {
    QListWidgetItem* enabledItem = ui_->enabledTableList->currentItem();
    QListWidgetItem* availableItem = ui_->availableTableList->currentItem();

    // 選択と位置に応じてボタンの有効 / 無効を切り替える
    ui_->disableTable->setEnabled(enabledItem != nullptr);
    ui_->enableTable->setEnabled(availableItem != nullptr);

    if (enabledItem) {
        int row = ui_->enabledTableList->row(enabledItem);
        ui_->tableMoveUp->setEnabled(row > 0);
        ui_->tableMoveDown->setEnabled(row < ui_->enabledTableList->count() - 1);
    }
    else {
        ui_->tableMoveUp->setEnabled(false);
        ui_->tableMoveDown->setEnabled(false);
    }
}

void MainWindow::setupKeymapLists() {
    // ダブルクリックで一覧間を移動できるようにする
    connect(ui_->enabledKeymapList, &QListWidget::itemDoubleClicked, this, &MainWindow::onDisableKeymap);
    connect(ui_->availableKeymapList, &QListWidget::itemDoubleClicked, this, &MainWindow::onEnableKeymap);

    // 初期のボタン状態を更新する
    updateKeymapButtonStates();
}

void MainWindow::loadKeymaps() {
    if (!currentProfile_) {
        return;
    }

    // 既存の項目を消去する
    ui_->enabledKeymapList->clear();
    ui_->availableKeymapList->clear();

    // 高速照合用の集合を作る
    QSet<QPair<QString, bool>> enabledKeymapKeys;

    // 有効なキーマップを読み込む
    for (int i = 0; i < currentProfile_->enabled_keymaps_size(); ++i) {
        const auto& enabledKeymap = currentProfile_->enabled_keymaps(i);
        QString keymapName = QString::fromStdString(enabledKeymap.name());
        bool isBuiltIn = enabledKeymap.is_built_in();
        enabledKeymapKeys.insert(QPair<QString, bool>(keymapName, isBuiltIn));

        QString displayName = translateKeymapName(keymapName, enabledKeymap.is_built_in());
        QListWidgetItem* item = new QListWidgetItem(displayName);

        // このキーマップが利用可能か確認する
        bool isAvailable = false;

        for (int j = 0; j < currentConfig_.available_keymaps_size(); ++j) {
            const auto& availableKeymap = currentConfig_.available_keymaps(j);
            if (availableKeymap.name() == enabledKeymap.name() &&
                availableKeymap.is_built_in() == enabledKeymap.is_built_in()) {
                isAvailable = true;
                isBuiltIn = availableKeymap.is_built_in();
                break;
            }
        }

        // 状態に応じて項目の見た目を設定する
        if (isBuiltIn) {
            displayName = displayName + " " + tr("[built-in]");
        }

        if (!isAvailable) {
            displayName = displayName + " " + tr("[not found]");
            item->setForeground(QColor(Qt::red));
        }

        item->setText(displayName);

        // 元の名前とメタ情報を保持する
        item->setData(Qt::UserRole, keymapName);
        item->setData(Qt::UserRole + 1, isBuiltIn);
        item->setData(Qt::UserRole + 2, isAvailable);

        ui_->enabledKeymapList->addItem(item);
    }

    // 利用可能なキーマップを読み込む(有効化済みを除く)
    for (int i = 0; i < currentConfig_.available_keymaps_size(); ++i) {
        const auto& availableKeymap = currentConfig_.available_keymaps(i);
        QString keymapName = QString::fromStdString(availableKeymap.name());
        bool isBuiltIn = availableKeymap.is_built_in();
        QPair<QString, bool> keymapKey(keymapName, isBuiltIn);

        if (!enabledKeymapKeys.contains(keymapKey)) {
            QString displayName = translateKeymapName(keymapName, availableKeymap.is_built_in());
            QListWidgetItem* item = new QListWidgetItem(displayName);

            if (availableKeymap.is_built_in()) {
                item->setText(displayName + " " + tr("[built-in]"));
            }

            // メタ情報を保持する
            item->setData(Qt::UserRole, keymapName);
            item->setData(Qt::UserRole + 1, availableKeymap.is_built_in());
            item->setData(Qt::UserRole + 2, true);  // 利用可能

            ui_->availableKeymapList->addItem(item);
        }
    }

    updateKeymapButtonStates();
}

void MainWindow::saveKeymaps() {
    if (!currentProfile_) {
        return;
    }

    // 既存の有効キーマップを消去する
    currentProfile_->clear_enabled_keymaps();

    // 有効なキーマップを順序通りに保存する
    for (int i = 0; i < ui_->enabledKeymapList->count(); ++i) {
        QListWidgetItem* item = ui_->enabledKeymapList->item(i);
        QString keymapName = item->data(Qt::UserRole).toString();
        bool isBuiltIn = item->data(Qt::UserRole + 1).toBool();
        bool isAvailable = item->data(Qt::UserRole + 2).toBool();

        auto* enabledKeymap = currentProfile_->add_enabled_keymaps();
        enabledKeymap->set_name(keymapName.toStdString());
        enabledKeymap->set_is_built_in(isBuiltIn);

        // 利用可能なら利用可能キーマップからファイル名を探す
        if (isAvailable) {
            for (int j = 0; j < currentConfig_.available_keymaps_size(); ++j) {
                const auto& availableKeymap = currentConfig_.available_keymaps(j);
                if (availableKeymap.name() == keymapName.toStdString() &&
                    availableKeymap.is_built_in() == isBuiltIn) {
                    enabledKeymap->set_filename(availableKeymap.filename());
                    break;
                }
            }
        }
    }
}

void MainWindow::onEnableKeymap() {
    QListWidgetItem* item = ui_->availableKeymapList->currentItem();
    if (!item) {
        return;
    }

    // 項目を利用可能一覧から有効一覧へ移動する
    int row = ui_->availableKeymapList->row(item);
    ui_->availableKeymapList->takeItem(row);
    ui_->enabledKeymapList->addItem(item);

    updateKeymapButtonStates();
    saveKeymaps();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onDisableKeymap() {
    QListWidgetItem* item = ui_->enabledKeymapList->currentItem();
    if (!item) {
        return;
    }

    // キーマップが実際に利用可能な場合のみ利用可能一覧へ戻す
    bool isAvailable = item->data(Qt::UserRole + 2).toBool();

    int row = ui_->enabledKeymapList->row(item);
    ui_->enabledKeymapList->takeItem(row);

    if (isAvailable) {
        // 利用可能一覧向けに表示テキストを戻す
        QString keymapName = item->data(Qt::UserRole).toString();
        bool isBuiltIn = item->data(Qt::UserRole + 1).toBool();
        QString displayName = translateKeymapName(keymapName, isBuiltIn);

        if (isBuiltIn) {
            item->setText(displayName + " " + tr("[built-in]"));
        }
        else {
            item->setText(displayName);
        }

        item->setForeground(QColor());  // 色を戻す

        ui_->availableKeymapList->addItem(item);
    }
    else {
        // キーマップが利用可能でなければ項目を削除する
        delete item;
    }

    updateKeymapButtonStates();
    saveKeymaps();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onKeymapMoveUp() {
    QListWidgetItem* item = ui_->enabledKeymapList->currentItem();
    if (!item) {
        return;
    }

    int row = ui_->enabledKeymapList->row(item);
    if (row > 0) {
        ui_->enabledKeymapList->takeItem(row);
        ui_->enabledKeymapList->insertItem(row - 1, item);
        ui_->enabledKeymapList->setCurrentItem(item);
    }

    updateKeymapButtonStates();
    saveKeymaps();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onKeymapMoveDown() {
    QListWidgetItem* item = ui_->enabledKeymapList->currentItem();
    if (!item) {
        return;
    }

    int row = ui_->enabledKeymapList->row(item);
    if (row < ui_->enabledKeymapList->count() - 1) {
        ui_->enabledKeymapList->takeItem(row);
        ui_->enabledKeymapList->insertItem(row + 1, item);
        ui_->enabledKeymapList->setCurrentItem(item);
    }

    updateKeymapButtonStates();
    saveKeymaps();
    syncAdvancedToBasic();
    recomputeDirtyState();
}

void MainWindow::onEnabledKeymapSelectionChanged() {
    updateKeymapButtonStates();
}

void MainWindow::onAvailableKeymapSelectionChanged() {
    updateKeymapButtonStates();
}

void MainWindow::updateKeymapButtonStates() {
    QListWidgetItem* enabledItem = ui_->enabledKeymapList->currentItem();
    QListWidgetItem* availableItem = ui_->availableKeymapList->currentItem();

    // 選択と位置に応じてボタンの有効 / 無効を切り替える
    ui_->disableKeymap->setEnabled(enabledItem != nullptr);
    ui_->enableKeymap->setEnabled(availableItem != nullptr);

    if (enabledItem) {
        int row = ui_->enabledKeymapList->row(enabledItem);
        ui_->keymapMoveUp->setEnabled(row > 0);
        ui_->keymapMoveDown->setEnabled(row < ui_->enabledKeymapList->count() - 1);
    }
    else {
        ui_->keymapMoveUp->setEnabled(false);
        ui_->keymapMoveDown->setEnabled(false);
    }
}

// Basicタブのイベントハンドラ
void MainWindow::onSubmodeEntryChanged() {
    if (isUpdatingFromAdvanced_) return;

    // 新しいサブモード入口値でcurrentProfileを更新する
    if (currentProfile_) {
        currentProfile_->set_submode_entry_point_chars(ui_->submodeEntryPointChars->text().toStdString());

        // 互換性を確認して警告表示を更新する
        syncAdvancedToBasic();
    }
    recomputeDirtyState();
}

void MainWindow::onBasicInputStyleChanged() {
    if (isUpdatingFromAdvanced_) return;

    // 入力形式に応じて他の選択肢の有効 / 無効を切り替える
    bool isKana = (ui_->mainInputStyle->currentIndex() == 1);  // JISかな

    // かなモードではSpace形式のみ変更できる
    ui_->punctuationStyle->setEnabled(!isKana);
    ui_->numberStyle->setEnabled(!isKana);
    ui_->commonSymbolStyle->setEnabled(!isKana);

    // 無効状態が分かるようラベルを更新する
    if (isKana) {
        ui_->punctuationStyle->setToolTip(tr("Disabled in Kana mode"));
        ui_->numberStyle->setToolTip(tr("Disabled in Kana mode"));
        ui_->commonSymbolStyle->setToolTip(tr("Disabled in Kana mode"));
    }
    else {
        ui_->punctuationStyle->setToolTip("");
        ui_->numberStyle->setToolTip("");
        ui_->commonSymbolStyle->setToolTip("");
    }

    syncBasicToAdvanced();
    recomputeDirtyState();
}

void MainWindow::onBasicSettingChanged() {
    if (isUpdatingFromAdvanced_) return;

    syncBasicToAdvanced();
    recomputeDirtyState();
}

void MainWindow::resetInputStyleToDefault() {
    // 既定値を設定する (すべて先頭の選択肢)
    ui_->mainInputStyle->setCurrentIndex(0);     // ローマ字
    ui_->punctuationStyle->setCurrentIndex(0);   // 句点 + 読点
    ui_->numberStyle->setCurrentIndex(0);        // 全角
    ui_->commonSymbolStyle->setCurrentIndex(0);  // 全角
    ui_->spaceStyleLabel->setCurrentIndex(0);    // 全角

    // 全コントロールを再度有効化する (ローマ字モードに戻すため)
    ui_->punctuationStyle->setEnabled(true);
    ui_->numberStyle->setEnabled(true);
    ui_->commonSymbolStyle->setEnabled(true);

    // ツールチップを消去する
    ui_->punctuationStyle->setToolTip("");
    ui_->numberStyle->setToolTip("");
    ui_->commonSymbolStyle->setToolTip("");

    // 変更を適用する
    syncBasicToAdvanced();
    hideBasicModeWarning();
    // 明示的に再計算する
    // コンボの選択位置が既に既定値でも、Basic→Advanced同期でテーブル / キーマップの順序付き状態が変わる可能性があるため、dirty状態を更新する
    recomputeDirtyState();
}

void MainWindow::syncBasicToAdvanced() {
    if (!currentProfile_) return;

    // 既存のキーマップとテーブルを消去する
    clearKeymapsAndTables();

    // Basicタブの選択に基づいて設定を適用する
    applyBasicPunctuationStyle();
    applyBasicNumberStyle();
    applyBasicSymbolStyle();
    applyBasicSpaceStyle();
    // 句読点形式は基本形式より先に設定すること
    // 句読点キーマップが和字記号マップを上書きするため
    applyBasicInputStyle();

    // 変更をUIに反映する
    if (currentProfile_) {
        // 無限ループ防止のため一時的にフラグを立てる
        isUpdatingFromAdvanced_ = true;
        ui_->submodeEntryPointChars->setText(QString::fromStdString(currentProfile_->submode_entry_point_chars()));
        isUpdatingFromAdvanced_ = false;
    }

    // Advancedタブの表示を更新する
    loadInputTables();
    loadKeymaps();
}

void MainWindow::syncAdvancedToBasic() {
    if (!currentProfile_) return;

    isUpdatingFromAdvanced_ = true;

    if (isBasicModeCompatible()) {
        hideBasicModeWarning();
        setBasicTabEnabled(true);

        // Advanced設定からBasic設定の推定を試みる
        // 簡易な逆方向マッピングである

        // サブモード入口と入力テーブルから入力形式を確認する
        QString submodeEntry = QString::fromStdString(currentProfile_->submode_entry_point_chars());
        bool hasRomajiTable = false;
        bool hasKanaTable = false;

        for (int i = 0; i < currentProfile_->enabled_tables_size(); ++i) {
            const auto& table = currentProfile_->enabled_tables(i);
            QString tableName = QString::fromStdString(table.name());

            if (tableName.contains("Romaji", Qt::CaseInsensitive)) {
                hasRomajiTable = true;
            }

            if (tableName.contains("Kana", Qt::CaseInsensitive)) {
                hasKanaTable = true;
            }
        }

        bool isKanaMode = false;
        // submodeEntryはisBasicModeCompatible()で確認済み
        if (hasRomajiTable) {
            ui_->mainInputStyle->setCurrentIndex(0);  // ローマ字
        }
        else if (hasKanaTable) {
            ui_->mainInputStyle->setCurrentIndex(1);  // JISかな
            isKanaMode = true;
        }

        // 入力形式に応じて他の選択肢の有効 / 無効を切り替える
        ui_->punctuationStyle->setEnabled(!isKanaMode);
        ui_->numberStyle->setEnabled(!isKanaMode);
        ui_->commonSymbolStyle->setEnabled(!isKanaMode);

        // ツールチップを更新する
        if (isKanaMode) {
            ui_->punctuationStyle->setToolTip(tr("Disabled in Kana mode"));
            ui_->numberStyle->setToolTip(tr("Disabled in Kana mode"));
            ui_->commonSymbolStyle->setToolTip(tr("Disabled in Kana mode"));
        }
        else {
            ui_->punctuationStyle->setToolTip("");
            ui_->numberStyle->setToolTip("");
            ui_->commonSymbolStyle->setToolTip("");
        }

        // 他の形式のキーマップ設定を確認する
        QSet<QString> enabledKeymaps;
        for (int i = 0; i < currentProfile_->enabled_keymaps_size(); ++i) {
            const auto& keymap = currentProfile_->enabled_keymaps(i);
            enabledKeymaps.insert(QString::fromStdString(keymap.name()));
        }

        // 句読点形式
        if (enabledKeymaps.contains("Fullwidth Period") && enabledKeymaps.contains("Fullwidth Comma")) {
            ui_->punctuationStyle->setCurrentIndex(1);  // Period+Comma
        }
        else if (enabledKeymaps.contains("Fullwidth Comma") && !enabledKeymaps.contains("Fullwidth Period")) {
            ui_->punctuationStyle->setCurrentIndex(2);  // Kuten+Comma
        }
        else if (enabledKeymaps.contains("Fullwidth Period") && !enabledKeymaps.contains("Fullwidth Comma")) {
            ui_->punctuationStyle->setCurrentIndex(3);  // Period+Toten
        }
        else {
            ui_->punctuationStyle->setCurrentIndex(0);  // 句点 + 読点
        }

        // 数字形式
        if (enabledKeymaps.contains("Fullwidth Number")) {
            ui_->numberStyle->setCurrentIndex(0);  // 全角
        }
        else {
            ui_->numberStyle->setCurrentIndex(1);  // 半角
        }

        // 記号形式
        if (enabledKeymaps.contains("Fullwidth Symbol")) {
            ui_->commonSymbolStyle->setCurrentIndex(0);  // 全角
        }
        else {
            ui_->commonSymbolStyle->setCurrentIndex(1);  // 半角
        }

        // 空白形式
        if (enabledKeymaps.contains("Fullwidth Space")) {
            ui_->spaceStyleLabel->setCurrentIndex(0);  // 全角
        }
        else {
            ui_->spaceStyleLabel->setCurrentIndex(1);  // 半角
        }
    }
    else {
        showBasicModeWarning();
        setBasicTabEnabled(false);
        // Basicモードと互換性がない場合は自動でAdvancedタブへ切り替える
        ui_->inputTableConfigModeTabWidget->setCurrentIndex(1);
    }

    isUpdatingFromAdvanced_ = false;
}

bool MainWindow::isBasicModeCompatible() {
    if (!currentProfile_) return false;

    // 現在の設定を取得する
    QString submodeEntry = QString::fromStdString(currentProfile_->submode_entry_point_chars());

    // 有効なキーマップとテーブルを収集する
    QList<QString> enabledCustomKeymaps;
    QList<QString> enabledCustomTables;

    QList<QString> enabledBuiltinKeymaps;
    QList<QString> enabledBuiltinTables;

    for (int i = 0; i < currentProfile_->enabled_keymaps_size(); ++i) {
        const auto& keymap = currentProfile_->enabled_keymaps(i);
        QString name = QString::fromStdString(keymap.name());
        if (keymap.is_built_in()) {
            enabledBuiltinKeymaps.append(name);
        }
        else {
            enabledCustomKeymaps.append(name);
        }
    }

    for (int i = 0; i < currentProfile_->enabled_tables_size(); ++i) {
        const auto& table = currentProfile_->enabled_tables(i);
        QString name = QString::fromStdString(table.name());
        if (table.is_built_in()) {
            enabledBuiltinTables.append(name);
        }
        else {
            enabledCustomKeymaps.append(name);
        }
    }

    // カスタムキーマップの確認
    if (enabledCustomTables.size() != 0 || enabledCustomKeymaps.size() != 0) {
        return false;
    }

    // 有効な入力形式設定か確認する
    // 組込テーブルが必須である
    bool hasBuiltinRomajiTable = enabledBuiltinTables.contains("Romaji");
    bool hasBuiltinKanaTable = enabledBuiltinTables.contains("Kana");
    bool hasBuiltinKanaKeymap = enabledBuiltinKeymaps.contains("JIS Kana");
    bool isRomajiSubmode = (submodeEntry == "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    bool isKanaSubmode = submodeEntry.isEmpty();

    // 有効な組み合わせ:
    // 1. ローマ字テーブルのみ + ローマ字サブモード
    // 2. かなテーブルのみ + かなサブモード(空)
    bool isValidRomajiInputStyle = (hasBuiltinRomajiTable && !hasBuiltinKanaTable && isRomajiSubmode && !hasBuiltinKanaKeymap);
    bool isValidKanaInputStyle = (hasBuiltinKanaTable && !hasBuiltinRomajiTable && isKanaSubmode && hasBuiltinKanaKeymap);

    // かなモードでは空白関連とJISかなのキーマップのみ許可する
    if (isValidKanaInputStyle) {
        QSet<QString> allowedKanaModeKeymaps = {"Fullwidth Space", "JIS Kana"};

        for (const QString& keymap : enabledBuiltinKeymaps) {
            if (!allowedKanaModeKeymaps.contains(keymap)) {
                return false;  // かなモードに無効なキーマップ
            }
        }

        return true;  // 有効な"かな"モード
    }
    else if (isValidRomajiInputStyle) {
        QSet<QString> validBasicKeymaps = {
            "Fullwidth Period", "Fullwidth Comma", "Fullwidth Number",
            "Fullwidth Symbol", "Fullwidth Space", "Japanese Symbol"};

        // 和字記号マップは有効化し、句読点の後に配置すること
        bool checkedJapaneSymbolMap = false;

        // 有効なキーマップがすべてBasicモードに適合するか確認する
        for (const QString& keymap : enabledBuiltinKeymaps) {
            if (!validBasicKeymaps.contains(keymap)) {
                return false;
            }

            if (checkedJapaneSymbolMap &&
                (keymap == "Fullwidth Period" || keymap == "Fullwidth Comma")) {
                return false;  // 句読点と和字記号マップの順序が不正
            }

            if (keymap == "Japanese Symbol") {
                checkedJapaneSymbolMap = true;
            }
        }

        if (!checkedJapaneSymbolMap) {
            return false;  // 必須マップが不足
        }

        return true;  // 有効なローマ字モード
    }
    else {
        return false;
    }
}

void MainWindow::showBasicModeWarning() {
    // まず既存の警告を隠し、重複を防ぐ
    hideBasicModeWarning();

    QVBoxLayout* basicTabLayout = qobject_cast<QVBoxLayout*>(ui_->inputStyleSimpleModeScrollAreaContents->layout());

    if (basicTabLayout) {
        QWidget* warningWidget = createWarningWidget(tr("<b>Warning:</b> Current settings can only "
                                                        "be edited in Advanced "
                                                        "mode."),
                                                     "yellow", tr("Reset Input Style"),
                                                     [this]() { resetInputStyleToDefault(); });

        basicTabLayout->insertWidget(0, warningWidget);

        // 警告表示中はBasicタブの全要素を無効化する
        setBasicTabEnabled(false);
    }
}

void MainWindow::hideBasicModeWarning() {
    QVBoxLayout* basicTabLayout = qobject_cast<QVBoxLayout*>(ui_->inputStyleSimpleModeScrollAreaContents->layout());

    if (basicTabLayout) {
        for (int i = basicTabLayout->count() - 1; i >= 0; --i) {
            QLayoutItem* item = basicTabLayout->itemAt(i);
            if (item && item->widget()) {
                QWidget* widget = item->widget();
                // 警告ウィジェットか確認する(黄色背景を持つもの)
                if (widget->styleSheet().contains("background-color: yellow")) {
                    basicTabLayout->removeWidget(widget);
                    widget->deleteLater();
                    // 警告を隠したらBasicタブ要素を再度有効化する
                    setBasicTabEnabled(true);

                    // かなモードなら制限を再適用する
                    if (ui_->mainInputStyle->currentIndex() == 1) {
                        ui_->punctuationStyle->setEnabled(false);
                        ui_->numberStyle->setEnabled(false);
                        ui_->commonSymbolStyle->setEnabled(false);
                        ui_->punctuationStyle->setToolTip("Disabled in Kana mode");
                        ui_->numberStyle->setToolTip("Disabled in Kana mode");
                        ui_->commonSymbolStyle->setToolTip("Disabled in Kana mode");
                    }
                    return;
                }
            }
        }
    }
}

void MainWindow::setBasicTabEnabled(bool enabled) {
    ui_->inputStylesGrid->setEnabled(enabled);
    ui_->mainInputStyle->setEnabled(enabled);
    ui_->punctuationStyle->setEnabled(enabled);
    ui_->numberStyle->setEnabled(enabled);
    ui_->commonSymbolStyle->setEnabled(enabled);
    ui_->spaceStyleLabel->setEnabled(enabled);
}

void MainWindow::applyBasicInputStyle() {
    int inputStyleIndex = ui_->mainInputStyle->currentIndex();

    if (inputStyleIndex == 0) {  // ローマ字
        currentProfile_->set_submode_entry_point_chars("ABCDEFGHIJKLMNOPQRSTUVWXYZ");
        addInputTableIfAvailable("Romaji", true);
        addKeymapIfAvailable("Japanese Symbol", true);
    }
    else if (inputStyleIndex == 1) {  // JISかな
        currentProfile_->set_submode_entry_point_chars("");
        addInputTableIfAvailable("Kana", true);
        addKeymapIfAvailable("JIS Kana", true);
    }
}

void MainWindow::applyBasicPunctuationStyle() {
    // 句読点形式が無効なら飛ばす (かなモード)
    if (!ui_->punctuationStyle->isEnabled()) {
        return;
    }

    int punctuationIndex = ui_->punctuationStyle->currentIndex();

    switch (punctuationIndex) {
        case 0:  // 和字の句点と読点
            // 追加のキーマップは不要
            break;
        case 1:  // Period+Comma: ．，
            addKeymapIfAvailable("Fullwidth Period", true);
            addKeymapIfAvailable("Fullwidth Comma", true);
            break;
        case 2:  // 和字の句点とASCIIコンマ
            addKeymapIfAvailable("Fullwidth Comma", true);
            break;
        case 3:  // Period+Toten: ．、
            addKeymapIfAvailable("Fullwidth Period", true);
            break;
    }
}

void MainWindow::applyBasicNumberStyle() {
    // 数字形式が無効なら飛ばす (かなモード)
    if (!ui_->numberStyle->isEnabled()) {
        return;
    }

    int numberIndex = ui_->numberStyle->currentIndex();

    if (numberIndex == 0) {  // 全角: １２３４５
        addKeymapIfAvailable("Fullwidth Number", true);
    }

    // 半角が既定値のためキーマップは不要
}

void MainWindow::applyBasicSymbolStyle() {
    // 記号形式が無効なら飛ばす(かなモード)
    if (!ui_->commonSymbolStyle->isEnabled()) {
        return;
    }

    int symbolIndex = ui_->commonSymbolStyle->currentIndex();

    switch (symbolIndex) {
        case 0:  // 全角: ！＃＠（
            addKeymapIfAvailable("Fullwidth Symbol", true);
            break;
        case 1:  // 半角: !#@(
            // 追加のキーマップは不要
            break;
    }
}

void MainWindow::applyBasicSpaceStyle() {
    int spaceIndex = ui_->spaceStyleLabel->currentIndex();

    if (spaceIndex == 0) {  // 全角: "　"
        addKeymapIfAvailable("Fullwidth Space", true);
    }

    // 半角が既定値のためキーマップは不要
}

void MainWindow::addKeymapIfAvailable(const QString& keymapName,
                                      bool isBuiltIn) {
    // 名前と組込状態の完全一致でキーマップが利用可能か確認する
    for (int i = 0; i < currentConfig_.available_keymaps_size(); ++i) {
        const auto& availableKeymap = currentConfig_.available_keymaps(i);
        if (QString::fromStdString(availableKeymap.name()) == keymapName &&
            availableKeymap.is_built_in() == isBuiltIn) {
            // 有効なキーマップに追加する
            auto* enabledKeymap = currentProfile_->add_enabled_keymaps();
            enabledKeymap->set_name(availableKeymap.name());
            enabledKeymap->set_is_built_in(availableKeymap.is_built_in());
            enabledKeymap->set_filename(availableKeymap.filename());
            break;
        }
    }
}

void MainWindow::addInputTableIfAvailable(const QString& tableName,
                                          bool isBuiltIn) {
    // 名前と組込状態の完全一致で入力テーブルが利用可能か確認する
    for (int i = 0; i < currentConfig_.available_tables_size(); ++i) {
        const auto& availableTable = currentConfig_.available_tables(i);
        if (QString::fromStdString(availableTable.name()) == tableName &&
            availableTable.is_built_in() == isBuiltIn) {
            // 有効なテーブルに追加する
            auto* enabledTable = currentProfile_->add_enabled_tables();
            enabledTable->set_name(availableTable.name());
            enabledTable->set_is_built_in(availableTable.is_built_in());
            enabledTable->set_filename(availableTable.filename());
            break;
        }
    }
}

void MainWindow::clearKeymapsAndTables() {
    if (currentProfile_) {
        currentProfile_->clear_enabled_keymaps();
        currentProfile_->clear_enabled_tables();
    }
}

void MainWindow::onCheckAllConversion() {
    ui_->halfwidthKatakanaConversion->setChecked(true);
    ui_->extendedEmojiConversion->setChecked(true);
    ui_->commaSeparatedNumCoversion->setChecked(true);
    ui_->calendarConversion->setChecked(true);
    ui_->timeConversion->setChecked(true);
    ui_->mailDomainConversion->setChecked(true);
    ui_->unicodeCodePointConversion->setChecked(true);
    ui_->romanTypographyConversion->setChecked(true);
    ui_->hazkeyVersionConversion->setChecked(true);
    ui_->relativeDateConversion->setChecked(true);
}

void MainWindow::onUncheckAllConversion() {
    ui_->halfwidthKatakanaConversion->setChecked(false);
    ui_->extendedEmojiConversion->setChecked(false);
    ui_->commaSeparatedNumCoversion->setChecked(false);
    ui_->calendarConversion->setChecked(false);
    ui_->timeConversion->setChecked(false);
    ui_->mailDomainConversion->setChecked(false);
    ui_->unicodeCodePointConversion->setChecked(false);
    ui_->romanTypographyConversion->setChecked(false);
    ui_->hazkeyVersionConversion->setChecked(false);
    ui_->relativeDateConversion->setChecked(false);
}

void MainWindow::onClearLearningData() {
    if (!currentProfile_) {
        QMessageBox::warning(this, tr("Error"), tr("No configuration profile loaded."));
        return;
    }

    // 確認ダイアログを表示する
    QMessageBox::StandardButton reply = QMessageBox::question(this, tr("Clear Input History"),
                                                              tr("Are you sure you want to clear all input history data? This action "
                                                                 "cannot be undone."),
                                                              QMessageBox::Yes | QMessageBox::No, QMessageBox::No);

    if (reply == QMessageBox::Yes) {
        // サーバコネクターで履歴を消去する
        bool success = server_.clearAllHistory(currentProfile_->profile_id());

        if (success) {
            QMessageBox::information(this, tr("Success"), tr("Input history has been cleared successfully."));
        }
        else {
            QMessageBox::critical(this, tr("Error"), tr("Failed to clear input history. Please check your "
                                                        "connection to the hazkey server."));
        }
    }
}

void MainWindow::onSelectiveLearningHistory() {
    if (!currentProfile_) {
        QMessageBox::warning(this, tr("Error"), tr("No configuration profile loaded."));
        return;
    }

    if (!learningHistoryDialog_) {
        learningHistoryDialog_ = new LearningHistoryDialog(&server_,
                                                           {currentProfile_->profile_id(), currentProfile_->use_profile_independent_history()},
                                                           this);
        learningHistoryDialog_->setAttribute(Qt::WA_DeleteOnClose);
    }

    learningHistoryDialog_->show();
    learningHistoryDialog_->raise();
    learningHistoryDialog_->activateWindow();
}

QString MainWindow::translateKeymapName(const QString& keymapName,
                                        bool isBuiltin) {
    if (!isBuiltin) {
        return keymapName;
    }

    if (keymapName == "JIS Kana") {
        return tr("JIS Kana");
    }
    else if (keymapName == "Japanese Symbol") {
        return tr("Japanese Symbol");
    }
    else if (keymapName == "Fullwidth Period") {
        return tr("Fullwidth Period");
    }
    else if (keymapName == "Fullwidth Comma") {
        return tr("Fullwidth Comma");
    }
    else if (keymapName == "Fullwidth Number") {
        return tr("Fullwidth Number");
    }
    else if (keymapName == "Fullwidth Symbol") {
        return tr("Fullwidth Symbol");
    }
    else if (keymapName == "Fullwidth Space") {
        return tr("Fullwidth Space");
    }

    return keymapName;
}

QString MainWindow::translateTableName(const QString& tableName,
                                       bool isBuiltin) {
    if (!isBuiltin) {
        return tableName;
    }

    if (tableName == "Romaji") {
        return tr("Romaji");
    }
    else if (tableName == "Kana") {
        return tr("Kana");
    }

    return tableName;
}

QWidget* MainWindow::zenzaiDialogParent() const {
    return zenzaiModelDialog_ ? static_cast<QWidget*>(zenzaiModelDialog_.data())
                              : static_cast<QWidget*>(const_cast<MainWindow*>(this));
}

void MainWindow::refreshZenzaiDialogButtonStates() {
    if (!zenzaiModelDialog_) return;

    // ダウンロード中、または応答の確立直前の短い区間は、ダイアログ内の全コントロールをロックする
    const bool locked = currentDownload_ != nullptr || zenzaiDownloadPending_;
    const QString activeKey = ZenzaiModelManager::getActiveModelKey();

    // ダイアログは固定の完全性スナップショットを持つ
    // ディスクI/Oはダイアログ構築時か、確定したディスク変更の直後にのみ行う
    const auto rows = zenzaiModelDialog_->findChildren<ZenzaiFamilyRow*>();
    for (ZenzaiFamilyRow* row : rows) {
        row->refreshState(locked, activeKey);
    }

    // OKボタンとキャンセルボタン
    QDialogButtonBox* bb = zenzaiModelDialog_->findChild<QDialogButtonBox*>();
    if (bb) {
        if (bb->button(QDialogButtonBox::Ok)) {
            QButtonGroup* group = zenzaiModelDialog_->findChild<QButtonGroup*>();
            const auto selection = currentZenzaiDialogSelection(group);
            const bool selectedArtifactDownloaded =
                isZenzaiSelectionActivatable(availableZenzaiModelFamilies(),
                                             zenzaiDownloadedSnapshot_, selection);
            bb->button(QDialogButtonBox::Ok)->setEnabled(selectedArtifactDownloaded && !locked);
        }

        if (bb->button(QDialogButtonBox::Cancel)) {
            // キャンセル: ダウンロード実行中は無効
            bb->button(QDialogButtonBox::Cancel)->setEnabled(!locked);
        }
    }
}

void MainWindow::refreshZenzaiDownloadedSnapshot() {
    zenzaiDownloadedSnapshot_ = ZenzaiModelManager::downloadedModelKeys(availableZenzaiModels());
}

MainWindow::~MainWindow() {
    if (currentDownload_) {
        currentDownload_->abort();
        currentDownload_->deleteLater();
    }
    closeDownloadStream();
    const QString leftoverTemp = currentDownloadTempPath();
    if (!leftoverTemp.isEmpty()) {
        QFile::remove(leftoverTemp);
    }

    if (downloadProgressDialog_) {
        delete downloadProgressDialog_;
    }

    delete ui_;
}

void MainWindow::onDownloadZenzaiModel() {
    if (openingZenzaiModelDialog_) {
        return;
    }

    QScopedValueRollback<bool> openingGuard(openingZenzaiModelDialog_, true);

    const QVector<ZenzaiModelOption>& models = availableZenzaiModels();
    if (models.isEmpty()) {
        QMessageBox::critical(this, tr("Download Error"), tr("No neural conversion models are configured."));
        return;
    }

    {
        QProgressDialog waitDialog(tr("Checking downloaded neural conversion models..."), QString(), 0, 0, this);
        waitDialog.setWindowModality(Qt::WindowModal);
        waitDialog.setMinimumDuration(0);
        waitDialog.setCancelButton(nullptr);
        waitDialog.setAutoReset(false);
        waitDialog.setAutoClose(false);

        OverrideCursorGuard cursorGuard;
        waitDialog.show();

        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents | QEventLoop::ExcludeSocketNotifiers);

        ZenzaiModelManager::migrateLegacyModel();
        refreshZenzaiDownloadedSnapshot();
        waitDialog.close();
    }

    while (true) {
        QDialog dialog(this);
        zenzaiModelDialog_ = &dialog;
        dialog.setWindowTitle(tr("Manage neural conversion models"));
        QVBoxLayout* dialogLayout = new QVBoxLayout(&dialog);

        QLabel* introLabel = new QLabel(tr("Select a downloaded model to use, or download a new one:"), &dialog);
        introLabel->setWordWrap(true);
        dialogLayout->addWidget(introLabel);

        QButtonGroup* group = new QButtonGroup(&dialog);
        group->setExclusive(true);

        const QVector<ZenzaiModelFamily>& families = availableZenzaiModelFamilies();
        QVector<ZenzaiFamilyRow*> rows;
        QString activeKey = ZenzaiModelManager::getActiveModelKey();
        int defaultFamilyIndex = -1;

        // 系列ごとに1行
        // 複数バリアント系列 (jinen-v2) では量子化が選択でき、単一バリアント系列 (zenz) は従来通りの見た目になる
        for (int i = 0; i < families.size(); ++i) {
            const ZenzaiModelFamily& family = families[i];
            if (family.variants.isEmpty()) {
                continue;
            }

            ZenzaiFamilyRow* row = new ZenzaiFamilyRow(family, zenzaiDownloadedSnapshot_, &dialog);
            row->setObjectName("row_" + family.familyKey);
            rows.append(row);
            group->addButton(row->radioButton(), i);

            // 有効なダウンロード済みバリアントがこの系列に属していればそれを、
            // 無ければこの系列の先頭のダウンロード済みバリアントを事前選択する。
            int preselect = -1;
            for (int v = 0; v < family.variants.size(); ++v) {
                if (!zenzaiDownloadedSnapshot_.contains(family.variants[v].key)) {
                    continue;
                }

                if (preselect == -1 || family.variants[v].key == activeKey) {
                    preselect = v;
                }
            }

            if (preselect >= 0) {
                row->setVariantIndex(preselect);
                if (defaultFamilyIndex == -1 || row->artifact().key == activeKey) {
                    defaultFamilyIndex = i;
                }
            }

            connect(row, &ZenzaiFamilyRow::downloadRequested, this, [this](const QString& key) { beginZenzaiModelDownload(key); });
            connect(row, &ZenzaiFamilyRow::deleteRequested, this, [this, &dialog](const QString& key) {
                requestZenzaiModelDeletion(key, &dialog);
            });
            connect(row, &ZenzaiFamilyRow::boundVariantChanged, this,
                    [this](const QString&) { refreshZenzaiDialogButtonStates(); });

            row->refreshState(currentDownload_ != nullptr || zenzaiDownloadPending_, activeKey);
            dialogLayout->addWidget(row);
        }

        // 全行の追加後に既定のラジオ選択を適用する
        if (defaultFamilyIndex >= 0) {
            QAbstractButton* defaultRb = group->button(defaultFamilyIndex);
            if (defaultRb) {
                defaultRb->setChecked(true);
            }
        }

        QDialogButtonBox* buttons = new QDialogButtonBox(
            QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dialog);
        buttons->button(QDialogButtonBox::Ok)->setEnabled(false);
        buttons->button(QDialogButtonBox::Ok)->setText(tr("OK"));

        // OKボタン: 選択行に束縛中のアーティファクトを有効化する
        connect(buttons->button(QDialogButtonBox::Ok), &QPushButton::clicked,
                this, [this, group, rows, &dialog]() {
                    int selectedIdx = group->checkedId();
                    if (selectedIdx < 0 || selectedIdx >= rows.size()) {
                        dialog.reject();
                        return;
                    }
                    const ZenzaiModelOption& chosen = rows[selectedIdx]->artifact();
                    if (ZenzaiModelManager::activateModel(chosen.key)) {
                        bool reloadSucceeded = false;
                        {
                            QProgressDialog waitDialog(tr("Loading neural conversion model..."), QString(), 0, 0, &dialog);
                            waitDialog.setWindowModality(Qt::WindowModal);
                            waitDialog.setMinimumDuration(0);
                            waitDialog.setCancelButton(nullptr);
                            waitDialog.setAutoReset(false);
                            waitDialog.setAutoClose(false);
                            OverrideCursorGuard cursorGuard;
                            waitDialog.show();
                            QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents | QEventLoop::ExcludeSocketNotifiers);
                            reloadSucceeded = server_.reloadZenzaiModel();
                            waitDialog.close();
                        }

                        if (!reloadSucceeded) {
                            QMessageBox::warning(&dialog, tr("Neural Conversion Model Warning"),
                                                 tr("The selected model is active, but neural conversion could not finish loading it."));
                        }

                        dialog.accept();
                    }
                    else {
                        QMessageBox::critical(&dialog, tr("Error"), tr("Failed to activate model."));
                    }
                });

        connect(buttons->button(QDialogButtonBox::Cancel), &QPushButton::clicked,
                this, [this, &dialog]() {
                    // ダウンロード実行中は閉じるのを抑止する。
                    if (currentDownload_) return;
                    dialog.reject();
                });

        dialogLayout->addWidget(buttons);
        refreshZenzaiDialogButtonStates();

        // ダイアログ寸法を明示する
        dialog.resize(700, 500);

        dialog.exec();
        zenzaiModelDialog_ = nullptr;
        rows.clear();

        // [OK] / [キャンセル]ボタンのいずれでもループを抜ける
        // モデルを有効化した可能性があるため (削除はその場で反映済み)、Zenzaiランタイムのメタデータのみを更新する
        // プロファイル由来ウィジェットと未保存の編集内容には触れず、更新に失敗しても警告表示はそのまま残す
        auto runtimeConfig = server_.getConfig();
        if (runtimeConfig.has_value()) {
            currentConfig_.set_zenzai_model_available(
                runtimeConfig->zenzai_model_available());
            currentConfig_.set_zenzai_model_path(
                runtimeConfig->zenzai_model_path());
            currentConfig_.mutable_available_zenzai_backend_devices()->CopyFrom(
                runtimeConfig->available_zenzai_backend_devices());
            updateZenzaiAvailabilityUi();
        }
        zenzaiDownloadedSnapshot_.clear();
        return;
    }
}

void MainWindow::beginZenzaiModelDownload(const QString& key) {
    const ZenzaiModelOption* selectedModel = findZenzaiModelByKey(key);
    if (!selectedModel) {
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"),
                              tr("Selected neural conversion model is no longer available."));
        refreshZenzaiDialogButtonStates();
        return;
    }

    // 旧形式カスタムモデルの確認と応答の確立が走る間は全コントロールをロックする
    // currentDownload_は未設定のため、zenzaiDownloadPending_がロックを担う
    zenzaiDownloadPending_ = true;
    refreshZenzaiDialogButtonStates();

    // ダウンロード前に旧形式カスタムモデルを確認する
    QString legacyPath = ZenzaiModelManager::getSymlinkPath();
    QFileInfo legacyInfo(legacyPath);
    if (legacyInfo.exists() && !legacyInfo.isSymLink()) {
        QMessageBox::StandardButton reply = QMessageBox::question(
            zenzaiDialogParent(), tr("Preserve Custom Model"),
            tr("A custom neural conversion model \"zenzai.gguf\" already exists.\n"
               "Do you want to preserve it before downloading a new one?"),
            QMessageBox::Yes | QMessageBox::No | QMessageBox::Cancel);

        if (reply == QMessageBox::Cancel || reply == QMessageBox::No) {
            // ボタン状態を戻す (ダウンロードは開始していない)
            zenzaiDownloadPending_ = false;
            refreshZenzaiDialogButtonStates();
            return;
        }

        if (reply == QMessageBox::Yes) {
            QString sha = ZenzaiModelManager::calculateSHA256(legacyPath);
            QString shaPrefix = sha.left(8);
            QString newName = QString("legacy-custom-%1.gguf").arg(shaPrefix);
            QString newPath = ZenzaiModelManager::getModelsDir() + "/" + newName;
            QDir().mkpath(ZenzaiModelManager::getModelsDir());

            if (!QFile::rename(legacyPath, newPath)) {
                QMessageBox::critical(zenzaiDialogParent(), tr("Error"), tr("Failed to preserve custom model."));
                // ボタン状態を戻す (ダウンロードは開始していない)
                zenzaiDownloadPending_ = false;
                refreshZenzaiDialogButtonStates();
                return;
            }
        }
    }

    // 選択を保持する
    currentDownloadUrl_ = selectedModel->url;
    currentDownloadExpectedSha256_ = selectedModel->sha256;
    currentDownloadExpectedBytes_ = selectedModel->expectedBytes;
    currentDownloadKey_ = selectedModel->key;

    // ストリーミング状態を初期化する (一時ファイルと増分ハッシュは初回readyReadで遅延生成する)
    downloadReceivedBytes_ = 0;
    downloadFileError_.clear();

    // --- Major 3: 正しい初期化順序 ---
    // 1. 応答を先に作り、イベント処理呼び出し(例: setValue)が再入する前に
    //    currentDownload_を設定する。
    //    停滞した転送は30秒で中断し (TimeoutError)、302応答は安全な範囲で追随し、
    //    削除直後の再取得で古いkeep-alive接続に張り付かないよう取得前に破棄する。
    QUrl dlUrl(currentDownloadUrl_);
    QNetworkRequest request(dlUrl);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(30000);
    networkManager_->clearAccessCache();
    currentDownload_ = networkManager_->get(request);

    connect(currentDownload_, &QNetworkReply::readyRead, this, &MainWindow::onDownloadReadyRead);
    connect(currentDownload_, &QNetworkReply::downloadProgress, this, &MainWindow::onDownloadProgress);
    connect(currentDownload_, &QNetworkReply::finished, this, &MainWindow::onDownloadFinished);
    connect(currentDownload_, QOverload<QNetworkReply::NetworkError>::of(&QNetworkReply::errorOccurred), this, &MainWindow::onDownloadError);

    // 応答がダイアログのロックを引き継いだため、pending番兵を解除する
    zenzaiDownloadPending_ = false;

    // 2. 次に進捗ダイアログを構築する (親はMainWindow)
    downloadProgressDialog_ = new QProgressDialog(tr("Downloading neural conversion model..."), tr("Cancel"), 0, 100, this);
    downloadProgressDialog_->setWindowModality(Qt::WindowModal);
    downloadProgressDialog_->setMinimumDuration(0);
    // 検証完了前に進捗100で自動クローズ / リセットしないよう抑止する
    downloadProgressDialog_->setAutoClose(false);
    downloadProgressDialog_->setAutoReset(false);
    downloadProgressDialog_->resize(450, 200);

    connect(downloadProgressDialog_, &QProgressDialog::canceled, this, [this]() {
        if (currentDownload_) {
            currentDownload_->abort();
        }});

    // 3. 表示 / setValueは最後に行う (イベントを回す可能性がある)
    downloadProgressDialog_->show();
    downloadProgressDialog_->setValue(0);
}

void MainWindow::requestZenzaiModelDeletion(const QString& key, QDialog* dialog) {
    const ZenzaiModelOption* model = findZenzaiModelByKey(key);
    if (!model) {
        QMessageBox::critical(zenzaiDialogParent(), tr("Error"), tr("Selected neural conversion model is no longer available."));
        return;
    }

    const QString displayName = model->displayName;
    QMessageBox::StandardButton reply = QMessageBox::question(
        dialog ? static_cast<QWidget*>(dialog) : zenzaiDialogParent(), tr("Delete Model"),
        tr("Are you sure you want to delete the model \"%1\"?").arg(displayName),
        QMessageBox::Yes | QMessageBox::No);
    if (reply != QMessageBox::Yes) {
        return;
    }

    QButtonGroup* group = dialog ? dialog->findChild<QButtonGroup*>() : nullptr;
    const std::optional<ZenzaiDialogSelection> previousSelection =
        currentZenzaiDialogSelection(group);
    const QString activeKey = ZenzaiModelManager::getActiveModelKey();
    const bool wasActive = activeKey == key;
    if (ZenzaiModelManager::deleteModel(key)) {
        if (wasActive) {
            server_.reloadZenzaiModel();
        }

        if (dialog) {
            refreshZenzaiDownloadedSnapshot();

            const std::optional<ZenzaiDialogSelection> reconciled =
                reconcileZenzaiDialogSelection(availableZenzaiModelFamilies(),
                                               zenzaiDownloadedSnapshot_, key,
                                               previousSelection, activeKey);
            const bool selectionChanged =
                previousSelection.has_value() != reconciled.has_value() ||
                (previousSelection.has_value() && reconciled.has_value() &&
                 (previousSelection->familyIndex != reconciled->familyIndex ||
                  previousSelection->variantIndex != reconciled->variantIndex));

            if (selectionChanged) {
                if (!reconciled.has_value()) {
                    clearZenzaiDialogSelection(group);
                }
                else {
                    QAbstractButton* replacementButton = group
                        ? group->button(reconciled->familyIndex)
                        : nullptr;
                    ZenzaiFamilyRow* replacementRow = replacementButton
                        ? qobject_cast<ZenzaiFamilyRow*>(replacementButton->parentWidget())
                        : nullptr;
                    if (replacementRow) {
                        // onDownloadFinishedと同じ順序で、束縛を更新してからチェックする
                        replacementRow->setVariantIndex(reconciled->variantIndex);
                        refreshZenzaiDialogButtonStates();
                        replacementButton->setChecked(true);
                    }
                    else {
                        clearZenzaiDialogSelection(group);
                    }
                }
            }

            refreshZenzaiDialogButtonStates();
        }
    }
    else {
        QMessageBox::critical(dialog ? static_cast<QWidget*>(dialog) : zenzaiDialogParent(), tr("Error"), tr("Failed to delete model."));
    }
}

void MainWindow::onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal) {
    // ガード: 古い応答からのシグナルを無視する
    if (qobject_cast<QNetworkReply*>(sender()) != currentDownload_) return;
    if (!downloadProgressDialog_) return;

    if (bytesTotal <= 0) {
        // 総量不明の間は不確定表示にし、受信量だけを示す (0%貼り付きを避ける)
        downloadProgressDialog_->setRange(0, 0);
        const double receivedMB = bytesReceived / 1024.0 / 1024.0;
        downloadProgressDialog_->setLabelText(
            tr("Downloading neural conversion model... %1 MB received").arg(receivedMB, 0, 'f', 2));
        return;
    }

    // 総量が判明したら確定表示に戻す (不確定表示からの復帰を含む)
    if (downloadProgressDialog_->minimum() == 0 && downloadProgressDialog_->maximum() == 0) {
        downloadProgressDialog_->setRange(0, 100);
    }
    int progress = static_cast<int>((bytesReceived * 100) / bytesTotal);
    downloadProgressDialog_->setValue(progress);

    // ダウンロード量をMB表示する
    double receivedMB = bytesReceived / 1024.0 / 1024.0;
    double totalMB = bytesTotal / 1024.0 / 1024.0;
    downloadProgressDialog_->setLabelText(tr("Downloading neural conversion model... %1 MB / %2 MB").arg(receivedMB, 0, 'f', 2).arg(totalMB, 0, 'f', 2));
}

void MainWindow::onDownloadReadyRead() {
    // ガード: 古い応答からのシグナルを無視する
    QNetworkReply* reply = qobject_cast<QNetworkReply*>(sender());
    if (reply != currentDownload_ || !currentDownload_) return;

    // 遅延生成: 初回断片で一時ファイルと増分ハッシュを用意する
    if (!downloadTempFile_ && !ensureDownloadStream()) {
        currentDownload_->abort();
        return;
    }

    const QByteArray chunk = currentDownload_->readAll();
    if (chunk.isEmpty()) return;
    downloadHash_->addData(chunk);
    if (downloadTempFile_->write(chunk) != chunk.size()) {
        downloadFileError_ = downloadTempFile_->errorString();
        currentDownload_->abort();
        return;
    }
    downloadReceivedBytes_ += chunk.size();
}

QString MainWindow::currentDownloadTempPath() const {
    if (currentDownloadKey_.isEmpty()) return QString();
    return ZenzaiModelManager::getModelPath(currentDownloadKey_) + ".tmp";
}

bool MainWindow::ensureDownloadStream() {
    if (downloadTempFile_) return true;
    const QString temporaryPath = currentDownloadTempPath();
    if (temporaryPath.isEmpty()) return false;
    QDir().mkpath(QFileInfo(temporaryPath).absolutePath());
    downloadTempFile_ = new QFile(temporaryPath);
    if (!downloadTempFile_->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        downloadFileError_ = downloadTempFile_->errorString();
        delete downloadTempFile_;
        downloadTempFile_ = nullptr;
        return false;
    }
    downloadHash_ = new QCryptographicHash(QCryptographicHash::Sha256);
    return true;
}

void MainWindow::closeDownloadStream() {
    if (downloadTempFile_) {
        downloadTempFile_->close();
        delete downloadTempFile_;
        downloadTempFile_ = nullptr;
    }
    if (downloadHash_) {
        delete downloadHash_;
        downloadHash_ = nullptr;
    }
}

void MainWindow::discardPartialDownload() {
    closeDownloadStream();
    const QString temporaryPath = currentDownloadTempPath();
    if (!temporaryPath.isEmpty()) {
        QFile::remove(temporaryPath);
    }
    downloadReceivedBytes_ = 0;
    downloadFileError_.clear();
}

void MainWindow::onDownloadFinished() {
    // ガード: 古い応答からのシグナルを無視する
    if (qobject_cast<QNetworkReply*>(sender()) != currentDownload_) {
        currentDownloadExpectedBytes_ = 0;
        return;
    }

    if (!currentDownload_) return;

    // ヘルパー: ダウンロード単位の状態を消去し、ダイアログのボタン状態を戻す
    auto clearAndRefresh = [this]() {
        currentDownloadUrl_.clear();
        currentDownloadExpectedSha256_.clear();
        currentDownloadExpectedBytes_ = 0;
        currentDownloadKey_.clear();
        zenzaiDownloadPending_ = false;
        refreshZenzaiDialogButtonStates();
    };

    // 進捗ダイアログを閉じる
    if (downloadProgressDialog_) {
        downloadProgressDialog_->deleteLater();
        downloadProgressDialog_ = nullptr;
    }

    // ネットワークエラーを確認する (onDownloadErrorで報告済み)
    if (currentDownload_->error() != QNetworkReply::NoError) {
        discardPartialDownload();
        currentDownload_->deleteLater();
        currentDownload_ = nullptr;
        // onDownloadError側でclearAndRefresh相当の処理を呼んだため、ここでは戻るだけ
        return;
    }

    // 応答に残る未読分を回収する (readyRead未発火の末尾断片があり得る)
    if (!ensureDownloadStream()) {
        const QString saveError = downloadFileError_;
        discardPartialDownload();
        currentDownload_->deleteLater();
        currentDownload_ = nullptr;
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"), tr("Failed to save model file: %1").arg(saveError));
        clearAndRefresh();
        return;
    }
    const QByteArray tail = currentDownload_->readAll();
    if (!tail.isEmpty()) {
        downloadHash_->addData(tail);
        if (downloadTempFile_->write(tail) != tail.size() && downloadFileError_.isEmpty()) {
            downloadFileError_ = downloadTempFile_->errorString();
        }
        downloadReceivedBytes_ += tail.size();
    }
    currentDownload_->deleteLater();
    currentDownload_ = nullptr;

    // 書出し失敗は検証前に保存エラーとして扱う
    if (!downloadFileError_.isEmpty()) {
        const QString saveError = downloadFileError_;
        discardPartialDownload();
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"), tr("Failed to save model file: %1").arg(saveError));
        clearAndRefresh();
        return;
    }

    const QString calculatedHashHex =
        QString::fromLatin1(downloadHash_->result().toHex());
    const qint64 receivedBytes = downloadReceivedBytes_;
    closeDownloadStream();

    const ZenzaiModelOption* downloadedModel =
        findZenzaiModelByKey(currentDownloadKey_);
    if (!downloadedModel) {
        discardPartialDownload();
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"),
                              tr("Selected neural conversion model is no longer available."));
        clearAndRefresh();
        return;
    }

    const QString modelPath = ZenzaiModelManager::getModelPath(downloadedModel->key);
    const ModelDownloadValidation validation = validateStreamedModelDownload(
        receivedBytes, currentDownloadExpectedBytes_,
        calculatedHashHex, currentDownloadExpectedSha256_);
    if (validation == ModelDownloadValidation::SizeMismatch) {
        finalizeStreamedModelDownload(modelPath, validation);
        QMessageBox::critical(
            zenzaiDialogParent(), tr("Download Error"),
            tr("Downloaded file verification failed. Size mismatch.\n"
               "Expected: %1 bytes\n"
               "Got: %2 bytes")
                .arg(currentDownloadExpectedBytes_)
                .arg(receivedBytes));
        clearAndRefresh();
        return;
    }

    if (validation == ModelDownloadValidation::ChecksumMismatch) {
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"),
                              tr("Downloaded file verification failed. Checksum mismatch.\n"
                                 "Expected: %1\n"
                                 "Got: %2").arg(currentDownloadExpectedSha256_).arg(calculatedHashHex));
        finalizeStreamedModelDownload(modelPath, validation);
        clearAndRefresh();
        return;
    }

    QString saveError;
    if (!finalizeStreamedModelDownload(modelPath, validation, &saveError)) {
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"), tr("Failed to save model file: %1").arg(saveError));
        clearAndRefresh();
        return;
    }

    // --- 成功経路 ---
    // 状態消去の前にダウンロードしたキーを保存する
    const QString downloadedKey = downloadedModel->key;
    refreshZenzaiDownloadedSnapshot();
    clearAndRefresh();
    // currentDownload_は既にnull (上記応答破棄後に設定済み)

    // 開いているダイアログがまだあればその場で更新する
    if (zenzaiModelDialog_) {
        // 各行を今回ダウンロードした量子化に束縛し直して選択する
        // [OK]ボタン押下でダウンロード直後のものが確実に有効化されるようにする
        const auto rows = zenzaiModelDialog_->findChildren<ZenzaiFamilyRow*>();
        for (ZenzaiFamilyRow* row : rows) {
            bool rebound = false;
            for (int v = 0; v < row->family().variants.size(); ++v) {
                if (row->family().variants[v].key != downloadedKey) {
                    continue;
                }

                row->setVariantIndex(v);
                rebound = true;
                break;
            }

            if (!rebound) {
                continue;
            }
            // 先に更新してラジオを有効化・再ラベル化してからチェックする
            // refreshStateはチェック状態自体を変えない
            refreshZenzaiDialogButtonStates();
            row->radioButton()->setChecked(true);
        }

        // 全ボタンの状態(Download/Delete/OK/Cancel)をディスク状態から更新する
        // currentDownload_はnullptrのため、更新処理は適切なボタンを有効化する
        refreshZenzaiDialogButtonStates();

        // Minor 2: ダイアログが存続中は状況に応じた完了メッセージを表示する
        QMessageBox::information(zenzaiDialogParent(), tr("Download Complete"), tr("The downloaded model is now selected. Click OK to activate it."));
    }
    else {
        // Minor 2: ダイアログは既に閉じられている
        QMessageBox::information(
            this, tr("Download Complete"),
            tr("Neural conversion model has been downloaded successfully.\n"
               "Open \"Manage neural conversion models\" to activate it."));
    }
}

void MainWindow::onDownloadError(QNetworkReply::NetworkError error) {
    // ガード: 古い応答からのシグナルを無視する
    if (qobject_cast<QNetworkReply*>(sender()) != currentDownload_) return;

    // 先に進捗ダイアログを閉じる
    if (downloadProgressDialog_) {
        downloadProgressDialog_->deleteLater();
        downloadProgressDialog_ = nullptr;
    }

    if (!currentDownload_) return;

    QString errorString = currentDownload_->errorString();
    currentDownload_->deleteLater();
    currentDownload_ = nullptr;

    // 書出し失敗で中断した場合は取消扱いにせず保存エラーとして報告する
    const QString fileError = downloadFileError_;
    const QString retryKey = currentDownloadKey_;
    discardPartialDownload();

    // ダウンロード単位の選択状態を消去する
    currentDownloadUrl_.clear();
    currentDownloadExpectedSha256_.clear();
    currentDownloadExpectedBytes_ = 0;
    currentDownloadKey_.clear();
    zenzaiDownloadPending_ = false;

    // ダイアログのボタン状態を戻す (currentDownload_は既にnullptr)
    refreshZenzaiDialogButtonStates();

    if (!fileError.isEmpty()) {
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"),
                              tr("Failed to save model file: %1").arg(fileError));
        return;
    }

    // 停滞中断は再試行を選択できる (保存済みキーで取得をやり直す)
    if (error == QNetworkReply::TimeoutError) {
        QMessageBox::StandardButton reply = QMessageBox::question(
            zenzaiDialogParent(), tr("Download Error"),
            tr("The download stalled and timed out.\n"
               "Do you want to retry the download?\n"
               "Details: %1").arg(errorString),
            QMessageBox::Retry | QMessageBox::Cancel);
        if (reply == QMessageBox::Retry && !retryKey.isEmpty()) {
            beginZenzaiModelDownload(retryKey);
        }
        return;
    }

    // ユーザがキャンセルした場合はエラーを表示しない
    if (error != QNetworkReply::OperationCanceledError) {
        QMessageBox::critical(zenzaiDialogParent(), tr("Download Error"),
                              tr("Failed to download neural conversion model: %1").arg(errorString));
    }
}

void MainWindow::onResetConfiguration() {
    QMessageBox::StandardButton reply = QMessageBox::question(this, tr("Reset Configuration"),
                                                              tr("Resetting will discard any unsaved changes. Continue?"),
                                                              QMessageBox::Yes | QMessageBox::No);

    if (reply == QMessageBox::No) {
        return;
    }

    // 接続競合を避けるため永続セッションを使用する
    if (!server_.beginSession()) {
        QMessageBox::critical(this, tr("Connection Error"),
                              tr("Failed to connect to server."));
        return;
    }

    // 既定設定はApplyかOKで保存するまでプレビュー扱いである
    auto configOpt = server_.getDefaultProfileInSession();
    server_.endSession();

    if (!configOpt.has_value()) {
        QMessageBox::critical(this, tr("Configuration Error"), tr("Failed to load default configuration from server."));
        return;
    }

    if (configOpt->profiles_size() != 1) {
        QMessageBox::critical(this, tr("Configuration Error"), tr("The default configuration must contain exactly one profile."));
        return;
    }

    // 現在設定のランタイムメタ情報を引き継ぐ
    // 既定プロファイル応答はプレビュー用のプロファイルのみをあえて含む
    *currentConfig_.mutable_profiles() = configOpt->profiles();
    currentProfile_ = currentConfig_.mutable_profiles(0);
    if (!currentProfile_) {
        QMessageBox::critical(this, tr("Configuration Error"),
                              tr("Failed to access profile."));
        return;
    }

    // 全UI部品を再読込する (設定は取得済みのため取得を省く)
    if (!loadCurrentConfig(false)) {
        QMessageBox::critical(this, tr("Configuration Error"),
                              tr("Failed to update UI."));
        return;
    }

    QTimer::singleShot(0, this, [this]() {
        QMessageBox::information(this, tr("Reset Complete"), tr("Configuration has been reset to defaults. Apply or OK to save."));
    });
}

QWidget* MainWindow::createWarningWidget(const QString& message,
                                         const QString& backgroundColor,
                                         const QString& buttonText,
                                         std::function<void()> buttonCallback) {
    QWidget* warningWidget = new QWidget();
    warningWidget->setStyleSheet(QString("background-color: %1; padding: 5px;").arg(backgroundColor));
    QHBoxLayout* warningLayout = new QHBoxLayout(warningWidget);

    QLabel* warningLabel = new QLabel(message);
    warningLabel->setWordWrap(true);
    warningLabel->setStyleSheet("color: black;");
    warningLayout->addWidget(warningLabel);

    if (!buttonText.isEmpty() && buttonCallback) {
        QPushButton* button = new QPushButton(buttonText);
        connect(button, &QPushButton::clicked, this, buttonCallback);
        warningLayout->addWidget(button);
    }

    return warningWidget;
}

QString MainWindow::userDictFilePath() {
    QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
    QString base;
    if (!xdg.isEmpty()) {
        base = xdg + "/hazkey";
    }
    else {
        base = QDir::homePath() + "/.config/hazkey";
    }

    QDir().mkpath(base);

    return base + "/user_dictionary.tsv";
}

void MainWindow::setupUserDict() {
    ui_->userDictTable->setColumnCount(4);
    ui_->userDictTable->setHorizontalHeaderLabels({tr("Reading"), tr("Word"), tr("Comment"), tr("品詞")});
    ui_->userDictTable->horizontalHeader()->setStretchLastSection(true);
    ui_->userDictTable->horizontalHeader()->setSectionResizeMode(0, QHeaderView::ResizeToContents);
    ui_->userDictTable->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
    ui_->userDictTable->horizontalHeader()->setSectionResizeMode(3, QHeaderView::ResizeToContents);
    ui_->userDictTable->setSelectionBehavior(QAbstractItemView::SelectRows);
    ui_->userDictTable->setSelectionMode(QAbstractItemView::SingleSelection);
    ui_->userDictTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
    ui_->userDictTable->verticalHeader()->setVisible(false);

    loadUserDictFromDisk();
    refreshUserDictTable();
}

void MainWindow::loadUserDictFromDisk() {
    userDictEntries_.clear();
    QFile file(userDictFilePath());

    if (!file.exists()) return;
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;

    QTextStream in(&file);
    in.setEncoding(QStringConverter::Utf8);
    while (!in.atEnd()) {
        const QString line = in.readLine();

        if (line.isEmpty() || line.startsWith('#')) continue;

        const QStringList cols = line.split('\t');

        if (cols.size() < 2) continue;

        UserDictEntry e;
        e.reading = cols[0].trimmed();
        e.word = cols[1];
        e.comment = cols.size() >= 3 ? cols[2] : QString();
        e.pos = cols.size() >= 4 ? normalizePosToken(cols[3]) : QStringLiteral("noun");

        if (e.reading.isEmpty() || e.word.isEmpty()) continue;

        userDictEntries_.append(e);
    }
}

bool MainWindow::saveUserDictToDisk() {
    const QString path = userDictFilePath();
    if (!writeUserDictionaryFile(path, userDictEntries_)) {
        QMessageBox::warning(this, tr("User Dictionary"), tr("Failed to save user dictionary to %1").arg(path));
        return false;
    }

    return true;
}

void MainWindow::refreshUserDictTable() {
    ui_->userDictTable->setRowCount(userDictEntries_.size());
    for (int i = 0; i < userDictEntries_.size(); ++i) {
        ui_->userDictTable->setItem(i, 0, new QTableWidgetItem(userDictEntries_[i].reading));
        ui_->userDictTable->setItem(i, 1, new QTableWidgetItem(userDictEntries_[i].word));
        ui_->userDictTable->setItem(i, 2, new QTableWidgetItem(userDictEntries_[i].comment));
        ui_->userDictTable->setItem(i, 3, new QTableWidgetItem(posToDisplay(userDictEntries_[i].pos)));
    }
    onUserDictSelectionChanged();
}

void MainWindow::onUserDictSelectionChanged() {
    const bool enabled = ui_->useUserDict->isChecked();
    const bool hasSel = !ui_->userDictTable->selectedItems().isEmpty();
    ui_->userDictDeleteEntry->setEnabled(enabled && hasSel);
}

bool MainWindow::editUserDictEntryDialog(UserDictEntry& entry, const QString& title) {
    QDialog dialog(this);
    dialog.setWindowTitle(title);
    dialog.setMinimumSize(520, 200);
    auto* form = new QFormLayout();
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    auto* readingEdit = new QLineEdit(entry.reading, &dialog);
    auto* wordEdit = new QLineEdit(entry.word, &dialog);
    auto* commentEdit = new QLineEdit(entry.comment, &dialog);
    auto* posCombo = new QComboBox(&dialog);
    posCombo->addItem(posToDisplay(QStringLiteral("noun")), QStringLiteral("noun"));
    posCombo->addItem(posToDisplay(QStringLiteral("person")), QStringLiteral("person"));
    posCombo->addItem(posToDisplay(QStringLiteral("place")), QStringLiteral("place"));
    posCombo->addItem(posToDisplay(QStringLiteral("verb")), QStringLiteral("verb"));
    int posIndex = posCombo->findData(entry.pos.isEmpty() ? QStringLiteral("noun") : entry.pos);
    posCombo->setCurrentIndex(posIndex >= 0 ? posIndex : 0);
    posCombo->setItemData(3, tr("動詞: 読みの末尾から活用形を自動生成します"), Qt::ToolTipRole);
    form->addRow(tr("Reading (hiragana)"), readingEdit);
    form->addRow(tr("Word"), wordEdit);
    form->addRow(tr("Comment"), commentEdit);
    form->addRow(tr("Part of Speech"), posCombo);

    // 活用情報ラベルは、品詞が[動詞]選択時のみ表示する (意図的に汎用文言にしている)
    // これは、かな末尾判定ロジック (hazkey-server/Sources/hazkey-server/VerbConjugator.swiftにある) の重複を避けるため
    auto* conjugationInfoLabel = new QLabel(&dialog);
    conjugationInfoLabel->setWordWrap(true);
    conjugationInfoLabel->setStyleSheet(QStringLiteral("color: gray; font-size: small;"));
    conjugationInfoLabel->setVisible(false);
    form->addRow(QString(), conjugationInfoLabel);
    auto updateConjugationInfo = [conjugationInfoLabel](const QString& pos) {
        if (pos == QStringLiteral("verb")) {
            conjugationInfoLabel->setText(
                QCoreApplication::translate("MainWindow",
                    "活用形を自動生成します（読みの末尾から判定）"));
            conjugationInfoLabel->setVisible(true);
        } else {
            conjugationInfoLabel->setVisible(false);
        }
    };
    updateConjugationInfo(posCombo->currentData().toString());
    connect(posCombo, &QComboBox::currentIndexChanged, posCombo,
        [posCombo, updateConjugationInfo]() {
            updateConjugationInfo(posCombo->currentData().toString());
        });

    auto* buttons = new QDialogButtonBox(
        QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dialog);
    connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

    auto* layout = new QVBoxLayout(&dialog);
    layout->addLayout(form);
    layout->addStretch();
    layout->addWidget(buttons);

    if (dialog.exec() != QDialog::Accepted) return false;
    const QString reading = readingEdit->text().trimmed();
    const QString word = wordEdit->text();
    if (reading.isEmpty() || word.isEmpty()) {
        QMessageBox::warning(this, tr("User Dictionary"),
                             tr("Reading and Word must not be empty."));
        return false;
    }
    if (reading.contains('\t') || word.contains('\t') ||
        commentEdit->text().contains('\t') || reading.contains('\n') ||
        word.contains('\n')) {
        QMessageBox::warning(this, tr("User Dictionary"),
                             tr("Tab and newline characters are not allowed."));
        return false;
    }
    entry.reading = reading;
    entry.word = word;
    entry.comment = commentEdit->text();
    entry.pos = posCombo->currentData().toString();
    return true;
}

void MainWindow::onUserDictAdd() {
    UserDictEntry e;
    if (!editUserDictEntryDialog(e, tr("Add Word"))) return;
    userDictEntries_.append(e);
    if (!saveUserDictToDisk()) {
        userDictEntries_.removeLast();
        return;
    }
    refreshUserDictTable();
}

void MainWindow::onUserDictEdit() {
    const int row = ui_->userDictTable->currentRow();
    if (row < 0 || row >= userDictEntries_.size()) return;
    UserDictEntry e = userDictEntries_[row];
    if (!editUserDictEntryDialog(e, tr("Edit Word"))) return;
    const UserDictEntry old = userDictEntries_[row];
    userDictEntries_[row] = e;
    if (!saveUserDictToDisk()) {
        userDictEntries_[row] = old;
        return;
    }
    refreshUserDictTable();
    ui_->userDictTable->selectRow(row);
}

void MainWindow::onUserDictDelete() {
    const int row = ui_->userDictTable->currentRow();
    if (row < 0 || row >= userDictEntries_.size()) return;
    if (QMessageBox::question(this, tr("User Dictionary"),
                              tr("Delete \"%1\" → \"%2\"?").arg(userDictEntries_[row].reading, userDictEntries_[row].word)) != QMessageBox::Yes) {
        return;
    }

    const UserDictEntry removed = userDictEntries_[row];

    userDictEntries_.removeAt(row);
    if (!saveUserDictToDisk()) {
        userDictEntries_.insert(row, removed);
        return;
    }
    refreshUserDictTable();
}

void MainWindow::onUserDictImport() {
    const QString path = QFileDialog::getOpenFileName(this, tr("Import User Dictionary"), QString(),
                                                      tr("Tab-separated files (*.tsv *.txt);;All files (*)"));

    if (path.isEmpty()) return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QMessageBox::warning(this, tr("User Dictionary"), tr("Failed to open user dictionary file: %1").arg(path));
        return;
    }

    QVector<UserDictEntry> importedEntries;
    int skippedRows = 0;
    QTextStream in(&file);
    in.setEncoding(QStringConverter::Utf8);
    while (!in.atEnd()) {
        const QString line = in.readLine();

        if (line.isEmpty() || line.startsWith('#')) continue;

        const QStringList cols = line.split('\t');
        if (cols.size() < 2) {
            ++skippedRows;
            continue;
        }

        UserDictEntry entry;
        entry.reading = cols[0].trimmed();
        entry.word = cols[1];
        entry.comment = cols.size() >= 3 ? cols[2] : QString();
        entry.pos = cols.size() >= 4 ? normalizePosToken(cols[3]) : QStringLiteral("noun");
        if (entry.reading.isEmpty() || entry.word.isEmpty()) {
            ++skippedRows;
            continue;
        }
        importedEntries.append(entry);
    }

    if (importedEntries.isEmpty()) {
        QMessageBox::information(this, tr("User Dictionary"), tr("No valid user dictionary entries were found."));
        return;
    }

    const QVector<UserDictEntry> backup = userDictEntries_;
    int updatedEntries = 0;
    int addedEntries = 0;
    for (const auto& imported : importedEntries) {
        bool updated = false;
        for (auto& existing : userDictEntries_) {
            if (existing.reading == imported.reading &&
                existing.word == imported.word) {
                existing = imported;
                updated = true;
                break;
            }
        }

        if (updated) {
            ++updatedEntries;
        }
        else {
            userDictEntries_.append(imported);
            ++addedEntries;
        }
    }

    if (!saveUserDictToDisk()) {
        userDictEntries_ = backup;
        return;
    }

    refreshUserDictTable();
    QMessageBox::information(this, tr("User Dictionary"),
                             tr("Imported %1 new and updated %2 entries; skipped %3 malformed rows.")
                                 .arg(addedEntries)
                                 .arg(updatedEntries)
                                 .arg(skippedRows));
}

void MainWindow::onUserDictExport() {
    const QString path = QFileDialog::getSaveFileName(this, tr("Export User Dictionary"), QString(),
                                                      tr("Tab-separated files (*.tsv *.txt);;All files (*)"));

    if (path.isEmpty()) return;

    if (!writeUserDictionaryFile(path, userDictEntries_)) {
        QMessageBox::warning(this, tr("User Dictionary"), tr("Failed to export user dictionary to %1").arg(path));
        return;
    }

    QMessageBox::information(this, tr("User Dictionary"), tr("Exported user dictionary to %1").arg(path));
}

#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QAbstractButton>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QProgressDialog>
#include <QString>
#include <QVector>
#include <QWidget>

#include "serverconnector.h"
#include "zenzai_models.h"

struct UserDictEntry {
    QString reading;
    QString word;
    QString comment;
    QString pos;
};

QT_BEGIN_NAMESPACE
namespace Ui {
class MainWindow;
}
QT_END_NAMESPACE

class MainWindow : public QWidget {
    Q_OBJECT

   public:
    MainWindow(QWidget* parent = nullptr);
    ~MainWindow();

   private slots:
    void onButtonClicked(QAbstractButton* button);
    void onApply();
    void onUseHistoryToggled(bool enabled);
    void onUseZenzaiCustomWeightToggled(bool enabled);
    void onBrowseZenzaiWeightPath();
    void onEnableTable();
    void onDisableTable();
    void onTableMoveUp();
    void onTableMoveDown();
    void onEnabledTableSelectionChanged();
    void onAvailableTableSelectionChanged();
    void onEnableKeymap();
    void onDisableKeymap();
    void onKeymapMoveUp();
    void onKeymapMoveDown();
    void onEnabledKeymapSelectionChanged();
    void onAvailableKeymapSelectionChanged();
    void onSubmodeEntryChanged();
    void onBasicInputStyleChanged();
    void onBasicSettingChanged();
    void resetInputStyleToDefault();
    void onCheckAllConversion();
    void onUncheckAllConversion();
    void onClearLearningData();
    void onUserDictAdd();
    void onUserDictEdit();
    void onUserDictDelete();
    void onUserDictImport();
    void onUserDictExport();
    void onUserDictSelectionChanged();
    void onUseUserDictToggled(bool enabled);
    void onDownloadZenzaiModel();
    void onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal);
    void onDownloadFinished();
    void onDownloadError(QNetworkReply::NetworkError error);
    void onResetConfiguration();

   private:
    void connectSignals();
    bool loadCurrentConfig(bool fetchConfig = true);
    bool saveCurrentConfig();
    void setupInputTableLists();
    void loadInputTables();
    void saveInputTables();
    void updateTableButtonStates();
    void setupKeymapLists();
    void loadKeymaps();
    void saveKeymaps();
    void updateKeymapButtonStates();
    void syncBasicToAdvanced();
    void syncAdvancedToBasic();
    bool isBasicModeCompatible();
    void showBasicModeWarning();
    void hideBasicModeWarning();
    void setBasicTabEnabled(bool enabled);
    void applyBasicInputStyle();
    void applyBasicPunctuationStyle();
    void applyBasicNumberStyle();
    void applyBasicSymbolStyle();
    void applyBasicSpaceStyle();
    void addKeymapIfAvailable(const QString& keymapName, bool isBuiltIn);
    void addInputTableIfAvailable(const QString& tableName, bool isBuiltIn);
    void clearKeymapsAndTables();
    QString translateKeymapName(const QString& keymapName, bool isBuiltin);
    QString translateTableName(const QString& tableName, bool isBuiltin);
    QWidget* createWarningWidget(
        const QString& message, const QString& backgroundColor,
        const QString& buttonText = QString(),
        std::function<void()> buttonCallback = nullptr);
    static QString userDictFilePath();
    void loadUserDictFromDisk();
    bool saveUserDictToDisk();
    void refreshUserDictTable();
    bool editUserDictEntryDialog(UserDictEntry& entry, const QString& title);
    void setupUserDict();
    // Recompute and restore all Zenzai dialog button states from disk.
    // No-op when zenzaiModelDialog_ is null.
    void refreshZenzaiDialogButtonStates();
    // Returns zenzaiModelDialog_ as QWidget* if alive, otherwise this.
    QWidget* zenzaiDialogParent() const;
    Ui::MainWindow* ui_;
    ServerConnector server_;
    hazkey::config::CurrentConfig currentConfig_;
    hazkey::config::Profile* currentProfile_;
    bool isUpdatingFromAdvanced_;
    QNetworkAccessManager* networkManager_;
    QNetworkReply* currentDownload_;
    QProgressDialog* downloadProgressDialog_;
    QString zenzaiModelPath_;
    // Pointer to the currently open Zenzai model management dialog (if any).
    QPointer<QDialog> zenzaiModelDialog_;
    // Selected by user in the model selection dialog before each download.
    QString currentDownloadUrl_;
    QString currentDownloadExpectedSha256_;
    QString currentDownloadKey_;
    QVector<UserDictEntry> userDictEntries_;
};
#endif  // MAINWINDOW_H

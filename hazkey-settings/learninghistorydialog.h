#ifndef LEARNINGHISTORYDIALOG_H
#define LEARNINGHISTORYDIALOG_H

#include <QDialog>

#include <cstdint>
#include <string>
#include <vector>

#include "serverconnector.h"

class QDialogButtonBox;
class QLabel;
class QLineEdit;
class QPushButton;
class QTableWidget;

struct LearningHistoryDialogTarget {
    std::string profileId;
    bool useProfileIndependentHistory = false;
};

class LearningHistoryDialog : public QDialog {
    Q_OBJECT

   public:
    LearningHistoryDialog(ServerConnector* server,
                          LearningHistoryDialogTarget target,
                          QWidget* parent = nullptr);

   private slots:
    void onSearch();
    void onPreviousPage();
    void onNextPage();
    void onDeleteSelected();

   private:
    static constexpr uint32_t kPageLimit = 200;

    void reloadPage();
    void populateTable(
        const hazkey::config::GetLearningHistoryResult& result);
    std::vector<hazkey::config::LearningEntryKey> checkedEntries() const;
    void updatePagination();

    ServerConnector* server_;
    LearningHistoryDialogTarget target_;
    QLabel* modeLabel_ = nullptr;
    QLineEdit* searchEdit_ = nullptr;
    QPushButton* searchButton_ = nullptr;
    QTableWidget* historyTable_ = nullptr;
    QPushButton* previousPageButton_ = nullptr;
    QPushButton* nextPageButton_ = nullptr;
    QLabel* paginationLabel_ = nullptr;
    QPushButton* deleteButton_ = nullptr;
    QDialogButtonBox* buttonBox_ = nullptr;
    std::vector<hazkey::config::LearningHistoryEntry> entries_;
    uint32_t offset_ = 0;
    uint32_t totalCount_ = 0;
};

#endif  // LEARNINGHISTORYDIALOG_H

#include "learninghistorydialog.h"

#include <QDate>
#include <QDialogButtonBox>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMessageBox>
#include <QPushButton>
#include <QTableWidget>
#include <QVBoxLayout>

#include <algorithm>

namespace {

QString localizedLastUsedDate(uint32_t unixDay) {
    const QDate date = QDate(1970, 1, 1).addDays(unixDay);
    return QLocale().toString(date, QLocale::ShortFormat);
}

}  // namespace

LearningHistoryDialog::LearningHistoryDialog(
    ServerConnector* server, LearningHistoryDialogTarget target, QWidget* parent)
    : QDialog(parent), server_(server), target_(std::move(target)) {
    setModal(true);
    setWindowTitle(tr("入力履歴を選択して削除"));
    resize(920, 790);

    auto* layout = new QVBoxLayout(this);
    modeLabel_ = new QLabel(
        target_.useProfileIndependentHistory ? tr("分離モード")
                                              : tr("共有モード"),
        this);
    modeLabel_->setObjectName("learningHistoryModeLabel");
    layout->addWidget(modeLabel_);

    auto* searchLayout = new QHBoxLayout();
    searchEdit_ = new QLineEdit(this);
    searchEdit_->setObjectName("learningHistorySearchEdit");
    searchEdit_->setPlaceholderText(tr("よみまたは表記を入力"));
    searchButton_ = new QPushButton(tr("検索"), this);
    searchButton_->setObjectName("learningHistorySearchButton");
    searchLayout->addWidget(searchEdit_);
    searchLayout->addWidget(searchButton_);
    layout->addLayout(searchLayout);

    historyTable_ = new QTableWidget(this);
    historyTable_->setObjectName("learningHistoryTable");
    historyTable_->setColumnCount(5);
    historyTable_->setHorizontalHeaderLabels(
        {tr("選択"), tr("よみ"), tr("表記"), tr("回数"), tr("最終使用日")});
    historyTable_->setEditTriggers(QAbstractItemView::NoEditTriggers);
    historyTable_->setSelectionMode(QAbstractItemView::NoSelection);
    historyTable_->verticalHeader()->setVisible(false);
    historyTable_->horizontalHeader()->setSectionResizeMode(
        0, QHeaderView::ResizeToContents);
    historyTable_->horizontalHeader()->setSectionResizeMode(
        1, QHeaderView::ResizeToContents);
    historyTable_->horizontalHeader()->setSectionResizeMode(
        2, QHeaderView::Stretch);
    historyTable_->horizontalHeader()->setSectionResizeMode(
        3, QHeaderView::ResizeToContents);
    historyTable_->horizontalHeader()->setSectionResizeMode(
        4, QHeaderView::ResizeToContents);
    layout->addWidget(historyTable_);

    auto* paginationLayout = new QHBoxLayout();
    previousPageButton_ = new QPushButton(tr("前"), this);
    previousPageButton_->setObjectName("learningHistoryPreviousPage");
    nextPageButton_ = new QPushButton(tr("次"), this);
    nextPageButton_->setObjectName("learningHistoryNextPage");
    paginationLabel_ = new QLabel(this);
    paginationLabel_->setObjectName("learningHistoryPaginationLabel");
    paginationLayout->addWidget(previousPageButton_);
    paginationLayout->addWidget(nextPageButton_);
    paginationLayout->addWidget(paginationLabel_);
    paginationLayout->addStretch();
    layout->addLayout(paginationLayout);

    deleteButton_ = new QPushButton(tr("削除"), this);
    deleteButton_->setObjectName("learningHistoryDeleteButton");
    layout->addWidget(deleteButton_);

    buttonBox_ = new QDialogButtonBox(QDialogButtonBox::Close, this);
    connect(buttonBox_, &QDialogButtonBox::rejected, this, &QDialog::reject);
    layout->addWidget(buttonBox_);

    connect(searchButton_, &QPushButton::clicked, this,
            &LearningHistoryDialog::onSearch);
    connect(searchEdit_, &QLineEdit::returnPressed, this,
            &LearningHistoryDialog::onSearch);
    connect(previousPageButton_, &QPushButton::clicked, this,
            &LearningHistoryDialog::onPreviousPage);
    connect(nextPageButton_, &QPushButton::clicked, this,
            &LearningHistoryDialog::onNextPage);
    connect(deleteButton_, &QPushButton::clicked, this,
            &LearningHistoryDialog::onDeleteSelected);

    reloadPage();
}

void LearningHistoryDialog::onSearch() {
    offset_ = 0;
    reloadPage();
}

void LearningHistoryDialog::onPreviousPage() {
    offset_ = offset_ > kPageLimit ? offset_ - kPageLimit : 0;
    reloadPage();
}

void LearningHistoryDialog::onNextPage() {
    if (offset_ + kPageLimit >= totalCount_) return;
    offset_ += kPageLimit;
    reloadPage();
}

void LearningHistoryDialog::onDeleteSelected() {
    const auto keys = checkedEntries();
    if (keys.empty()) {
        QMessageBox::warning(this, tr("削除"), tr("削除する履歴を選択してください。"));
        return;
    }

    if (QMessageBox::question(
            this, tr("入力履歴を削除"),
            tr("選択した入力履歴を削除しますか？この操作は元に戻せません。"),
            QMessageBox::Yes | QMessageBox::No, QMessageBox::No)
        != QMessageBox::Yes) {
        return;
    }

    const auto deletedCount =
        server_->deleteLearningEntries(target_.profileId, keys);
    if (!deletedCount) {
        QMessageBox::warning(this, tr("エラー"),
                             tr("入力履歴の削除に失敗しました。hazkeyサーバーへの接続を確認してください。"));
        return;
    }

    reloadPage();
    QMessageBox::information(this, tr("完了"),
                             tr("%1 件の入力履歴を削除しました。")
                                 .arg(*deletedCount));
}

void LearningHistoryDialog::reloadPage() {
    const auto result = server_->getLearningHistory(
        target_.profileId, searchEdit_->text().toStdString(), offset_, kPageLimit);
    if (!result) {
        QMessageBox::warning(this, tr("エラー"),
                             tr("入力履歴を取得できませんでした。hazkeyサーバーへの接続を確認してください。"));
        return;
    }

    if (result->total_count() > 0 && offset_ >= result->total_count()) {
        offset_ = ((result->total_count() - 1) / kPageLimit) * kPageLimit;
        reloadPage();
        return;
    }

    populateTable(*result);
}

void LearningHistoryDialog::populateTable(
    const hazkey::config::GetLearningHistoryResult& result) {
    entries_.assign(result.entries().begin(), result.entries().end());
    totalCount_ = result.total_count();
    historyTable_->setRowCount(static_cast<int>(entries_.size()));
    for (int row = 0; row < static_cast<int>(entries_.size()); ++row) {
        const auto& entry = entries_[row];
        auto* checkbox = new QTableWidgetItem();
        checkbox->setCheckState(Qt::Unchecked);
        historyTable_->setItem(row, 0, checkbox);
        historyTable_->setItem(
            row, 1,
            new QTableWidgetItem(QString::fromStdString(entry.reading())));
        historyTable_->setItem(
            row, 2, new QTableWidgetItem(QString::fromStdString(entry.word())));
        historyTable_->setItem(row, 3,
                               new QTableWidgetItem(QString::number(entry.count())));
        historyTable_->setItem(
            row, 4, new QTableWidgetItem(
                        localizedLastUsedDate(entry.last_used_unix_day())));
    }
    updatePagination();
}

std::vector<hazkey::config::LearningEntryKey>
LearningHistoryDialog::checkedEntries() const {
    std::vector<hazkey::config::LearningEntryKey> keys;
    for (int row = 0; row < historyTable_->rowCount(); ++row) {
        if (historyTable_->item(row, 0)->checkState() != Qt::Checked) continue;
        const auto& entry = entries_[row];
        hazkey::config::LearningEntryKey key;
        key.set_reading(entry.reading());
        key.set_word(entry.word());
        key.set_lcid(entry.lcid());
        key.set_rcid(entry.rcid());
        keys.push_back(std::move(key));
    }
    return keys;
}

void LearningHistoryDialog::updatePagination() {
    const uint32_t first = entries_.empty() ? 0 : offset_ + 1;
    const uint32_t last = offset_ + static_cast<uint32_t>(entries_.size());
    paginationLabel_->setText(
        tr("表示中: %1–%2 / 合計 %3").arg(first).arg(last).arg(totalCount_));
    previousPageButton_->setEnabled(offset_ > 0);
    nextPageButton_->setEnabled(offset_ + kPageLimit < totalCount_);
    deleteButton_->setEnabled(!entries_.empty());
}

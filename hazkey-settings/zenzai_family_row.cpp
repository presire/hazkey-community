/**
 * @file zenzai_family_row.cpp
 * @brief モデル管理ダイアログの系列行ウィジェットの実装
 *
 * 系列1件分のラジオボタン、量子化コンボ、ダウンロード/削除ボタン、説明ラベルを構築し、
 * 束縛中バリアントの決定とディスク状態の反映を担う
 */

#include "zenzai_family_row.h"

#include <QCoreApplication>
#include <QDir>
#include <QHBoxLayout>
#include <QStringList>
#include <QVBoxLayout>

namespace {

/**
 * @brief rich text のアンカー要素を組み立てる
 * @param url リンク先URL
 * @param text 表示文字列
 * @return hrefを持つa要素のHTML片
 */
QString anchorHtml(const QString& url, const QString& text) {
    return QStringLiteral("<a href=\"%1\">%2</a>")
        .arg(url.toHtmlEscaped(), text.toHtmlEscaped());
}

}  // namespace

ZenzaiFamilyRow::ZenzaiFamilyRow(const ZenzaiModelFamily& family,
                                 const QSet<QString>& downloadedKeys, QWidget* parent)
    : QWidget(parent),
      family_(family),
      downloadedKeys_(downloadedKeys),
      variantIndex_(0),
      downloadInProgress_(false),
      updatingCombo_(false),
      radio_(nullptr),
      quantizationCombo_(nullptr),
      downloadButton_(nullptr),
      deleteButton_(nullptr),
      descriptionLabel_(nullptr),
      attributionLabel_(nullptr) {
    QVBoxLayout* rowContainer = new QVBoxLayout(this);
    rowContainer->setContentsMargins(0, 0, 0, 0);

    QHBoxLayout* controlsLayout = new QHBoxLayout();

    radio_ = new QRadioButton(this);
    controlsLayout->addWidget(radio_);

    if (multiVariant()) {
        quantizationCombo_ = new QComboBox(this);
        quantizationCombo_->setObjectName(QStringLiteral("quant_") + family_.familyKey);
        for (const ZenzaiModelOption& variant : family_.variants) {
            const QString label =
                variant.quantLabel.isEmpty() ? variant.displayName : variant.quantLabel;
            quantizationCombo_->addItem(label, variant.key);
        }
        controlsLayout->addWidget(quantizationCombo_);

        connect(quantizationCombo_,
                QOverload<int>::of(&QComboBox::currentIndexChanged), this,
                [this](int index) {
                    if (updatingCombo_) return;
                    setVariantIndex(index);
                });
    }

    controlsLayout->addStretch(1);

    downloadButton_ =
        new QPushButton(QCoreApplication::translate("MainWindow", "Download"), this);
    controlsLayout->addWidget(downloadButton_);

    deleteButton_ = new QPushButton(QCoreApplication::translate("MainWindow", "Delete"), this);
    controlsLayout->addWidget(deleteButton_);

    connect(downloadButton_, &QPushButton::clicked, this, [this]() {
        if (family_.variants.isEmpty()) return;
        emit downloadRequested(artifact().key);
    });
    connect(deleteButton_, &QPushButton::clicked, this, [this]() {
        if (family_.variants.isEmpty()) return;
        emit deleteRequested(artifact().key);
    });

    rowContainer->addLayout(controlsLayout);

    descriptionLabel_ = new QLabel(family_.description, this);
    descriptionLabel_->setIndent(20);
    descriptionLabel_->setWordWrap(true);
    descriptionLabel_->setStyleSheet(QStringLiteral("color: gray;"));
    rowContainer->addWidget(descriptionLabel_);

    // Attribution is only rendered for families that carry it. zenz families
    // keep their pre-existing single-description appearance.
    if (!family_.author.isEmpty() || !family_.sourceUrl.isEmpty() ||
        !family_.licenseName.isEmpty()) {
        QStringList lines;
        if (!family_.licenseName.isEmpty()) {
            lines << QCoreApplication::translate("MainWindow", "Model by %1 · License: %2")
                         .arg(family_.author.toHtmlEscaped(),
                              anchorHtml(family_.licenseUrl, family_.licenseName));
        } else {
            lines << QCoreApplication::translate("MainWindow", "Model by %1")
                         .arg(family_.author.toHtmlEscaped());
        }
        if (!family_.sourceUrl.isEmpty()) {
            lines << QCoreApplication::translate("MainWindow", "Source: %1")
                         .arg(anchorHtml(family_.sourceUrl, family_.sourceUrl));
        }
        lines << QCoreApplication::translate(
            "MainWindow",
            "Downloaded on demand from the source above. Model weights are not bundled with "
            "Hazkey-Community.");

        attributionLabel_ = new QLabel(this);
        attributionLabel_->setObjectName(QStringLiteral("attribution_") +
                                         family_.familyKey);
        attributionLabel_->setTextFormat(Qt::RichText);
        attributionLabel_->setOpenExternalLinks(true);
        attributionLabel_->setTextInteractionFlags(Qt::TextBrowserInteraction);
        attributionLabel_->setWordWrap(true);
        attributionLabel_->setIndent(20);
        attributionLabel_->setStyleSheet(QStringLiteral("color: gray;"));
        attributionLabel_->setText(lines.join(QStringLiteral("<br>")));
        rowContainer->addWidget(attributionLabel_);
    }

    applyBoundVariant();
}

const ZenzaiModelFamily& ZenzaiFamilyRow::family() const { return family_; }

int ZenzaiFamilyRow::variantIndex() const { return variantIndex_; }

const ZenzaiModelOption& ZenzaiFamilyRow::artifact() const {
    return family_.variants.at(variantIndex_);
}

QRadioButton* ZenzaiFamilyRow::radioButton() const { return radio_; }

QComboBox* ZenzaiFamilyRow::quantizationCombo() const { return quantizationCombo_; }

QPushButton* ZenzaiFamilyRow::downloadButton() const { return downloadButton_; }

QPushButton* ZenzaiFamilyRow::deleteButton() const { return deleteButton_; }

QLabel* ZenzaiFamilyRow::attributionLabel() const { return attributionLabel_; }

bool ZenzaiFamilyRow::multiVariant() const { return family_.variants.size() > 1; }

bool ZenzaiFamilyRow::artifactIsActive() const {
    if (family_.variants.isEmpty() || activeKey_.isEmpty()) return false;
    return artifact().key == activeKey_;
}

bool ZenzaiFamilyRow::artifactIsDownloaded() const {
    if (family_.variants.isEmpty()) return false;
    return downloadedKeys_.contains(artifact().key);
}

void ZenzaiFamilyRow::applyBoundVariant() {
    if (family_.variants.isEmpty()) {
        radio_->setEnabled(false);
        downloadButton_->setEnabled(false);
        deleteButton_->setVisible(false);
        if (quantizationCombo_) {
            quantizationCombo_->setEnabled(false);
        }
        return;
    }

    const ZenzaiModelOption& option = artifact();

    // The object names follow the bound artifact so that key-based lookups keep
    // working exactly as they did before quantizations were introduced.
    radio_->setObjectName(QStringLiteral("rb_") + option.key);
    downloadButton_->setObjectName(QStringLiteral("dlBtn_") + option.key);
    deleteButton_->setObjectName(QStringLiteral("delBtn_") + option.key);

    if (quantizationCombo_) {
        updatingCombo_ = true;
        quantizationCombo_->setCurrentIndex(variantIndex_);
        updatingCombo_ = false;
    }

    refreshState(downloadInProgress_, activeKey_);
}

void ZenzaiFamilyRow::setVariantIndex(int index) {
    if (family_.variants.isEmpty()) return;

    const int clamped = qBound(0, index, family_.variants.size() - 1);
    const bool changed = clamped != variantIndex_;
    variantIndex_ = clamped;
    applyBoundVariant();
    if (changed) {
        emit boundVariantChanged(artifact().key);
    }
}

void ZenzaiFamilyRow::refreshState(bool downloadInProgress, const QString& activeKey) {
    downloadInProgress_ = downloadInProgress;
    activeKey_ = activeKey;

    if (family_.variants.isEmpty()) {
        applyBoundVariant();
        return;
    }

    const ZenzaiModelOption& option = artifact();
    const bool downloaded = downloadedKeys_.contains(option.key);

    radio_->setText(ZenzaiModelManager::formatModelLabel(option, downloaded));
    radio_->setEnabled(downloaded);
    radio_->setToolTip(option.description);

    if (quantizationCombo_) {
        quantizationCombo_->setEnabled(!downloadInProgress);
    }

    downloadButton_->setEnabled(!downloaded && !downloadInProgress);
    deleteButton_->setVisible(downloaded);
    deleteButton_->setEnabled(downloaded && !downloadInProgress);
}

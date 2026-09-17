/**
 * @file zenzai_family_row_test.cpp
 * @brief ZenzaiFamilyRowの量子化選択と状態反映のQt Test
 *
 * 一時ディレクトリを環境変数XDG_DATA_HOMEとして使い、系列行が
 * 選択中バリアントのアーティファクト、objectName、およびダウンロード済み状態を
 * 実ファイルの有無とSHA256照合に基づいて正しく反映することを確認する
 */

#include <QtTest/QtTest>

#include <QCryptographicHash>
#include <QDialog>
#include <QDir>
#include <QFile>
#include <QPixmap>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QVBoxLayout>
#include <QVector>

#include "zenzai_family_row.h"
#include "zenzai_models.h"

namespace {

/** @brief 複数バリアント系列の量子化ラベル */
const char* const kMultiVariantLabels[] = {"f16", "Q8_0", "Q5_K_M", "Q4_K_M"};

/** @brief 複数バリアント系列の各バリアントに書き込む固定内容 */
const char* const kMultiVariantPayloads[] = {
    "jinen-small-f16-payload",
    "jinen-small-q8_0-payload",
    "jinen-small-q5_k_m-payload",
    "jinen-small-q4_k_m-payload",
};

/** @brief 複数バリアント系列のバリアント数を返す */
int multiVariantCount() {
    return static_cast<int>(sizeof(kMultiVariantLabels) / sizeof(kMultiVariantLabels[0]));
}

/**
 * @brief バリアントのインデックスからモデルキーを組み立てる
 * @param index 系列内のバリアントインデックス
 * @return カタログキー
 */
QString multiVariantKey(int index) {
    return QStringLiteral("jinen-v2-small-") +
           QString::fromLatin1(kMultiVariantLabels[index]);
}

/**
 * @brief 内容のSHA256をファイルを介さずに計算する
 * @param content ハッシュ対象の内容
 * @return 16進文字列のSHA256
 */
QString sha256Of(const QByteArray& content) {
    return QString::fromLatin1(
        QCryptographicHash::hash(content, QCryptographicHash::Sha256).toHex());
}

}  // namespace

/**
 * @brief 系列行の量子化選択と状態反映を検証するテストクラス
 *
 * @details テスト全体では、環境変数XDG_DATA_HOMEを一時ディレクトリに差し替え、各テストの開始時にその内容を削除して再作成する
 *          カタログが期待するSHA256はメモリ上で計算し、実際に存在させたいバリアントだけをcommitMultiVariant()でディスクへ書き出す
 *          可視状態を検査するテストでは行ウィジェットをshow()し、実ダイアログと同じ可視階層で確認する
 */
class ZenzaiFamilyRowTest : public QObject {
    Q_OBJECT

   private slots:
    /** @brief テスト全体の開始時に環境変数を保存して一時ディレクトリを設定する */
    void initTestCase();
    /** @brief テスト全体の終了時に環境変数XDG_DATA_HOMEを元の状態へ戻す */
    void cleanupTestCase();
    /** @brief 各テストの開始時に一時ディレクトリの内容を初期化する */
    void init();
    /** @brief 各テストの終了処理を行う (現在は空のfixtureフック) */
    void cleanup();

    /** @brief 複数バリアント系列が量子化コンボを提示することを検証する */
    void testMultiVariantFamilyExposesQuantizationCombo();
    /** @brief 単一バリアント系列がコンボを追加せず従来のobjectNameを保つことを検証する */
    void testSingleVariantFamilyHasNoCombo();
    /** @brief 帰属情報を持つ系列だけが帰属ラベルを表示することを検証する */
    void testAttributionLabelRenderedForAttributedFamilyOnly();
    /** @brief バリアント切り替えがアーティファクトとobjectNameを更新することを検証する */
    void testVariantRebindingUpdatesArtifactAndObjectNames();
    /** @brief 未ダウンロードのバリアントが選択も削除もできないことを検証する */
    void testUndownloadedVariantIsNotSelectableOrErasable();
    /** @brief ダウンロード済みの複数量子化を独立に選択できることを検証する */
    void testTwoDownloadedQuantsAreIndependentlySelectable();
    /** @brief ダウンロード/削除シグナルが束縛中アーティファクトのキーを運ぶことを検証する */
    void testSignalsCarryBoundArtifactKey();
    /** @brief バリアント変更シグナルが新しいキーを1回だけ運ぶことを検証する */
    void testBoundVariantChangedSignalCarriesNewKey();
    /** @brief ダウンロード中に操作がロックされ、完了後に復旧することを検証する */
    void testRefreshStateDuringDownloadDisablesActions();
    /** @brief 行が渡されたスナップショットだけを参照することを検証する */
    void testRefreshStateUsesSnapshotWithoutDiskScan();
    /** @brief 実カタログから組んだダイアログが描画され、量子化切替で見た目が変わることを検証する */
    void testRealCatalogDialogRendersAndRebinds();

   private:
    /**
     * @brief 複数バリアント系列を構築する (どのバリアントもディスクへは書き出さない)
     * @return jinen-v2-small相当の4バリアント系列
     */
    ZenzaiModelFamily makeMultiVariantFamily() const;
    /**
     * @brief 単一バリアント系列を構築する (ディスクへは書き出さない)
     * @return zenz-v3.2-small相当の単一バリアント系列
     */
    ZenzaiModelFamily makeSingleVariantFamily() const;
    /**
     * @brief 指定バリアントのファイルをディスクへ書き出してダウンロード済み状態にする
     * @param index 書き出すバリアントの系列内インデックス
     */
    void commitMultiVariant(int index) const;
    /**
     * @brief モデルファイルを管理対象ディレクトリへ書き出す
     * @param key 書き出すモデルキー
     * @param content 書き出す内容
     */
    void writeModel(const QString& key, const QByteArray& content) const;
    const QSet<QString>& snapshotFor(const ZenzaiModelFamily& family);

    /** @brief 全テストでファイルを作成する一時ディレクトリ */
    QTemporaryDir tempDir;
    /** @brief initTestCase()前の環境変数XDG_DATA_HOME値 空の場合は未設定を表す */
    QString originalXdgDataHome;
    QSet<QString> downloadedSnapshot;
};

void ZenzaiFamilyRowTest::initTestCase() {
    originalXdgDataHome = qEnvironmentVariable("XDG_DATA_HOME");
    qputenv("XDG_DATA_HOME", tempDir.path().toUtf8());
}

void ZenzaiFamilyRowTest::cleanupTestCase() {
    if (originalXdgDataHome.isEmpty()) {
        qunsetenv("XDG_DATA_HOME");
    } else {
        qputenv("XDG_DATA_HOME", originalXdgDataHome.toUtf8());
    }
}

void ZenzaiFamilyRowTest::init() {
    QDir(tempDir.path()).removeRecursively();
    QDir().mkpath(tempDir.path());
}

void ZenzaiFamilyRowTest::cleanup() {}

void ZenzaiFamilyRowTest::writeModel(const QString& key, const QByteArray& content) const {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QFile file(ZenzaiModelManager::getModelPath(key));
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(content);
    file.close();
}

const QSet<QString>& ZenzaiFamilyRowTest::snapshotFor(
    const ZenzaiModelFamily& family) {
    downloadedSnapshot = ZenzaiModelManager::downloadedModelKeys(family.variants);
    return downloadedSnapshot;
}

void ZenzaiFamilyRowTest::commitMultiVariant(int index) const {
    writeModel(multiVariantKey(index),
               QByteArray(kMultiVariantPayloads[index]));
}

ZenzaiModelFamily ZenzaiFamilyRowTest::makeMultiVariantFamily() const {
    ZenzaiModelFamily family;
    family.familyKey = QStringLiteral("jinen-v2-small");
    family.displayName = QStringLiteral("jinen-v2-small");
    family.description = QStringLiteral("Jinen v2 small model. Choose a quantization.");

    for (int i = 0; i < multiVariantCount(); ++i) {
        const QString label = QString::fromLatin1(kMultiVariantLabels[i]);
        const QByteArray content(kMultiVariantPayloads[i]);
        const QString key = multiVariantKey(i);

        ZenzaiModelOption option;
        option.key = key;
        option.displayName = QStringLiteral("jinen-v2-small (%1)").arg(label);
        option.description = family.description;
        option.url = QStringLiteral("https://example.invalid/%1.gguf").arg(key);
        // The catalog pins the digest of the payload; only a file with this
        // content counts as downloaded.
        option.sha256 = sha256Of(content);
        option.sizeDisplay = QStringLiteral("~1 MB");
        option.recommended = false;
        option.isLegacyGen = false;
        option.expectedBytes = static_cast<qint64>(content.size());
        option.quantLabel = label;
        family.variants.append(option);
    }
    return family;
}

ZenzaiModelFamily ZenzaiFamilyRowTest::makeSingleVariantFamily() const {
    const QString key = QStringLiteral("zenz-v3.2-small");
    const QByteArray content("zenz-small-payload");

    ZenzaiModelFamily family;
    family.familyKey = key;
    family.displayName = key;
    family.description = QStringLiteral("Recommended: Latest version.");

    ZenzaiModelOption option;
    option.key = key;
    option.displayName = QStringLiteral("zenz-v3.2-small (Q5_K_M)");
    option.description = family.description;
    option.url = QStringLiteral("https://example.invalid/%1.gguf").arg(key);
    option.sha256 = sha256Of(content);
    option.sizeDisplay = QStringLiteral("~74 MB");
    option.recommended = true;
    option.isLegacyGen = false;
    option.expectedBytes = 0;
    option.quantLabel = QString();
    family.variants.append(option);
    return family;
}

void ZenzaiFamilyRowTest::testMultiVariantFamilyExposesQuantizationCombo() {
    const ZenzaiModelFamily family = makeMultiVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    QVERIFY(row.multiVariant());
    QComboBox* combo = row.quantizationCombo();
    QVERIFY2(combo != nullptr, "multi-variant family must expose a quantization combo");
    QCOMPARE(combo->count(), 4);

    const QStringList expectedLabels = {QStringLiteral("f16"), QStringLiteral("Q8_0"),
                                        QStringLiteral("Q5_K_M"), QStringLiteral("Q4_K_M")};
    for (int i = 0; i < expectedLabels.size(); ++i) {
        QCOMPARE(combo->itemText(i), expectedLabels.at(i));
        QCOMPARE(combo->itemData(i).toString(), family.variants.at(i).key);
    }
    // The combo starts on the first variant and the row is bound to it.
    QCOMPARE(combo->currentIndex(), 0);
    QCOMPARE(row.variantIndex(), 0);
    QCOMPARE(row.artifact().key, family.variants.at(0).key);
}

void ZenzaiFamilyRowTest::testSingleVariantFamilyHasNoCombo() {
    const ZenzaiModelFamily family = makeSingleVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    QVERIFY(!row.multiVariant());
    QVERIFY2(row.quantizationCombo() == nullptr,
             "single-variant family must not add a quantization combo");
    // Legacy object names stay key-based for the sole artifact.
    QCOMPARE(row.radioButton()->objectName(), QStringLiteral("rb_") + family.familyKey);
    QCOMPARE(row.downloadButton()->objectName(), QStringLiteral("dlBtn_") + family.familyKey);
    QCOMPARE(row.deleteButton()->objectName(), QStringLiteral("delBtn_") + family.familyKey);
    QCOMPARE(row.artifact().key, family.familyKey);
    // Zero expectedBytes keeps the pre-existing size-validation opt-out.
    QCOMPARE(row.artifact().expectedBytes, Q_INT64_C(0));
}

void ZenzaiFamilyRowTest::testAttributionLabelRenderedForAttributedFamilyOnly() {
    // A family that carries attribution metadata renders the CC-BY-SA-4.0
    // disclosure with clickable source/license links.
    ZenzaiModelFamily attributed = makeMultiVariantFamily();
    attributed.author = QStringLiteral("togatogah");
    attributed.sourceUrl =
        QStringLiteral("https://huggingface.co/togatogah/jinen-v2-small.gguf");
    attributed.licenseName = QStringLiteral("CC-BY-SA-4.0");
    attributed.licenseUrl =
        QStringLiteral("https://creativecommons.org/licenses/by-sa/4.0/");

    ZenzaiFamilyRow attributedRow(attributed, snapshotFor(attributed));
    attributedRow.show();

    QLabel* label = attributedRow.attributionLabel();
    QVERIFY2(label != nullptr, "an attributed family must render an attribution label");
    QCOMPARE(label->objectName(),
             QStringLiteral("attribution_") + attributed.familyKey);
    QVERIFY2(label->isVisible(), "the attribution label must be visible");
    QCOMPARE(label->textFormat(), Qt::RichText);
    QVERIFY2(label->textInteractionFlags() & Qt::LinksAccessibleByMouse,
             "the attribution links must be clickable");

    const QString text = label->text();
    QVERIFY2(text.contains(QStringLiteral("togatogah")),
             "the attribution must credit the model author");
    QVERIFY2(text.contains(QStringLiteral("CC-BY-SA-4.0")),
             "the attribution must name the license");
    QVERIFY2(text.contains(QStringLiteral("href=\"") + attributed.sourceUrl +
                           QStringLiteral("\"")),
             "the source repository must be a clickable link");
    QVERIFY2(text.contains(QStringLiteral("href=\"") + attributed.licenseUrl +
                           QStringLiteral("\"")),
             "the license must be a clickable link");
    QCOMPARE(text.count(QStringLiteral("<a href=\"")), 2);
    QVERIFY2(text.contains(QStringLiteral("not bundled")),
             "the disclosure must state that weights are not bundled");

    // A family without attribution metadata keeps the pre-existing appearance.
    const ZenzaiModelFamily plain = makeSingleVariantFamily();
    ZenzaiFamilyRow plainRow(plain, snapshotFor(plain));
    plainRow.show();
    QVERIFY2(plainRow.attributionLabel() == nullptr,
             "a family without attribution metadata must not add a disclosure row");
}

void ZenzaiFamilyRowTest::testVariantRebindingUpdatesArtifactAndObjectNames() {
    const ZenzaiModelFamily family = makeMultiVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    row.setVariantIndex(2);  // Q5_K_M
    const QString expectedKey = QStringLiteral("jinen-v2-small-Q5_K_M");
    QCOMPARE(row.variantIndex(), 2);
    QCOMPARE(row.artifact().key, expectedKey);
    QCOMPARE(row.artifact().quantLabel, QStringLiteral("Q5_K_M"));
    QCOMPARE(row.radioButton()->objectName(), QStringLiteral("rb_") + expectedKey);
    QCOMPARE(row.downloadButton()->objectName(), QStringLiteral("dlBtn_") + expectedKey);
    QCOMPARE(row.deleteButton()->objectName(), QStringLiteral("delBtn_") + expectedKey);
    QCOMPARE(row.quantizationCombo()->currentIndex(), 2);

    // Selecting through the combo must rebind too.
    row.quantizationCombo()->setCurrentIndex(3);  // Q4_K_M
    QCOMPARE(row.artifact().key, QStringLiteral("jinen-v2-small-Q4_K_M"));
    QCOMPARE(row.downloadButton()->objectName(),
             QStringLiteral("dlBtn_jinen-v2-small-Q4_K_M"));

    // Out-of-range requests clamp to the available variants.
    row.setVariantIndex(99);
    QCOMPARE(row.variantIndex(), family.variants.size() - 1);
    row.setVariantIndex(-5);
    QCOMPARE(row.variantIndex(), 0);
}

void ZenzaiFamilyRowTest::testUndownloadedVariantIsNotSelectableOrErasable() {
    // Only Q5_K_M (index 2) is committed to disk.
    commitMultiVariant(2);

    const ZenzaiModelFamily family = makeMultiVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    row.setVariantIndex(2);
    row.refreshState(false, QStringLiteral("jinen-v2-small-Q4_K_M"));
    QVERIFY(row.artifactIsDownloaded());
    QVERIFY2(row.radioButton()->isEnabled(),
             "a downloaded variant must be selectable via its radio button");
    QVERIFY2(row.deleteButton()->isVisible(),
             "a downloaded variant must offer a delete button");
    QVERIFY(row.deleteButton()->isEnabled());
    QVERIFY2(!row.downloadButton()->isEnabled(),
             "a downloaded variant must not offer a download button");
    QVERIFY(row.radioButton()->text().contains(QStringLiteral("(downloaded)")));

    // The active artifact is Q4_K_M, so this row must not claim to be active.
    QVERIFY(!row.artifactIsActive());

    row.setVariantIndex(0);  // f16 -- not committed
    row.refreshState(false, QStringLiteral("jinen-v2-small-Q4_K_M"));
    QVERIFY(!row.artifactIsDownloaded());
    QVERIFY2(!row.radioButton()->isEnabled(),
             "an undownloaded variant must not be selectable");
    QVERIFY2(row.deleteButton()->isHidden(),
             "an undownloaded variant must not offer a delete button");
    QVERIFY2(row.downloadButton()->isEnabled(),
             "an undownloaded variant must offer a download button");
    QVERIFY(!row.radioButton()->text().contains(QStringLiteral("(downloaded)")));
}

void ZenzaiFamilyRowTest::testTwoDownloadedQuantsAreIndependentlySelectable() {
    // Commit only two of the four variants to disk.
    commitMultiVariant(1);
    commitMultiVariant(2);

    const ZenzaiModelFamily family = makeMultiVariantFamily();
    const QString keyQ8 = family.variants.at(1).key;
    const QString keyQ5 = family.variants.at(2).key;
    QVERIFY(QFile::exists(ZenzaiModelManager::getModelPath(keyQ8)));
    QVERIFY(QFile::exists(ZenzaiModelManager::getModelPath(keyQ5)));

    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    row.setVariantIndex(1);
    row.refreshState(false, keyQ8);
    QVERIFY(row.artifactIsDownloaded());
    QVERIFY(row.radioButton()->isEnabled());
    QVERIFY(row.deleteButton()->isVisible());
    QVERIFY(row.artifactIsActive());

    row.setVariantIndex(2);
    row.refreshState(false, keyQ8);
    QVERIFY(row.artifactIsDownloaded());
    QVERIFY(row.radioButton()->isEnabled());
    QVERIFY(row.deleteButton()->isVisible());
    QVERIFY(!row.artifactIsActive());

    // A third variant stays undownloaded and therefore unusable.
    row.setVariantIndex(0);
    row.refreshState(false, keyQ8);
    QVERIFY(!row.artifactIsDownloaded());
    QVERIFY(!row.radioButton()->isEnabled());
    QVERIFY(row.deleteButton()->isHidden());
}

void ZenzaiFamilyRowTest::testSignalsCarryBoundArtifactKey() {
    // Only Q4_K_M (index 3) is committed to disk.
    commitMultiVariant(3);

    const ZenzaiModelFamily family = makeMultiVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    QSignalSpy downloadSpy(&row, &ZenzaiFamilyRow::downloadRequested);
    QSignalSpy deleteSpy(&row, &ZenzaiFamilyRow::deleteRequested);
    QVERIFY(downloadSpy.isValid());
    QVERIFY(deleteSpy.isValid());

    // Undownloaded f16 offers a download button carrying its own key.
    row.setVariantIndex(0);
    row.refreshState(false, QString());
    QVERIFY(row.downloadButton()->isEnabled());
    row.downloadButton()->click();
    QCOMPARE(downloadSpy.count(), 1);
    QCOMPARE(downloadSpy.takeFirst().at(0).toString(), family.variants.at(0).key);

    // Downloaded Q4_K_M offers a delete button carrying its own key.
    row.setVariantIndex(3);
    row.refreshState(false, QString());
    QVERIFY(row.deleteButton()->isVisible());
    QVERIFY(row.deleteButton()->isEnabled());
    row.deleteButton()->click();
    QCOMPARE(deleteSpy.count(), 1);
    QCOMPARE(deleteSpy.takeFirst().at(0).toString(), family.variants.at(3).key);
}

void ZenzaiFamilyRowTest::testBoundVariantChangedSignalCarriesNewKey() {
    const ZenzaiModelFamily family = makeMultiVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    QSignalSpy spy(&row, &ZenzaiFamilyRow::boundVariantChanged);
    QVERIFY(spy.isValid());

    row.setVariantIndex(2);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.takeFirst().at(0).toString(), QStringLiteral("jinen-v2-small-Q5_K_M"));

    // Re-selecting the same variant must not emit again.
    row.setVariantIndex(2);
    QCOMPARE(spy.count(), 0);
}

void ZenzaiFamilyRowTest::testRefreshStateDuringDownloadDisablesActions() {
    commitMultiVariant(2);

    const ZenzaiModelFamily family = makeMultiVariantFamily();
    ZenzaiFamilyRow row(family, snapshotFor(family));
    row.show();

    // Downloaded variant: delete normally enabled, download normally disabled.
    row.setVariantIndex(2);
    row.refreshState(false, QString());
    QVERIFY(row.deleteButton()->isEnabled());
    QVERIFY(!row.downloadButton()->isEnabled());
    QVERIFY(row.radioButton()->isEnabled());

    // During a download the download/delete actions and the quantization combo
    // are locked out. The radio button keeps its disk-derived state because the
    // dialog blocks activation through the OK button instead.
    row.refreshState(true, QString());
    QVERIFY(!row.downloadButton()->isEnabled());
    QVERIFY(!row.deleteButton()->isEnabled());
    QVERIFY(row.radioButton()->isEnabled());
    QVERIFY(!row.quantizationCombo()->isEnabled());

    // After the download settles the controls recover from the on-disk state.
    row.refreshState(false, QString());
    QVERIFY(row.deleteButton()->isEnabled());
    QVERIFY(!row.downloadButton()->isEnabled());
    QVERIFY(row.quantizationCombo()->isEnabled());
}

void ZenzaiFamilyRowTest::testRefreshStateUsesSnapshotWithoutDiskScan() {
    const ZenzaiModelFamily family = makeSingleVariantFamily();
    QSet<QString> snapshot = {family.variants.first().key};
    ZenzaiFamilyRow row(family, snapshot);

    // No model file exists, but the row must honor the supplied dialog snapshot.
    row.refreshState(false, QString());
    QVERIFY(row.artifactIsDownloaded());
    QVERIFY(row.radioButton()->isEnabled());

    // Changing the snapshot changes the row state without any file I/O.
    snapshot.clear();
    row.refreshState(false, QString());
    QVERIFY(!row.artifactIsDownloaded());
    QVERIFY(!row.radioButton()->isEnabled());
}

void ZenzaiFamilyRowTest::testRealCatalogDialogRendersAndRebinds() {
    // Build a dialog out of the real application catalog, exactly like
    // MainWindow::onDownloadZenzaiModel() does, and render it offscreen.
    QDialog dialog;
    QVBoxLayout* layout = new QVBoxLayout(&dialog);
    const QVector<ZenzaiModelFamily>& families = availableZenzaiModelFamilies();
    QVERIFY(families.size() >= 5);

    QVector<ZenzaiFamilyRow*> rows;
    for (const ZenzaiModelFamily& family : families) {
        QVERIFY(!family.variants.isEmpty());
        downloadedSnapshot =
            ZenzaiModelManager::downloadedModelKeys(family.variants);
        ZenzaiFamilyRow* row =
            new ZenzaiFamilyRow(family, downloadedSnapshot, &dialog);
        row->setObjectName(QStringLiteral("row_") + family.familyKey);
        row->refreshState(false, QString());
        rows.append(row);
        layout->addWidget(row);
    }
    dialog.resize(720, 520);
    dialog.show();
    QVERIFY(QTest::qWaitForWindowExposed(&dialog));

    // zenz families keep the legacy single-variant appearance.
    for (int i = 0; i < 3; ++i) {
        QVERIFY2(rows.at(i)->quantizationCombo() == nullptr,
                 qPrintable(QStringLiteral("zenz family %1 must not have a combo")
                                .arg(families.at(i).familyKey)));
    }

    // The jinen families offer all four quantizations.
    ZenzaiFamilyRow* jinen = nullptr;
    for (ZenzaiFamilyRow* row : rows) {
        if (row->family().familyKey == QStringLiteral("jinen-v2-small")) {
            jinen = row;
        }
    }
    QVERIFY(jinen != nullptr);
    QCOMPARE(jinen->quantizationCombo()->count(), 4);

    // The real catalog discloses attribution for exactly the two jinen families,
    // and those rows credit togatogah under CC-BY-SA-4.0.
    int attributedRows = 0;
    for (ZenzaiFamilyRow* row : rows) {
        QLabel* attribution = row->attributionLabel();
        if (row->family().familyKey.startsWith(QStringLiteral("jinen-v2-"))) {
            QVERIFY2(attribution != nullptr,
                     qPrintable(QStringLiteral("jinen family %1 must render attribution")
                                    .arg(row->family().familyKey)));
            QVERIFY(attribution->isVisible());
            QVERIFY2(attribution->text().contains(QStringLiteral("togatogah")),
                     qPrintable(QStringLiteral("jinen family %1 must credit togatogah")
                                    .arg(row->family().familyKey)));
            QVERIFY2(attribution->text().contains(QStringLiteral("CC-BY-SA-4.0")),
                     qPrintable(QStringLiteral("jinen family %1 must disclose CC-BY-SA-4.0")
                                    .arg(row->family().familyKey)));
            QVERIFY2(attribution->text().contains(row->family().sourceUrl),
                     qPrintable(QStringLiteral("jinen family %1 must link its source repository")
                                    .arg(row->family().familyKey)));
            ++attributedRows;
        } else {
            QVERIFY2(attribution == nullptr,
                     qPrintable(QStringLiteral("zenz family %1 must not render attribution")
                                    .arg(row->family().familyKey)));
        }
    }
    QCOMPARE(attributedRows, 2);

    const QString outDir = QDir::tempPath() + QStringLiteral("/hazkey-todo3-qa");
    QDir().mkpath(outDir);

    jinen->setVariantIndex(2);  // Q5_K_M
    jinen->refreshState(false, QString());
    // Changing the label resizes the row; let the layout settle exactly as the
    // dialog's own event loop would before judging geometry or pixels.
    dialog.layout()->activate();
    QCoreApplication::processEvents();
    QVERIFY2(jinen->radioButton()->width() >= jinen->radioButton()->sizeHint().width(),
             "the radio must be wide enough for its label");
    QVERIFY2(jinen->radioButton()->geometry().right() <
                 jinen->quantizationCombo()->x(),
             "the quantization combo must not overlap the model label");
    const QPixmap q5 = jinen->grab();
    QVERIFY(!q5.isNull());
    QVERIFY(q5.width() > 0 && q5.height() > 0);
    QVERIFY(q5.save(outDir + QStringLiteral("/jinen-row-Q5_K_M.png")));

    if (qEnvironmentVariableIsSet("HAZKEY_QA_DUMP_GEOMETRY")) {
        qInfo() << "jinen-v2-small row" << jinen->geometry() << "radio"
                << jinen->radioButton()->geometry() << "radio sizeHint"
                << jinen->radioButton()->sizeHint() << "combo"
                << jinen->quantizationCombo()->geometry() << "download"
                << jinen->downloadButton()->geometry();
    }

    jinen->setVariantIndex(3);  // Q4_K_M
    jinen->refreshState(false, QString());
    dialog.layout()->activate();
    QCoreApplication::processEvents();
    QVERIFY2(jinen->radioButton()->width() >= jinen->radioButton()->sizeHint().width(),
             "the radio must stay wide enough after rebinding");
    const QPixmap q4 = jinen->grab();
    QVERIFY(!q4.isNull());
    QVERIFY(q4.save(outDir + QStringLiteral("/jinen-row-Q4_K_M.png")));

    // The rendered row really changes when the bound quantization changes.
    QVERIFY2(q5.toImage() != q4.toImage(),
             "rebinding the quantization must change the rendered row");
    QVERIFY2(jinen->downloadButton()->objectName().contains(QStringLiteral("Q4_K_M")),
             "the download button must follow the bound quantization");

    const QPixmap whole = dialog.grab();
    QVERIFY(whole.save(outDir + QStringLiteral("/dialog-all-families.png")));

    qInfo() << "Todo3 QA artifacts written to" << outDir;
}

QTEST_MAIN(ZenzaiFamilyRowTest)
#include "zenzai_family_row_test.moc"

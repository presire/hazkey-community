#include <QtTest/QtTest>

#include "zenzai_dialog_selection.h"

namespace {

ZenzaiModelFamily makeFamily(const QString& familyKey, const QStringList& variantKeys) {
    ZenzaiModelFamily family;
    family.familyKey = familyKey;
    for (const QString& key : variantKeys) {
        ZenzaiModelOption option;
        option.key = key;
        family.variants.append(option);
    }
    return family;
}

}  // namespace

/**
 * @brief モデル削除後のチェック選択解決の回帰ガード
 */
class ZenzaiDialogSelectionTest : public QObject {
    Q_OBJECT

private slots:
    void prefersSameFamilyReplacementVariant();
    void fallsBackToCatalogOrderWhenSameFamilyHasNoReplacement();
    void clearsSelectionWhenNoDownloadedModelsRemain();
    void preservesSelectionWhenDeletedModelWasUnrelated();
    void preservesCheckedSelectionWhenActiveModelIsDeleted();
    void selectsCatalogModelWhenActiveModelIsDeletedWithoutCheckedSelection();
    void activatesOnlyExistingDownloadedSelection();
};

void ZenzaiDialogSelectionTest::prefersSameFamilyReplacementVariant() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("single"), {QStringLiteral("single-model")}),
        makeFamily(QStringLiteral("multi"), {QStringLiteral("multi-f16"),
                                             QStringLiteral("multi-q4"),
                                             QStringLiteral("multi-q5")}),
    };
    const QSet<QString> downloadedKeys = {QStringLiteral("single-model"),
                                          QStringLiteral("multi-q4")};

    const auto selection = reconcileZenzaiDialogSelection(
        families, downloadedKeys, QStringLiteral("multi-q5"),
        ZenzaiDialogSelection{1, 2}, QStringLiteral("multi-q5"));

    QVERIFY(selection.has_value());
    QCOMPARE(selection->familyIndex, 1);
    QCOMPARE(selection->variantIndex, 1);
}

void ZenzaiDialogSelectionTest::fallsBackToCatalogOrderWhenSameFamilyHasNoReplacement() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("single"), {QStringLiteral("single-model")}),
        makeFamily(QStringLiteral("multi"), {QStringLiteral("multi-q4")}),
    };
    const QSet<QString> downloadedKeys = {QStringLiteral("single-model")};

    const auto selection = reconcileZenzaiDialogSelection(
        families, downloadedKeys, QStringLiteral("multi-q4"),
        ZenzaiDialogSelection{1, 0}, QStringLiteral("multi-q4"));

    QVERIFY(selection.has_value());
    QCOMPARE(selection->familyIndex, 0);
    QCOMPARE(selection->variantIndex, 0);
}

void ZenzaiDialogSelectionTest::clearsSelectionWhenNoDownloadedModelsRemain() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("single"), {QStringLiteral("single-model")}),
    };

    const auto selection = reconcileZenzaiDialogSelection(
        families, {}, QStringLiteral("single-model"),
        ZenzaiDialogSelection{0, 0}, QStringLiteral("single-model"));

    QVERIFY(!selection.has_value());
}

void ZenzaiDialogSelectionTest::preservesSelectionWhenDeletedModelWasUnrelated() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("first"), {QStringLiteral("first-model")}),
        makeFamily(QStringLiteral("second"), {QStringLiteral("second-model")}),
    };
    const QSet<QString> downloadedKeys = {QStringLiteral("first-model"),
                                          QStringLiteral("second-model")};

    const auto selection = reconcileZenzaiDialogSelection(
        families, downloadedKeys, QStringLiteral("second-model"),
        ZenzaiDialogSelection{0, 0}, QString());

    QVERIFY(selection.has_value());
    QCOMPARE(selection->familyIndex, 0);
    QCOMPARE(selection->variantIndex, 0);
}

void ZenzaiDialogSelectionTest::preservesCheckedSelectionWhenActiveModelIsDeleted() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("active"), {QStringLiteral("active-model")}),
        makeFamily(QStringLiteral("other"), {QStringLiteral("other-model")}),
    };
    // 削除直後のダウンロード済み集合には、消えた有効化モデルは含まれない
    const QSet<QString> downloadedKeys = {QStringLiteral("other-model")};

    const auto selection = reconcileZenzaiDialogSelection(
        families, downloadedKeys, QStringLiteral("active-model"),
        ZenzaiDialogSelection{1, 0}, QStringLiteral("active-model"));

    QVERIFY(selection.has_value());
    QCOMPARE(selection->familyIndex, 1);
    QCOMPARE(selection->variantIndex, 0);
}

void ZenzaiDialogSelectionTest::selectsCatalogModelWhenActiveModelIsDeletedWithoutCheckedSelection() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("active"), {QStringLiteral("active-model")}),
        makeFamily(QStringLiteral("other"), {QStringLiteral("other-model")}),
    };
    const QSet<QString> downloadedKeys = {QStringLiteral("other-model")};

    const auto selection = reconcileZenzaiDialogSelection(
        families, downloadedKeys, QStringLiteral("active-model"), std::nullopt,
        QStringLiteral("active-model"));

    QVERIFY(selection.has_value());
    QCOMPARE(selection->familyIndex, 1);
    QCOMPARE(selection->variantIndex, 0);
}

void ZenzaiDialogSelectionTest::activatesOnlyExistingDownloadedSelection() {
    const QVector<ZenzaiModelFamily> families = {
        makeFamily(QStringLiteral("a"), {QStringLiteral("a-model")}),
        makeFamily(QStringLiteral("b"), {QStringLiteral("b-f16"), QStringLiteral("b-q4")}),
    };
    const QSet<QString> downloadedKeys = {QStringLiteral("a-model"), QStringLiteral("b-q4")};

    QVERIFY(isZenzaiSelectionActivatable(families, downloadedKeys, ZenzaiDialogSelection{0, 0}));
    QVERIFY(isZenzaiSelectionActivatable(families, downloadedKeys, ZenzaiDialogSelection{1, 1}));
    QVERIFY(!isZenzaiSelectionActivatable(families, downloadedKeys, ZenzaiDialogSelection{1, 0}));
    QVERIFY(!isZenzaiSelectionActivatable(families, downloadedKeys, ZenzaiDialogSelection{0, 1}));
    QVERIFY(!isZenzaiSelectionActivatable(families, downloadedKeys, std::nullopt));
}

QTEST_MAIN(ZenzaiDialogSelectionTest)

#include "zenzai_dialog_selection_test.moc"

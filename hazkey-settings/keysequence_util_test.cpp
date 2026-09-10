/**
 * @file keysequence_util_test.cpp
 * @brief keysequence_util.hのQtテスト
 *
 * QKeySequence ⇔ fcitx5 Key文字列の相互変換が、Ctrl/Control および Meta/Super の表記マッピングを含めて正しく行われることを検証する
 * テストは、Qt Testフレームワーク (QTEST_MAIN) で実行される
 */

#include <QtTest/QtTest>

#include "keysequence_util.h"

/**
 * @brief keysequence_utilの変換APIを検証するテストクラス
 *
 * テストスロットは、以下の4系統からなる:
 * - testQtToFcitxRoundTrip: データ駆動の双方向変換テスト
 * - testEmptyInput: 空入力の挙動
 * - testSingleKeyNoModifier: 修飾キーなし単一キーの挙動
 * - testRoundTripPreserves: 往復変換で元のシーケンスが保持されること
 */
class KeySequenceUtilTest : public QObject {
    Q_OBJECT

   private slots:
    void testQtToFcitxRoundTrip_data();
    void testQtToFcitxRoundTrip();
    void testEmptyInput();
    void testSingleKeyNoModifier();
    void testRoundTripPreserves();
};

/**
 * @brief testQtToFcitxRoundTripのデータプロバイダ
 *
 * 各データ行は、Qt表記 (qtString) と期待されるfcitx5表記 (fcitxString) のペアを保持し、
 * Ctrl/Control、Meta/Super のマッピング、変更不要なトークン、修飾キーなしの単一キーを網羅する
 */
void KeySequenceUtilTest::testQtToFcitxRoundTrip_data() {
    QTest::addColumn<QString>("qtString");
    QTest::addColumn<QString>("fcitxString");

    QTest::newRow("ctrl shift l") << QStringLiteral("Ctrl+Shift+L")
                                  << QStringLiteral("Control+Shift+L");
    QTest::newRow("ctrl l") << QStringLiteral("Ctrl+L")
                            << QStringLiteral("Control+L");
    QTest::newRow("alt shift x unchanged")
        << QStringLiteral("Alt+Shift+X") << QStringLiteral("Alt+Shift+X");
    QTest::newRow("meta k") << QStringLiteral("Meta+K")
                            << QStringLiteral("Super+K");
    QTest::newRow("f5 single key") << QStringLiteral("F5")
                                     << QStringLiteral("F5");
}

/**
 * @brief Qt表記とfcitx5表記の双方向変換を検証する
 *
 * データプロバイダ (testQtToFcitxRoundTrip_data) の各行について:
 * - Qt → fcitx5: fcitxKeyStringFromQKeySequenceの結果が期待値と一致する
 * - fcitx5 → Qt: qKeySequenceFromFcitxKeyStringの結果をPortableTextで文字列化したものが元のQt表記と一致する
 */
void KeySequenceUtilTest::testQtToFcitxRoundTrip() {
    QFETCH(QString, qtString);
    QFETCH(QString, fcitxString);

    // Qt -> fcitx5
    QCOMPARE(fcitxKeyStringFromQKeySequence(
                 QKeySequence::fromString(qtString, QKeySequence::PortableText)),
             fcitxString);
    // fcitx5 -> Qt
    QCOMPARE(qKeySequenceFromFcitxKeyString(fcitxString)
                 .toString(QKeySequence::PortableText),
             qtString);
}

/**
 * @brief 空入力の挙動を検証する
 *
 * 空のQKeySequenceは空文字列に、空文字列は空のQKeySequenceに変換されることを確認する
 */
void KeySequenceUtilTest::testEmptyInput() {
    QCOMPARE(fcitxKeyStringFromQKeySequence(QKeySequence()), QString());
    QCOMPARE(qKeySequenceFromFcitxKeyString(QString()), QKeySequence());
}

/**
 * @brief 修飾キーなしの単一キーがそのまま維持されることを検証する
 *
 * マッピング対象外のトークン (例: "L") は Qt → fcitx5、fcitx5 → Qt のどちらの方向でも変更されないことを確認する
 */
void KeySequenceUtilTest::testSingleKeyNoModifier() {
    QCOMPARE(fcitxKeyStringFromQKeySequence(
                 QKeySequence::fromString(QLatin1String("L"),
                                          QKeySequence::PortableText)),
             QLatin1String("L"));
    QCOMPARE(qKeySequenceFromFcitxKeyString(QLatin1String("L"))
                 .toString(QKeySequence::PortableText),
             QLatin1String("L"));
}

/**
 * @brief 往復変換で元のQKeySequenceが保持されることを検証する
 *
 * 代表的な入力 (Ctrl/Control、Meta/Super、変更不要トークン、単一キー) について、
 * fcitx5表記への変換後にQt表記へ戻しても元のシーケンスと等しくなることを確認する
 */
void KeySequenceUtilTest::testRoundTripPreserves() {
    const QStringList inputs = {
        QStringLiteral("Ctrl+Shift+L"),
        QStringLiteral("Ctrl+L"),
        QStringLiteral("Alt+Shift+X"),
        QStringLiteral("Meta+K"),
        QStringLiteral("L"),
    };
    for (const QString& input : inputs) {
        const QKeySequence original =
            QKeySequence::fromString(input, QKeySequence::PortableText);
        QCOMPARE(qKeySequenceFromFcitxKeyString(
                     fcitxKeyStringFromQKeySequence(original)),
                 original);
    }
}

QTEST_MAIN(KeySequenceUtilTest)
#include "keysequence_util_test.moc"

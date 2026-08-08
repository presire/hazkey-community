#include <QtTest/QtTest>

#include "keysequence_util.h"

class KeySequenceUtilTest : public QObject {
    Q_OBJECT

   private slots:
    void testQtToFcitxRoundTrip_data();
    void testQtToFcitxRoundTrip();
    void testEmptyInput();
    void testSingleKeyNoModifier();
    void testRoundTripPreserves();
};

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
}

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

void KeySequenceUtilTest::testEmptyInput() {
    QCOMPARE(fcitxKeyStringFromQKeySequence(QKeySequence()), QString());
    QCOMPARE(qKeySequenceFromFcitxKeyString(QString()), QKeySequence());
}

void KeySequenceUtilTest::testSingleKeyNoModifier() {
    QCOMPARE(fcitxKeyStringFromQKeySequence(
                 QKeySequence::fromString(QLatin1String("L"),
                                          QKeySequence::PortableText)),
             QLatin1String("L"));
    QCOMPARE(qKeySequenceFromFcitxKeyString(QLatin1String("L"))
                 .toString(QKeySequence::PortableText),
             QLatin1String("L"));
}

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

/**
 * @file keypad_input_ui_test.cpp
 * @brief テンキー入力設定のenum値と2つのウィジェットの対応を検証するテスト
 * @note mainwindow.uiから生成したUIを使い、実際のウィジェット名と初期状態も検証する
 */
#include <QCheckBox>
#include <QComboBox>
#include <QLabel>
#include <QWidget>
#include <QtTest/QtTest>

#include "config_definitions.h"
#include "ui_mainwindow.h"

namespace {

/** @brief テストで使うprotobuf列挙型の別名 */
using Mode = hazkey::config::Profile_KeypadInputMode;

/** @brief 素通りを表すprotobuf列挙値 */
constexpr Mode kPassthrough =
    hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_PASSTHROUGH;
/** @brief 半角を表すprotobuf列挙値 */
constexpr Mode kHalfwidth =
    hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_HALFWIDTH;
/** @brief 全角を表すprotobuf列挙値 */
constexpr Mode kFullwidth =
    hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_FULLWIDTH;
/** @brief 未設定を表すprotobuf列挙値 */
constexpr Mode kUnspecified =
    hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_MODE_UNSPECIFIED;

}  // namespace

/**
 * @class KeypadInputUiTest
 * @brief ConfigDefs::KeypadInputModeと[ユーザインターフェース]タブのテンキー設定を検証する
 */
class KeypadInputUiTest : public QObject {
    Q_OBJECT

   private slots:
    /** @brief 往復テストの入力となる3つの有効なenum値を用意する */
    void roundTripThroughWidgets_data();
    /** @brief enum値を2つのウィジェットへ設定し、読み戻すと同じ値になることを検証する */
    void roundTripThroughWidgets();
    /** @brief 未設定・UNSPECIFIED・未知の値が素通りとして表示されることを検証する */
    void fallbackValuesLoadAsPassthrough_data();
    /** @brief 未設定・UNSPECIFIED・未知の値が素通りとして表示されることを検証する */
    void fallbackValuesLoadAsPassthrough();
    /** @brief 素通りがONなら、コンボボックスの選択に依らず実効値が素通りになることを検証する */
    void passthroughIgnoresWidthIndex();
    /** @brief 素通りがOFFなら、コンボボックスの選択から半角・全角を求めることを検証する */
    void widthIndexSelectsHalfOrFullWidth();
    /** @brief 純関数isPassthrough()とwidthIndexFromEnum()の対応表を検証する */
    void pureFunctionsTable();
    /** @brief mainwindow.uiのテンキー設定のウィジェット名・既定状態・項目を検証する */
    void mainWindowUiHasKeypadWidgets();
};

void KeypadInputUiTest::roundTripThroughWidgets_data() {
    QTest::addColumn<int>("mode");
    QTest::addColumn<bool>("expectedChecked");
    QTest::addColumn<int>("expectedIndex");
    QTest::newRow("passthrough") << static_cast<int>(kPassthrough) << true
                                 << ConfigDefs::KeypadInputMode::HALFWIDTH_INDEX;
    QTest::newRow("halfwidth") << static_cast<int>(kHalfwidth) << false
                               << ConfigDefs::KeypadInputMode::HALFWIDTH_INDEX;
    QTest::newRow("fullwidth") << static_cast<int>(kFullwidth) << false
                               << ConfigDefs::KeypadInputMode::FULLWIDTH_INDEX;
}

void KeypadInputUiTest::roundTripThroughWidgets() {
    QFETCH(int, mode);
    QFETCH(bool, expectedChecked);
    QFETCH(int, expectedIndex);

    QCheckBox passthrough;
    QComboBox width;
    width.addItems({QStringLiteral("Half-width"), QStringLiteral("Full-width")});
    // 前の状態が残っても結果が変わらないことを確かめるため、逆の状態から始める
    passthrough.setChecked(!expectedChecked);
    width.setCurrentIndex(1 - expectedIndex);

    ConfigDefs::KeypadInputMode::setToUi(&passthrough, &width, mode);
    QCOMPARE(passthrough.isChecked(), expectedChecked);
    QCOMPARE(width.currentIndex(), expectedIndex);
    QCOMPARE(static_cast<int>(
                 ConfigDefs::KeypadInputMode::getFromUi(&passthrough, &width)),
             mode);
}

void KeypadInputUiTest::fallbackValuesLoadAsPassthrough_data() {
    QTest::addColumn<int>("mode");
    QTest::newRow("unspecified") << static_cast<int>(kUnspecified);
    QTest::newRow("unknown positive") << 99;
    QTest::newRow("unknown negative") << -1;
}

void KeypadInputUiTest::fallbackValuesLoadAsPassthrough() {
    QFETCH(int, mode);

    QCheckBox passthrough;
    QComboBox width;
    width.addItems({QStringLiteral("Half-width"), QStringLiteral("Full-width")});
    passthrough.setChecked(false);
    width.setCurrentIndex(ConfigDefs::KeypadInputMode::FULLWIDTH_INDEX);

    ConfigDefs::KeypadInputMode::setToUi(&passthrough, &width, mode);
    QVERIFY(passthrough.isChecked());
    QCOMPARE(width.currentIndex(),
             ConfigDefs::KeypadInputMode::DEFAULT_WIDTH_INDEX);
    QCOMPARE(ConfigDefs::KeypadInputMode::getFromUi(&passthrough, &width),
             kPassthrough);
    QCOMPARE(ConfigDefs::KeypadInputMode::DEFAULT_ENUM, kPassthrough);
}

void KeypadInputUiTest::passthroughIgnoresWidthIndex() {
    for (int index : {-1, 0, 1, 2}) {
        QCOMPARE(ConfigDefs::KeypadInputMode::fromUi(true, index), kPassthrough);
    }

    // 素通り中にコンボボックスを変えても実効値 (未保存判定のキー) は変わらない
    QCheckBox passthrough;
    QComboBox width;
    width.addItems({QStringLiteral("Half-width"), QStringLiteral("Full-width")});
    passthrough.setChecked(true);
    width.setCurrentIndex(0);
    const Mode before =
        ConfigDefs::KeypadInputMode::getFromUi(&passthrough, &width);
    width.setCurrentIndex(1);
    QCOMPARE(ConfigDefs::KeypadInputMode::getFromUi(&passthrough, &width),
             before);
}

void KeypadInputUiTest::widthIndexSelectsHalfOrFullWidth() {
    QCOMPARE(ConfigDefs::KeypadInputMode::fromUi(false, 0), kHalfwidth);
    QCOMPARE(ConfigDefs::KeypadInputMode::fromUi(false, 1), kFullwidth);
    // 未対応のインデックスは半角として扱う
    QCOMPARE(ConfigDefs::KeypadInputMode::fromUi(false, -1), kHalfwidth);
    QCOMPARE(ConfigDefs::KeypadInputMode::fromUi(false, 2), kHalfwidth);
}

void KeypadInputUiTest::pureFunctionsTable() {
    QVERIFY(ConfigDefs::KeypadInputMode::isPassthrough(kPassthrough));
    QVERIFY(ConfigDefs::KeypadInputMode::isPassthrough(kUnspecified));
    QVERIFY(ConfigDefs::KeypadInputMode::isPassthrough(99));
    QVERIFY(!ConfigDefs::KeypadInputMode::isPassthrough(kHalfwidth));
    QVERIFY(!ConfigDefs::KeypadInputMode::isPassthrough(kFullwidth));

    QCOMPARE(ConfigDefs::KeypadInputMode::widthIndexFromEnum(kPassthrough), 0);
    QCOMPARE(ConfigDefs::KeypadInputMode::widthIndexFromEnum(kUnspecified), 0);
    QCOMPARE(ConfigDefs::KeypadInputMode::widthIndexFromEnum(kHalfwidth), 0);
    QCOMPARE(ConfigDefs::KeypadInputMode::widthIndexFromEnum(kFullwidth), 1);
    QCOMPARE(ConfigDefs::KeypadInputMode::widthIndexFromEnum(99), 0);
}

void KeypadInputUiTest::mainWindowUiHasKeypadWidgets() {
    QWidget host;
    Ui::MainWindow ui;
    ui.setupUi(&host);

    QVERIFY(ui.keypadPassthrough != nullptr);
    QVERIFY(ui.keypadWidth != nullptr);
    QVERIFY(ui.keypadPassthroughLabel != nullptr);
    QVERIFY(ui.keypadWidthLabel != nullptr);
    QVERIFY(ui.keypadLabel != nullptr);

    // [ユーザインターフェース]タブに置かれている
    QVERIFY(ui.userInterfaceTab->isAncestorOf(ui.keypadPassthrough));
    QVERIFY(ui.userInterfaceTab->isAncestorOf(ui.keypadWidth));

    // 既定は素通りで、項目は半角・全角の順
    QVERIFY(ui.keypadPassthrough->isChecked());
    QCOMPARE(ui.keypadWidth->count(), 2);
    QCOMPARE(ui.keypadWidth->itemText(ConfigDefs::KeypadInputMode::HALFWIDTH_INDEX),
             QStringLiteral("Half-width"));
    QCOMPARE(ui.keypadWidth->itemText(ConfigDefs::KeypadInputMode::FULLWIDTH_INDEX),
             QStringLiteral("Full-width"));
    QVERIFY(!ui.keypadPassthrough->toolTip().isEmpty());
    QVERIFY(!ui.keypadWidth->toolTip().isEmpty());

    // 生成UIの既定状態をenum値へ変換すると素通りになる
    QCOMPARE(ConfigDefs::KeypadInputMode::getFromUi(ui.keypadPassthrough,
                                                    ui.keypadWidth),
             kPassthrough);
}

QTEST_MAIN(KeypadInputUiTest)
#include "keypad_input_ui_test.moc"

/**
 * @file basic_input_style_test.cpp
 * @brief basic_input_styleの純ロジックテスト (MainWindow / ソケット非依存)
 */
#include <QtTest/QtTest>

#include "basic_input_style.h"

using namespace BasicInputStyleKeymaps;
using namespace BasicInputStyleTables;

/**
 * @brief テスト用のファイル内ヘルパー
 */
namespace {

/**
 * @brief テスト用の完全な利用可能一覧 (レガシー + 新分割 + テーブル) を作る
 * @return 利用可能キーマップのエントリ列
 */
QVector<BasicAvailableEntry> fullAvailableKeymaps()
{
    const QStringList names = {
        fullwidthPeriod, fullwidthComma, fullwidthNumber, fullwidthSpace,
        japaneseSymbol, legacyFullwidthSymbol,
        fullwidthBasicSymbol, fullwidthQuotation, typographicQuotation,
        japaneseBracket, fullwidthBracket, halfwidthBracket, jisKana};
    QVector<BasicAvailableEntry> entries;
    for (const QString& name : names) {
        entries.append({name, true, QStringLiteral("builtin/") + name + QStringLiteral(".keymap")});
    }
    return entries;
}

/**
 * @brief テスト用の完全な入力テーブル一覧を作る
 * @return 利用可能入力テーブルのエントリ列
 */
QVector<BasicAvailableEntry> fullAvailableTables()
{
    return {{romaji, true, QStringLiteral("builtin/Romaji.table")},
            {kana, true, QStringLiteral("builtin/Kana.table")}};
}

/**
 * @brief 名前だけの有効キーマップ一覧を作る (投影テスト用)
 * @param names エントリ化する名前の一覧
 * @return 名前と組込フラグだけを持つエントリ列
 */
QVector<BasicProfileEntry> keymapEntries(const QStringList& names)
{
    QVector<BasicProfileEntry> entries;
    for (const QString& name : names) {
        entries.append({name, true, QString()});
    }
    return entries;
}

/**
 * @brief 名前だけの有効入力テーブル一覧を作る (投影テスト用)
 * @param names エントリ化する名前の一覧
 * @return 名前と組込フラグだけを持つエントリ列
 */
QVector<BasicProfileEntry> tableEntries(const QStringList& names)
{
    QVector<BasicProfileEntry> entries;
    for (const QString& name : names) {
        entries.append({name, true, QString()});
    }
    return entries;
}

/**
 * @brief ローマ字モードのサブモード入口文字
 */
const QString kRomajiSubmode = QStringLiteral("ABCDEFGHIJKLMNOPQRSTUVWXYZ");

} // namespace

/**
 * @brief buildBasicInputStylePlan / projectBasicInputStyle の純ロジックテスト
 *
 * MainWindowやソケットに依存せず、計画生成と逆投影だけを検証する
 */
class BasicInputStyleTest : public QObject {
    Q_OBJECT

private slots:
    void planDefaultSelectionUsesNewSplitMaps();
    void planOrderExhaustiveOverAllCombinations();
    void planRespectsPriorityOrder();
    void planMissingKeymapFailsAllOrNothing();
    void planMissingTableFailsAllOrNothing();
    void planRejectsNonBuiltinAvailability();
    void planKanaModeMinimalMaps();
    void projectionRoundTripExhaustive();
    void projectionLegacyFullwidthSymbolCompatible();
    void projectionLegacyServerDefaultOrderCompatible();
    void projectionLegacySymbollessDisplayOnly();
    void projectionLegacyMixedWithSplitIncompatible();
    void projectionOrderViolationsIncompatible();
    void projectionCustomAndUnknownEntriesIncompatible();
    void projectionKanaMode();
};

/** @brief 既定選択が新分割マップを使い旧サーバ既定と整合することを検査する */
void BasicInputStyleTest::planDefaultSelectionUsesNewSplitMaps()
{
    const BasicInputStylePlan plan = buildBasicInputStylePlan(BasicInputStyleSelection{},
                                                              fullAvailableKeymaps(),
                                                              fullAvailableTables());
    QVERIFY(plan.ok);
    // 既定は全角数字 / 全角記号 / 全角引用符 / 和字括弧 / 全角スペース + 和字記号
    QVERIFY(plan.keymaps.size() == 6);
    QCOMPARE(plan.keymaps[0].name, fullwidthNumber);
    QCOMPARE(plan.keymaps[1].name, fullwidthBasicSymbol);
    QCOMPARE(plan.keymaps[2].name, fullwidthQuotation);
    QCOMPARE(plan.keymaps[3].name, japaneseBracket);
    QCOMPARE(plan.keymaps[4].name, fullwidthSpace);
    QCOMPARE(plan.keymaps[5].name, japaneseSymbol);
    QVERIFY(plan.tables.size() == 1);
    QCOMPARE(plan.tables[0].name, romaji);
    QCOMPARE(plan.submodeEntryPointChars, kRomajiSubmode);
}

/** @brief 句読点4 × 数字2 × 記号2 × 引用符3 × 括弧3 × 空白2 = 288通りの計画を検査する */
void BasicInputStyleTest::planOrderExhaustiveOverAllCombinations()
{
    for (int punctuation = 0; punctuation < 4; ++punctuation) {
        for (int number = 0; number < 2; ++number) {
            for (int symbol = 0; symbol < 2; ++symbol) {
                for (int quotation = 0; quotation < 3; ++quotation) {
                    for (int bracket = 0; bracket < 3; ++bracket) {
                        for (int space = 0; space < 2; ++space) {
                            BasicInputStyleSelection s;
                            s.punctuationStyle = punctuation;
                            s.numberStyle = number;
                            s.symbolStyle = symbol;
                            s.quotationStyle = quotation;
                            s.bracketStyle = bracket;
                            s.spaceStyle = space;

                            const QString context = QStringLiteral("p%1n%2s%3q%4b%5sp%6")
                                                        .arg(punctuation)
                                                        .arg(number)
                                                        .arg(symbol)
                                                        .arg(quotation)
                                                        .arg(bracket)
                                                        .arg(space);
                            const BasicInputStylePlan plan = buildBasicInputStylePlan(s, fullAvailableKeymaps(), fullAvailableTables());
                            QVERIFY2(plan.ok, qPrintable(context));

                            QStringList names;
                            for (const BasicProfileEntry& e : plan.keymaps) {
                                names << e.name;
                            }

                            // 和字記号は常に最後
                            QCOMPARE(names.last(), japaneseSymbol);

                            // 句読点マップは和字記号より前 (先頭側)
                            const int japaneseIndex = names.indexOf(japaneseSymbol);
                            for (const QString& punctuationMap : {fullwidthPeriod, fullwidthComma}) {
                                if (names.contains(punctuationMap)) {
                                    QVERIFY(names.indexOf(punctuationMap) < japaneseIndex);
                                }
                            }

                            // 括弧マップは必ずちょうど1つ、かつ和字記号より前
                            int bracketCount = 0;
                            for (const QString& b : {japaneseBracket, fullwidthBracket, halfwidthBracket}) {
                                bracketCount += names.contains(b) ? 1 : 0;
                            }
                            QCOMPARE(bracketCount, 1);

                            // 半角括弧は角括弧を恒等上書きするため和字記号より前でなければならない
                            if (bracket == 2) {
                                QVERIFY(names.indexOf(halfwidthBracket) < japaneseIndex);
                            }

                            // 引用符マップの対応
                            if (quotation == 0) {
                                QVERIFY(names.contains(fullwidthQuotation));
                            }
                            else if (quotation == 1) {
                                QVERIFY(names.contains(typographicQuotation));
                            }
                            else {
                                QVERIFY(!names.contains(fullwidthQuotation) && !names.contains(typographicQuotation));
                            }

                            // 記号・数字・空白の対応
                            QCOMPARE(names.contains(fullwidthBasicSymbol), symbol == 0);
                            QCOMPARE(names.contains(fullwidthNumber), number == 0);
                            QCOMPARE(names.contains(fullwidthSpace), space == 0);

                            // 旧Fullwidth Symbolは新計画に現れない
                            QVERIFY(!names.contains(legacyFullwidthSymbol));

                            // サーバ報告のファイル名がそのまま引き継がれる
                            for (const BasicProfileEntry& e : plan.keymaps) {
                                QCOMPARE(e.filename, QStringLiteral("builtin/") + e.name + QStringLiteral(".keymap"));
                                QVERIFY(e.isBuiltin);
                            }
                        }
                    }
                }
            }
        }
    }
}

/** @brief 優先順序 (句読点 → 数字 → 全角基本記号 → 引用符 → 括弧 → 空白 → 和字記号) を検査する */
void BasicInputStyleTest::planRespectsPriorityOrder()
{
    BasicInputStyleSelection s;
    s.punctuationStyle = 1; // Period+Comma
    s.numberStyle = 0;      // 全角
    s.symbolStyle = 0;      // 全角
    s.quotationStyle = 1;   // 組版
    s.bracketStyle = 2;     // 半角括弧
    s.spaceStyle = 0;       // 全角

    const BasicInputStylePlan plan = buildBasicInputStylePlan(s, fullAvailableKeymaps(), fullAvailableTables());
    QVERIFY(plan.ok);

    QStringList names;
    for (const BasicProfileEntry& e : plan.keymaps) {
        names << e.name;
    }
    const QStringList expected = {fullwidthPeriod, fullwidthComma, fullwidthNumber,
                                 fullwidthBasicSymbol, typographicQuotation, halfwidthBracket,
                                 fullwidthSpace, japaneseSymbol};
    QCOMPARE(names, expected);
}

/** @brief 必須キーマップの欠落が部分計画なしのall-or-nothingになることを検査する */
void BasicInputStyleTest::planMissingKeymapFailsAllOrNothing()
{
    QVector<BasicAvailableEntry> available = fullAvailableKeymaps();
    // Typographic Quotationを利用可能一覧から除く
    QVector<BasicAvailableEntry> reduced;
    for (const BasicAvailableEntry& e : available) {
        if (e.name != typographicQuotation) {
            reduced.append(e);
        }
    }

    BasicInputStyleSelection s;
    s.quotationStyle = 1;
    const BasicInputStylePlan plan = buildBasicInputStylePlan(s, reduced, fullAvailableTables());
    QVERIFY(!plan.ok);
    QVERIFY(plan.keymaps.isEmpty()); // 既存プロファイルを消しかねない部分計画を返さない
    QVERIFY(plan.missingKeymaps.contains(typographicQuotation));

    // 半角引用符なら欠落マップ不要なので成功する
    s.quotationStyle = 2;
    QVERIFY(buildBasicInputStylePlan(s, reduced, fullAvailableTables()).ok);

    // 半角括弧の欠落も同様に拒否
    QVector<BasicAvailableEntry> reduced2;
    for (const BasicAvailableEntry& e : available) {
        if (e.name != halfwidthBracket) {
            reduced2.append(e);
        }
    }
    BasicInputStyleSelection s2;
    s2.bracketStyle = 2;
    QVERIFY(!buildBasicInputStylePlan(s2, reduced2, fullAvailableTables()).ok);
    s2.bracketStyle = 0;
    QVERIFY(buildBasicInputStylePlan(s2, reduced2, fullAvailableTables()).ok);
}

/** @brief 入力テーブルの欠落もall-or-nothingになることを検査する */
void BasicInputStyleTest::planMissingTableFailsAllOrNothing()
{
    const QVector<BasicAvailableEntry> noTables;
    const BasicInputStylePlan plan = buildBasicInputStylePlan(BasicInputStyleSelection{}, fullAvailableKeymaps(), noTables);
    QVERIFY(!plan.ok);
    QVERIFY(plan.tables.isEmpty());
    QVERIFY(plan.keymaps.isEmpty());
    QVERIFY(plan.missingTables.contains(romaji));
}

/** @brief 非組込として報告された同名エントリを利用可能と見なさないことを検査する */
void BasicInputStyleTest::planRejectsNonBuiltinAvailability()
{
    QVector<BasicAvailableEntry> available = fullAvailableKeymaps();
    for (BasicAvailableEntry& e : available) {
        if (e.name == japaneseBracket) {
            e.isBuiltin = false;
        }
    }
    const BasicInputStylePlan plan = buildBasicInputStylePlan(BasicInputStyleSelection{}, available, fullAvailableTables());
    QVERIFY(!plan.ok);
    QVERIFY(plan.missingKeymaps.contains(japaneseBracket));
}

/** @brief かなモードが[JIS Kana]と任意の[Fullwidth Space]のみを生成することを検査する */
void BasicInputStyleTest::planKanaModeMinimalMaps()
{
    BasicInputStyleSelection s;
    s.mainInputStyle = 1;
    s.quotationStyle = 1; // 無効な選択値でもマップを増やさない
    s.bracketStyle = 2;
    s.spaceStyle = 1; // 半角スペースならJISかなのみ

    const BasicInputStylePlan halfSpace = buildBasicInputStylePlan(s, fullAvailableKeymaps(), fullAvailableTables());
    QVERIFY(halfSpace.ok);
    QStringList names;
    for (const BasicProfileEntry& e : halfSpace.keymaps) {
        names << e.name;
    }
    QCOMPARE(names, QStringList{jisKana});
    QVERIFY(halfSpace.tables.size() == 1);
    QCOMPARE(halfSpace.tables[0].name, kana);
    QVERIFY(halfSpace.submodeEntryPointChars.isEmpty());

    s.spaceStyle = 0;
    const BasicInputStylePlan fullSpace = buildBasicInputStylePlan(s, fullAvailableKeymaps(), fullAvailableTables());
    QVERIFY(fullSpace.ok);
    names.clear();
    for (const BasicProfileEntry& e : fullSpace.keymaps) {
        names << e.name;
    }
    QCOMPARE(names, (QStringList{fullwidthSpace, jisKana}));
}

/** @brief 全288組合せの計画 → 投影の往復が同一選択値を返すことを検査する */
void BasicInputStyleTest::projectionRoundTripExhaustive()
{
    for (int punctuation = 0; punctuation < 4; ++punctuation) {
        for (int number = 0; number < 2; ++number) {
            for (int symbol = 0; symbol < 2; ++symbol) {
                for (int quotation = 0; quotation < 3; ++quotation) {
                    for (int bracket = 0; bracket < 3; ++bracket) {
                        for (int space = 0; space < 2; ++space) {
                            BasicInputStyleSelection s;
                            s.punctuationStyle = punctuation;
                            s.numberStyle = number;
                            s.symbolStyle = symbol;
                            s.quotationStyle = quotation;
                            s.bracketStyle = bracket;
                            s.spaceStyle = space;

                            const BasicInputStylePlan plan = buildBasicInputStylePlan(s, fullAvailableKeymaps(), fullAvailableTables());
                            QVERIFY(plan.ok);

                            const BasicInputStyleProjection projection =
                                projectBasicInputStyle(plan.submodeEntryPointChars, plan.keymaps, plan.tables);
                            QVERIFY2(projection.compatible, "roundtrip projection must stay compatible");
                            QVERIFY(!projection.legacyDisplayOnly);
                            QCOMPARE(projection.selection, s);
                        }
                    }
                }
            }
        }
    }
}

/** @brief レガシー[Fullwidth Symbol]構成が互換投影されることを検査する */
void BasicInputStyleTest::projectionLegacyFullwidthSymbolCompatible()
{
    const BasicInputStyleProjection simple = projectBasicInputStyle(
        kRomajiSubmode, keymapEntries({legacyFullwidthSymbol, japaneseSymbol}), tableEntries({romaji}));
    QVERIFY(simple.compatible);
    QVERIFY(!simple.legacyDisplayOnly);
    QCOMPARE(simple.selection.symbolStyle, 0);
    QCOMPARE(simple.selection.quotationStyle, 0);
    QCOMPARE(simple.selection.bracketStyle, 0);
    QCOMPARE(simple.selection.numberStyle, 1);
    QCOMPARE(simple.selection.spaceStyle, 1);

    // 句読点・数字・空白を併用したフルのレガシー構成
    const BasicInputStyleProjection full = projectBasicInputStyle(
        kRomajiSubmode,
        keymapEntries({fullwidthPeriod, fullwidthComma, fullwidthNumber, legacyFullwidthSymbol, fullwidthSpace, japaneseSymbol}),
        tableEntries({romaji}));
    QVERIFY(full.compatible);
    QCOMPARE(full.selection.punctuationStyle, 1);
    QCOMPARE(full.selection.numberStyle, 0);
    QCOMPARE(full.selection.symbolStyle, 0);
    QCOMPARE(full.selection.spaceStyle, 0);
}

/** @brief 旧サーバ既定順 ([Fullwidth Space]と[Japanese Symbol]の入れ替わり) を書き換えずに互換投影することを検査する */
void BasicInputStyleTest::projectionLegacyServerDefaultOrderCompatible()
{
    // 旧 HazkeyServerConfig.genDefaultConfig(): Number → Fullwidth Symbol → Japanese Symbol → Space
    const BasicInputStyleProjection oldDefault = projectBasicInputStyle(
        kRomajiSubmode,
        keymapEntries({fullwidthNumber, legacyFullwidthSymbol, japaneseSymbol, fullwidthSpace}),
        tableEntries({romaji}));
    QVERIFY(oldDefault.compatible);
    QVERIFY(!oldDefault.legacyDisplayOnly);
    QCOMPARE(oldDefault.selection.mainInputStyle, 0);
    QCOMPARE(oldDefault.selection.punctuationStyle, 0);
    QCOMPARE(oldDefault.selection.numberStyle, 0);
    QCOMPARE(oldDefault.selection.symbolStyle, 0);
    QCOMPARE(oldDefault.selection.quotationStyle, 0);
    QCOMPARE(oldDefault.selection.bracketStyle, 0);
    QCOMPARE(oldDefault.selection.spaceStyle, 0);

    // 現行の書き込み順 (Space → Japanese Symbol) も従来どおり互換で同一選択値
    const BasicInputStyleProjection writerOrder = projectBasicInputStyle(
        kRomajiSubmode,
        keymapEntries({fullwidthNumber, legacyFullwidthSymbol, fullwidthSpace, japaneseSymbol}),
        tableEntries({romaji}));
    QVERIFY(writerOrder.compatible);
    QVERIFY(!writerOrder.legacyDisplayOnly);
    QCOMPARE(writerOrder.selection, oldDefault.selection);

    // 和字記号のみ + 全角スペースの旧順入れ替わりも表示専用として認める
    const BasicInputStyleProjection displayOnlySwapped = projectBasicInputStyle(
        kRomajiSubmode,
        keymapEntries({japaneseSymbol, fullwidthSpace}),
        tableEntries({romaji}));
    QVERIFY(displayOnlySwapped.compatible);
    QVERIFY(displayOnlySwapped.legacyDisplayOnly);
    QCOMPARE(displayOnlySwapped.selection.spaceStyle, 0);

    // 許容は対象キーが重ならない末尾2マップのみ、上書き関係の順序違反は非互換のまま
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({fullwidthNumber, japaneseSymbol, legacyFullwidthSymbol, fullwidthSpace}),
                                    tableEntries({romaji}))
                   .compatible);
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({fullwidthNumber, legacyFullwidthSymbol, japaneseSymbol, fullwidthSpace, fullwidthComma}),
                                    tableEntries({romaji}))
                   .compatible);
    // 新形式は正準順序の完全一致を要求 (入れ替わりを認めない)
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({fullwidthNumber, fullwidthBasicSymbol, japaneseBracket, japaneseSymbol, fullwidthSpace}),
                                    tableEntries({romaji}))
                   .compatible);
}

/** @brief レガシーの[Japanese Symbol]のみ構成が表示専用投影になることを検査する */
void BasicInputStyleTest::projectionLegacySymbollessDisplayOnly()
{
    const BasicInputStyleProjection bare = projectBasicInputStyle(
        kRomajiSubmode, keymapEntries({japaneseSymbol}), tableEntries({romaji}));
    QVERIFY(bare.compatible);
    QVERIFY(bare.legacyDisplayOnly);
    QCOMPARE(bare.selection.symbolStyle, 1);
    QCOMPARE(bare.selection.quotationStyle, 2);
    QCOMPARE(bare.selection.bracketStyle, 0);

    // 句読点マップ併用も表示専用で投影できる
    const BasicInputStyleProjection withComma = projectBasicInputStyle(
        kRomajiSubmode, keymapEntries({fullwidthComma, japaneseSymbol}), tableEntries({romaji}));
    QVERIFY(withComma.compatible);
    QVERIFY(withComma.legacyDisplayOnly);
    QCOMPARE(withComma.selection.punctuationStyle, 2);
}

/** @brief レガシー[Fullwidth Symbol]と新分割マップの混在が非互換になることを検査する */
void BasicInputStyleTest::projectionLegacyMixedWithSplitIncompatible()
{
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({legacyFullwidthSymbol, japaneseBracket, japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({legacyFullwidthSymbol, fullwidthBasicSymbol, japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
    // 新形式で括弧マップが0つ / 2つも非互換
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({fullwidthBasicSymbol, japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({japaneseBracket, halfwidthBracket, japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
}

/** @brief 順序違反・重複・欠落が非互換になることを検査する */
void BasicInputStyleTest::projectionOrderViolationsIncompatible()
{
    // 和字記号が先頭 (句読点より前) は旧isBasicModeCompatibleと同じく非互換
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({japaneseSymbol, legacyFullwidthSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
    // 半角括弧が和字記号より後では恒等上書きできない
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({japaneseSymbol, halfwidthBracket}),
                                    tableEntries({romaji}))
                   .compatible);
    // 和字記号の欠落
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({japaneseBracket}),
                                    tableEntries({romaji}))
                   .compatible);
    // 重複
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({japaneseSymbol, japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
}

/** @brief カスタム / 未知エントリやテーブル異常が非互換になることを検査する */
void BasicInputStyleTest::projectionCustomAndUnknownEntriesIncompatible()
{
    QVector<BasicProfileEntry> withCustom = keymapEntries({japaneseSymbol});
    withCustom.append({QStringLiteral("My Keymap"), false, QStringLiteral("my.keymap")});
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode, withCustom, tableEntries({romaji})).compatible);

    QVector<BasicProfileEntry> customTable = tableEntries({romaji});
    customTable[0].isBuiltin = false;
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode, keymapEntries({japaneseSymbol}), customTable).compatible);

    // 未知のマップ名
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({QStringLiteral("Fancy Symbol"), japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
    // テーブルが2つ / サブモード入口不一致
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode,
                                    keymapEntries({japaneseSymbol}),
                                    tableEntries({romaji, kana}))
                   .compatible);
    QVERIFY(!projectBasicInputStyle(QStringLiteral("ABC"),
                                    keymapEntries({japaneseSymbol}),
                                    tableEntries({romaji}))
                   .compatible);
    // 空のプロファイル
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode, {}, tableEntries({romaji})).compatible);
}

/** @brief かなモードの投影が[Fullwidth Space]→[JIS Kana]の順のみを許すことを検査する */
void BasicInputStyleTest::projectionKanaMode()
{
    const BasicInputStyleProjection bare = projectBasicInputStyle(QString(), keymapEntries({jisKana}), tableEntries({kana}));
    QVERIFY(bare.compatible);
    QCOMPARE(bare.selection.mainInputStyle, 1);
    QCOMPARE(bare.selection.spaceStyle, 1);

    const BasicInputStyleProjection withSpace = projectBasicInputStyle(QString(), keymapEntries({fullwidthSpace, jisKana}), tableEntries({kana}));
    QVERIFY(withSpace.compatible);
    QCOMPARE(withSpace.selection.spaceStyle, 0);

    // 順序逆転 / 引用符・括弧マップの混在 / JISかな欠落は非互換
    QVERIFY(!projectBasicInputStyle(QString(), keymapEntries({jisKana, fullwidthSpace}), tableEntries({kana})).compatible);
    QVERIFY(!projectBasicInputStyle(QString(), keymapEntries({japaneseBracket, jisKana}), tableEntries({kana})).compatible);
    QVERIFY(!projectBasicInputStyle(QString(), keymapEntries({fullwidthSpace}), tableEntries({kana})).compatible);
    // かなモードでローマ字サブモード入口は非互換
    QVERIFY(!projectBasicInputStyle(kRomajiSubmode, keymapEntries({jisKana}), tableEntries({kana})).compatible);
}

QTEST_MAIN(BasicInputStyleTest)
#include "basic_input_style_test.moc"

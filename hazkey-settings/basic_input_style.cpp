/**
 * @file basic_input_style.cpp
 * @brief Basic入力方式タブの純ロジック実装 (basic_input_style.h参照)
 */
#include "basic_input_style.h"
#include <QSet>

/**
 * @brief ファイル内ヘルパー
 *
 * 正準キーマップ順の組み立てと、利用可能一覧からのエントリ解決を担う
 */
namespace {

using namespace BasicInputStyleKeymaps;
using namespace BasicInputStyleTables;

/**
 * @brief ローマ字モードの正準キーマップ順 (新形式) を組み立てる
 *
 * 並びは、句読点 → 数字 → 全角基本記号 → 引用符 → 括弧 → 空白 → 和字記号とする
 * 一覧の先頭ほど優先度が高いため、句読点と括弧は和字記号より前でなければならない
 *
 * @param selection Basicタブの選択値
 * @return 正準順のキーマップ名一覧
 */
QStringList romajiCanonicalOrder(const BasicInputStyleSelection& selection)
{
    QStringList order;

    switch (selection.punctuationStyle) {
        case 1: // Period + Comma: ．，
            order << fullwidthPeriod << fullwidthComma;
            break;
        case 2: // 句点 + カンマ: 和文句点と半角カンマ
            order << fullwidthComma;
            break;
        case 3: // ピリオド + 読点: ．、
            order << fullwidthPeriod;
            break;
        default: // 句点 + 読点: 和文句点と読点は追加マップ不要
            break;
    }

    if (selection.numberStyle == 0) { // 全角数字
        order << fullwidthNumber;
    }

    if (selection.symbolStyle == 0) { // 全角記号 (括弧・引用符を除く基本記号)
        order << fullwidthBasicSymbol;
    }

    if (selection.quotationStyle == 0) { // 全角引用符 ＂＇｀
        order << fullwidthQuotation;
    }
    else if (selection.quotationStyle == 1) { // 組版引用符 ”’‘
        order << typographicQuotation;
    }
    // 2: 半角はマップ不要

    // 括弧は必ずちょうど1つ
    switch (selection.bracketStyle) {
        case 1: // 全角括弧 （）［］｛｝
            order << fullwidthBracket;
            break;
        case 2: // 半角括弧 ()[]{}: 和字記号より前で角括弧を恒等上書きする
            order << halfwidthBracket;
            break;
        default: // 和字括弧 （）「」｛｝
            order << japaneseBracket;
            break;
    }

    if (selection.spaceStyle == 0) { // 全角スペース
        order << fullwidthSpace;
    }

    // 和字記号は常に最後 (上のすべてのマップが優先して上書きする)
    order << japaneseSymbol;
    return order;
}

/**
 * @brief ローマ字モードの正準キーマップ順 (レガシー形式) を組み立てる
 *
 * symbolStyle==0の時、旧[Fullwidth Symbol]を含む
 *
 * @param selection Basicタブの選択値
 * @return レガシー正準順のキーマップ名一覧
 */
QStringList legacyCanonicalOrder(const BasicInputStyleSelection& selection)
{
    QStringList order;

    switch (selection.punctuationStyle) {
        case 1:
            order << fullwidthPeriod << fullwidthComma;
            break;
        case 2:
            order << fullwidthComma;
            break;
        case 3:
            order << fullwidthPeriod;
            break;
        default:
            break;
    }

    if (selection.numberStyle == 0) {
        order << fullwidthNumber;
    }

    if (selection.symbolStyle == 0) {
        order << legacyFullwidthSymbol;
    }

    if (selection.spaceStyle == 0) {
        order << fullwidthSpace;
    }

    order << japaneseSymbol;
    return order;
}

/**
 * @brief レガシー構成の許容順序かどうかを判定する
 *
 * 正準順 (末尾が[Fullwidth Space] → [Japanese Symbol]) に加え、末尾の[Fullwidth Space]と
 * [Japanese Symbol]を入れ替えた旧サーバ既定順
 * ([Fullwidth Number]→[Fullwidth Symbol]→[Japanese Symbol]→[Fullwidth Space]) も認める
 *
 * 両マップは対象キーが重ならず互いに上書きしないため、入れ替えても挙動は同一
 * 句読点・括弧など和字記号を上書きする側のマップが後ろへ回る順序違反は引き続き非互換
 * (末尾のこの2件以外の入れ替えは許さない)
 *
 * 一覧自体は書き換えない
 *
 * @param actual プロファイルの実際のキーマップ名一覧
 * @param expected 正準順のキーマップ名一覧
 * @return 許容順序に一致する場合はtrue
 */
bool legacyOrderMatches(const QStringList& actual, const QStringList& expected)
{
    if (actual == expected) {
        return true;
    }
    if (actual.size() != expected.size() || expected.size() < 2) {
        return false;
    }
    if (expected.at(expected.size() - 2) == fullwidthSpace && expected.last() == japaneseSymbol) {
        QStringList swapped = expected;
        swapped.swapItemsAt(swapped.size() - 2, swapped.size() - 1);
        return actual == swapped;
    }
    return false;
}

/**
 * @brief かなモードの正準キーマップ順を組み立てる
 *
 * [Fullwidth Space] → [JIS Kana]の順であり既存挙動と同一
 *
 * @param selection Basicタブの選択値
 * @return かなモードのキーマップ名一覧
 */
QStringList kanaCanonicalOrder(const BasicInputStyleSelection& selection)
{
    QStringList order;
    if (selection.spaceStyle == 0) {
        order << fullwidthSpace;
    }
    order << jisKana;
    return order;
}

/**
 * @brief 名前と組込状態の完全一致で利用可能一覧からエントリを引く
 *
 * @param available 利用可能エントリの一覧
 * @param name 検索する名前
 * @return 一致するエントリへのポインタ、見つからない場合はnullptr
 */
const BasicAvailableEntry* findAvailable(const QVector<BasicAvailableEntry>& available,
                                         const QString& name)
{
    for (const BasicAvailableEntry& entry : available) {
        if (entry.name == name && entry.isBuiltin) {
            return &entry;
        }
    }
    return nullptr;
}

/**
 * @brief 名前列を利用可能一覧で解決し、欠落をmissingへ記録する
 *
 * @param names 解決する名前の一覧
 * @param available 利用可能エントリの一覧
 * @param resolved 解決済みエントリの追記先
 * @param missing 見つからなかった名前の追記先
 * @return 欠落が1つもなければtrue
 */
bool resolveEntries(const QStringList& names,
                    const QVector<BasicAvailableEntry>& available,
                    QVector<BasicProfileEntry>& resolved,
                    QStringList& missing)
{
    for (const QString& name : names) {
        const BasicAvailableEntry* found = findAvailable(available, name);
        if (found) {
            // サーバ報告のファイル名をそのまま採用 (自己同一性の検証はここで行う)
            resolved.append({found->name, found->isBuiltin, found->filename});
        }
        else {
            missing.append(name);
        }
    }
    return missing.isEmpty();
}

/**
 * @brief エントリ列から名前列を抽出する
 *
 * @param entries 対象のエントリ列
 * @return 名前を並べた文字列リスト
 */
QStringList namesOf(const QVector<BasicProfileEntry>& entries)
{
    QStringList names;
    names.reserve(entries.size());
    for (const BasicProfileEntry& entry : entries) {
        names << entry.name;
    }
    return names;
}

/**
 * @brief 新分割マップの名前集合を返す
 *
 * 新分割マップは旧[Fullwidth Symbol]とは併存しない
 *
 * @return 新分割マップ名の集合
 */
const QSet<QString>& newSplitMapNames()
{
    static const QSet<QString> names = {
        fullwidthBasicSymbol, fullwidthQuotation, typographicQuotation,
        japaneseBracket, fullwidthBracket, halfwidthBracket};
    return names;
}

/**
 * @brief 括弧マップ名のうち一覧に含まれるものの個数を数える
 *
 * @param nameSet 検査する名前集合
 * @return 含まれる括弧マップの個数 (0または1を期待)
 */
int bracketMapCount(const QSet<QString>& nameSet)
{
    int count = 0;
    for (const QString& bracket : {japaneseBracket, fullwidthBracket, halfwidthBracket}) {
        if (nameSet.contains(bracket)) {
            ++count;
        }
    }
    return count;
}

} // namespace

BasicInputStylePlan buildBasicInputStylePlan(const BasicInputStyleSelection& selection,
                                             const QVector<BasicAvailableEntry>& availableKeymaps,
                                             const QVector<BasicAvailableEntry>& availableTables)
{
    BasicInputStylePlan plan;

    QStringList requiredKeymaps;
    QStringList requiredTables;

    if (selection.isKanaMode()) {
        // かなモードは引用符・括弧のマップを生成しない (コンボは無効)
        requiredKeymaps = kanaCanonicalOrder(selection);
        requiredTables << kana;
        plan.submodeEntryPointChars = QString();
    }
    else {
        requiredKeymaps = romajiCanonicalOrder(selection);
        requiredTables << romaji;
        plan.submodeEntryPointChars = QStringLiteral("ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    }

    // all-or-nothing: 必須エントリがすべて揃う時のみ有効な計画を返す
    const bool keymapsOk = resolveEntries(requiredKeymaps, availableKeymaps, plan.keymaps, plan.missingKeymaps);
    const bool tablesOk = resolveEntries(requiredTables, availableTables, plan.tables, plan.missingTables);

    if (keymapsOk && tablesOk) {
        plan.ok = true;
        return plan;
    }

    plan.keymaps.clear();
    plan.tables.clear();
    return plan;
}

BasicInputStyleProjection projectBasicInputStyle(const QString& submodeEntryPointChars,
                                                 const QVector<BasicProfileEntry>& enabledKeymaps,
                                                 const QVector<BasicProfileEntry>& enabledTables)
{
    BasicInputStyleProjection result;

    // カスタム (非組込) が1つでもあればBasicでは表現できない
    for (const BasicProfileEntry& entry : enabledKeymaps) {
        if (!entry.isBuiltin) {
            return result;
        }
    }
    for (const BasicProfileEntry& entry : enabledTables) {
        if (!entry.isBuiltin) {
            return result;
        }
    }

    const QStringList keymapNames = namesOf(enabledKeymaps);
    const QSet<QString> nameSet(keymapNames.begin(), keymapNames.end());
    if (nameSet.size() != keymapNames.size()) {
        return result; // 重複は正準順序と一致し得ない
    }

    const QStringList tableNames = namesOf(enabledTables);

    // --- かなモード: テーブルはKanaのみ・サブモード入口なし・JISかな必須+任意で全角スペース ---
    if (submodeEntryPointChars.isEmpty()) {
        if (tableNames.size() != 1 || tableNames.first() != kana) {
            return result;
        }
        if (!nameSet.contains(jisKana)) {
            return result;
        }
        for (const QString& name : keymapNames) {
            if (name != jisKana && name != fullwidthSpace) {
                return result;
            }
        }

        BasicInputStyleSelection selection;
        selection.mainInputStyle = 1;
        selection.spaceStyle = nameSet.contains(fullwidthSpace) ? 0 : 1;

        if (keymapNames == kanaCanonicalOrder(selection)) {
            result.compatible = true;
            result.selection = selection;
        }
        return result;
    }

    // --- ローマ字モード ---
    if (submodeEntryPointChars != QStringLiteral("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) {
        return result;
    }
    if (tableNames.size() != 1 || tableNames.first() != romaji) {
        return result;
    }
    if (nameSet.contains(jisKana)) {
        return result;
    }

    // 許容される組み込みマップの全体集合 (レガシー + 新分割)
    static const QSet<QString> allowedNames = {
        fullwidthPeriod, fullwidthComma, fullwidthNumber, fullwidthSpace,
        japaneseSymbol, legacyFullwidthSymbol,
        fullwidthBasicSymbol, fullwidthQuotation, typographicQuotation,
        japaneseBracket, fullwidthBracket, halfwidthBracket};
    for (const QString& name : keymapNames) {
        if (!allowedNames.contains(name)) {
            return result;
        }
    }

    // 和字記号は必須 (正準順序の最後、欠落・順序違反は下の一致検査でも弾かれる)
    if (!nameSet.contains(japaneseSymbol)) {
        return result;
    }

    const bool hasLegacySymbol = nameSet.contains(legacyFullwidthSymbol);
    bool hasNewSplitMap = false;
    for (const QString& name : nameSet) {
        if (newSplitMapNames().contains(name)) {
            hasNewSplitMap = true;
            break;
        }
    }

    // レガシー全角記号と新分割マップの混在は非互換 (暗黙の書き換えをしない)
    if (hasLegacySymbol && hasNewSplitMap) {
        return result;
    }

    BasicInputStyleSelection selection;
    selection.mainInputStyle = 0;

    // 句読点形式
    const bool hasPeriod = nameSet.contains(fullwidthPeriod);
    const bool hasComma = nameSet.contains(fullwidthComma);
    if (hasPeriod && hasComma) {
        selection.punctuationStyle = 1;
    }
    else if (hasComma) {
        selection.punctuationStyle = 2;
    }
    else if (hasPeriod) {
        selection.punctuationStyle = 3;
    }
    else {
        selection.punctuationStyle = 0;
    }

    selection.numberStyle = nameSet.contains(fullwidthNumber) ? 0 : 1;
    selection.spaceStyle = nameSet.contains(fullwidthSpace) ? 0 : 1;

    QStringList expectedOrder;
    bool usesLegacyOrder = false;
    if (hasLegacySymbol) {
        // レガシー全角記号構成: 全角記号 / 全角引用符 / 和字括弧へ投影 (編集までプロファイルは不変)
        selection.symbolStyle = 0;
        selection.quotationStyle = 0;
        selection.bracketStyle = 0;
        expectedOrder = legacyCanonicalOrder(selection);
        usesLegacyOrder = true;
    }
    else if (hasNewSplitMap) {
        // 新形式: 括弧マップはちょうど1つ必須
        if (bracketMapCount(nameSet) != 1) {
            return result;
        }
        selection.symbolStyle = nameSet.contains(fullwidthBasicSymbol) ? 0 : 1;
        if (nameSet.contains(fullwidthQuotation)) {
            selection.quotationStyle = 0;
        }
        else if (nameSet.contains(typographicQuotation)) {
            selection.quotationStyle = 1;
        }
        else {
            selection.quotationStyle = 2;
        }
        if (nameSet.contains(japaneseBracket)) {
            selection.bracketStyle = 0;
        }
        else if (nameSet.contains(fullwidthBracket)) {
            selection.bracketStyle = 1;
        }
        else {
            selection.bracketStyle = 2;
        }
        expectedOrder = romajiCanonicalOrder(selection);
    }
    else {
        // レガシー和字記号のみ (旧半角記号構成): 表示専用投影とし、実際の混在挙動は明示編集まで残る
        selection.symbolStyle = 1;
        selection.quotationStyle = 2;
        selection.bracketStyle = 0;
        result.legacyDisplayOnly = true;
        expectedOrder = legacyCanonicalOrder(selection);
        usesLegacyOrder = true;
    }

    // レガシー構成は末尾2マップの入れ替わり (旧サーバ既定順) も認める
    // 一覧は書き換えず判定だけで許容し、上書き関係のある順序違反は非互換のままとする
    const bool orderMatches = usesLegacyOrder ? legacyOrderMatches(keymapNames, expectedOrder)
                                              : (keymapNames == expectedOrder);
    if (orderMatches) {
        result.compatible = true;
        result.selection = selection;
    }
    return result;
}

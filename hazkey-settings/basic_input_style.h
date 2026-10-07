/**
 * @file basic_input_style.h
 * @brief Basic入力方式タブの純ロジック (protobufとMainWindowから独立)
 *
 * - Basicタブの選択インデックスから、有効キーマップ / 入力テーブルの完全な順序付き置換計画を作る
 * - Advanced設定 (順序付きの有効一覧) がBasicで表現可能かを判定し、選択値へ逆投影する
 *
 * サーバは有効一覧を逆順にマージするため、一覧の先頭ほど優先度が高い
 * よって計画の順序がそのまま優先順位である (和字記号マップは常に最後)
 */
#ifndef HAZKEY_SETTINGS_BASIC_INPUT_STYLE_H
#define HAZKEY_SETTINGS_BASIC_INPUT_STYLE_H

#include <QString>
#include <QStringList>
#include <QVector>

/**
 * @brief Basic入力方式が使う組み込みキーマップ名
 *
 * 旧名は挙動を維持したレガシー、新名は分割マップ
 */
namespace BasicInputStyleKeymaps {
inline const QString fullwidthPeriod = QStringLiteral("Fullwidth Period");
inline const QString fullwidthComma = QStringLiteral("Fullwidth Comma");
inline const QString fullwidthNumber = QStringLiteral("Fullwidth Number");
inline const QString fullwidthSpace = QStringLiteral("Fullwidth Space");
inline const QString japaneseSymbol = QStringLiteral("Japanese Symbol");
inline const QString legacyFullwidthSymbol = QStringLiteral("Fullwidth Symbol");
inline const QString fullwidthBasicSymbol = QStringLiteral("Fullwidth Basic Symbol");
inline const QString fullwidthQuotation = QStringLiteral("Fullwidth Quotation");
inline const QString typographicQuotation = QStringLiteral("Typographic Quotation");
inline const QString japaneseBracket = QStringLiteral("Japanese Bracket");
inline const QString fullwidthBracket = QStringLiteral("Fullwidth Bracket");
inline const QString halfwidthBracket = QStringLiteral("Halfwidth Bracket");
inline const QString jisKana = QStringLiteral("JIS Kana");
} // namespace BasicInputStyleKeymaps

/**
 * @brief Basic入力方式が使う組み込み入力テーブル名
 */
namespace BasicInputStyleTables {
inline const QString romaji = QStringLiteral("Romaji");
inline const QString kana = QStringLiteral("Kana");
} // namespace BasicInputStyleTables

/**
 * @brief Basicタブのコンボ選択値
 *
 * 各フィールドはコンボの選択インデックスを保持する
 */
struct BasicInputStyleSelection {
    /** @brief 入力方式 (0: ローマ字 / 1: JISかな) */
    int mainInputStyle = 0;
    /** @brief 句読点形式 (0: 句点+読点 / 1: Period+Comma / 2: 句点+カンマ / 3: ピリオド+読点) */
    int punctuationStyle = 0;
    /** @brief 数字形式 (0: 全角 / 1: 半角) */
    int numberStyle = 0;
    /** @brief 記号形式 (0: 全角 / 1: 半角) */
    int symbolStyle = 0;
    /** @brief 引用符形式 (0: 全角引用符 / 1: 組版引用符 / 2: 半角) */
    int quotationStyle = 0;
    /** @brief 括弧形式 (0: 和字括弧 / 1: 全角括弧 / 2: 半角括弧) */
    int bracketStyle = 0;
    /** @brief 空白形式 (0: 全角 / 1: 半角) */
    int spaceStyle = 0;

    /** @brief JISかなモードかどうか */
    bool isKanaMode() const { return mainInputStyle == 1; }

    /** @brief すべてのフィールドが一致するかどうか */
    bool operator==(const BasicInputStyleSelection& other) const
    {
        return mainInputStyle == other.mainInputStyle &&
               punctuationStyle == other.punctuationStyle &&
               numberStyle == other.numberStyle &&
               symbolStyle == other.symbolStyle &&
               quotationStyle == other.quotationStyle &&
               bracketStyle == other.bracketStyle &&
               spaceStyle == other.spaceStyle;
    }
};

/**
 * @brief サーバから報告された利用可能なキーマップ / 入力テーブルのエントリ
 */
struct BasicAvailableEntry {
    /** @brief キーマップ / 入力テーブルの名前 */
    QString name;
    /** @brief 組込エントリならtrue */
    bool isBuiltin = false;
    /** @brief サーバが報告したファイル名 */
    QString filename;
};

/**
 * @brief プロファイルの有効一覧に書き込むエントリ
 *
 * サーバ報告値をそのまま使う
 */
struct BasicProfileEntry {
    /** @brief キーマップ / 入力テーブルの名前 */
    QString name;
    /** @brief 組込エントリならtrue */
    bool isBuiltin = false;
    /** @brief サーバが報告したファイル名 */
    QString filename;
};

/**
 * @brief Basic選択から生成した完全な置換計画
 *
 * 要求エントリが1つでも欠けるときは ok=false で中身は空
 */
struct BasicInputStylePlan {
    /** @brief 計画が有効な場合はtrue */
    bool ok = false;
    /** @brief 優先順 (先頭が最も強い) の完全な置換列 */
    QVector<BasicProfileEntry> keymaps;
    /** @brief 入力テーブルの完全な置換列 */
    QVector<BasicProfileEntry> tables;
    /** @brief ローマ字モードのサブモード入口文字、かなモードでは空 */
    QString submodeEntryPointChars;
    /** @brief 利用可能一覧に見つからなかった必須キーマップ名 */
    QStringList missingKeymaps;
    /** @brief 利用可能一覧に見つからなかった必須入力テーブル名 */
    QStringList missingTables;
};

/**
 * @brief Advanced設定からの逆投影結果
 */
struct BasicInputStyleProjection {
    /** @brief Advanced設定がBasicで表現できる場合はtrue */
    bool compatible = false;
    /** @brief 逆投影したBasicタブの選択値 */
    BasicInputStyleSelection selection;
    /** @brief レガシー設定を表示用にのみ投影した (まだプロファイルは新形式と一致しない) 場合true */
    bool legacyDisplayOnly = false;
};

/**
 * @brief Basic選択から順序付きのキーマップ / 入力テーブル置換計画を生成する
 *
 * 可用性検証はall-or-nothingであり、1つでも欠ける場合は部分計画を返さずmissingに欠落名を列挙する
 * 返す一覧は先頭ほど優先度が高い
 *
 * @param selection Basicタブの選択値
 * @param availableKeymaps CurrentConfig.available_keymaps の変換列
 * @param availableTables CurrentConfig.available_tables の変換列
 * @return 計画 (必須エントリの名前と組込状態がすべて利用可能一覧に存在する時のみ ok=true)
 */
BasicInputStylePlan buildBasicInputStylePlan(const BasicInputStyleSelection& selection,
                                             const QVector<BasicAvailableEntry>& availableKeymaps,
                                             const QVector<BasicAvailableEntry>& availableTables);

/**
 * @brief Advanced設定 (順序付き有効一覧) をBasic選択値へ逆投影する
 *
 * 読み取り専用であり、レガシー設定は表示専用の投影となって明示編集までプロファイルを書き換えない
 *
 * レガシー規則:
 * - [Fullwidth Symbol]単独構成は新分割マップを含まないので互換とし、全角基本記号 / 全角引用符 / 和字括弧へ投影する
 * - [Japanese Symbol]のみの旧半角構成は表示専用投影 (半角基本記号 / 半角引用符 / 和字括弧) とし legacyDisplayOnly=true
 * - [Fullwidth Symbol]と新分割マップの混在は非互換 (暗黙の書き換えをしない)
 * - 実一覧が選択値から生成される正準順序と完全一致する場合のみ互換 (順序・重複・欠落を同時に検査)
 * - レガシー構成に限り、対象キーが重ならない末尾の[Fullwidth Space]と[Japanese Symbol]の入れ替わり
 *   (旧サーバ既定順[Fullwidth Number]→[Fullwidth Symbol]→[Japanese Symbol]→[Fullwidth Space]) を認める
 *   一覧は書き換えず判定のみで許容し、上書き関係のある他の順序違反は非互換のまま
 *
 * @param submodeEntryPointChars プロファイルのサブモード入口文字
 * @param enabledKeymaps プロファイルの enabled_keymaps (先頭 = 高優先の順)
 * @param enabledTables プロファイルの enabled_tables
 * @return 互換性判定と投影結果
 */
BasicInputStyleProjection projectBasicInputStyle(const QString& submodeEntryPointChars,
                                                 const QVector<BasicProfileEntry>& enabledKeymaps,
                                                 const QVector<BasicProfileEntry>& enabledTables);

#endif // HAZKEY_SETTINGS_BASIC_INPUT_STYLE_H

/**
 * @file userdict_model.h
 * @brief ユーザ辞書エントリとTSV保存関数の宣言
 */

#ifndef USERDICT_MODEL_H
#define USERDICT_MODEL_H

#include <QString>
#include <QVector>

/**
 * @brief ユーザ辞書TSVの1行を表すモデル
 *
 * UIと単体テストが同じエントリ型と正規形式のファイル書込関数を共有できるよう、mainwindow.hとは分離して定義する
 *
 * @note 保存時はposがnounまたは空の場合、空のコメント列を含む
 *       末尾列を省略する
 *       それ以外のPOSでは、空のコメントであってもコメント列とPOS列の両方を出力する
 *       読み込み側でPOS列がない行にはnounが設定される
 */
struct UserDictEntry {
    /** @brief 辞書で照合する読み */
    QString reading;
    /** @brief 読みに対応する表記 */
    QString word;
    /** @brief 任意のコメント */
    QString comment;
    /**
     * @brief 品詞トークン
     *
     * nounは通常の品詞を表す
     * 空の場合も保存時にはnounと同じ省略形式として扱われ、非空の他の値はそのまま4列目に出力される
     */
    QString pos;
};

/**
 * @brief ユーザ辞書を正規形式のUTF-8 TSVとしてアトミックに保存する
 *
 * 先頭に "# reading<TAB>word<TAB>comment[<TAB>pos]\n" を出力し、各エントリを1行ずつLF終端で出力する
 * posがnounまたは空の行では、空のコメント列とPOS列を省略する
 * その他のPOSの行では、コメントが空でも4列目のPOSを保持する
 * QSaveFileの直接書込フォールバックを無効にするため、全内容の書込・flush・commitが成功した場合だけ対象ファイルが置き換えられる
 *
 * @param path 保存先のファイルパス
 * @param entries 保存するユーザー辞書エントリの列
 * @return 保存がcommitまで成功した場合はtrue、
 *         ファイルを開けない場合やストリームエラーが発生した場合、またはcommitに失敗した場合はfalse
 *         失敗時は保留中の書込を取り消し、既存ファイルを変更しない
 */
bool writeUserDictionaryFile(const QString& path,
                             const QVector<UserDictEntry>& entries);

#endif  // USERDICT_MODEL_H

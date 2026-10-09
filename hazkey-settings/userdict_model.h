/**
 * @file userdict_model.h
 * @brief ユーザ辞書エントリとTSV保存関数の宣言
 */

#ifndef USERDICT_MODEL_H
#define USERDICT_MODEL_H

#include <QString>
#include <QStringList>
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
 * @brief エントリの全フィールドがTSVとして安全かを返す
 *
 * reading/word/comment/posのいずれかに'\t' '\n' '\r'が含まれると、列や行がずれて
 * エントリが壊れる(サーバは'\n'と'\r'の両方で行分割する)ため、不正とみなす
 *
 * @param e 検査するエントリ
 * @return 全フィールドが安全ならtrue
 */
bool isValidUserDictEntry(const UserDictEntry& e);

/**
 * @brief QTextStream::readLine()が返した1行を、サーバと同じ規則でレコードへ分割する
 *
 * readLine()は'\n'と"\r\n"しか行終端として扱わないが、サーバは単独の'\r'も行終端として扱う
 * 読込・インポートはこの関数の結果を1レコードずつ処理し、サーバと同じ見え方にする
 * 空のレコードは含まない
 *
 * @param line readLine()が返した行
 * @return '\r'で分割した空でないレコードの列
 */
QStringList splitUserDictionaryRecords(const QString& line);

/**
 * @brief ユーザ辞書を正規形式のUTF-8 TSVとしてアトミックに保存する
 *
 * 先頭に"# reading<TAB>word<TAB>comment[<TAB>pos]\n"を出力して、各エントリを1行ずつLF終端で出力する
 * posがnounまたは空の行では、空のコメント列とPOS列を省略する
 * その他のPOSの行では、コメントが空でも4列目のPOSを保持する
 * QSaveFileの直接書込フォールバックを無効にするため、全内容の書込・flush・commitが成功した場合だけ対象ファイルが置き換えられる
 *
 * @param path 保存先のファイルパス
 * @param entries 保存するユーザー辞書エントリの列
 * @return 保存がcommitまで成功した場合はtrue
 *         次のいずれかの場合はfalse
 *         ・いずれかのエントリが [isValidUserDictEntry] を満たさない (ファイルは開かず変更しない)
 *         ・ファイルを開けない、またはストリームエラーが発生した
 *         ・commitに失敗した
 *         失敗時は保留中の書込を取り消し、既存ファイルを変更しない
 */
bool writeUserDictionaryFile(const QString& path,
                             const QVector<UserDictEntry>& entries);

#endif  // USERDICT_MODEL_H

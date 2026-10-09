/**
 * @file userdict_model.cpp
 * @brief ユーザ辞書TSVの正規化された保存処理の実装
 */

#include <QIODevice>
#include <QSaveFile>
#include <QTextStream>
#include "userdict_model.h"

namespace {

/**
 * @brief 1件のユーザ辞書エントリを正規TSV行として書き出す
 *
 * nounまたは空のPOSでは、コメントが空ならコメント列も省略する
 * それ以外のPOSでは、コメントの有無にかかわらずコメント列とPOS列を出力する
 *
 * @param out TSV行の出力先ストリーム
 * @param e 書き出すユーザ辞書エントリ
 */
void writeUserDictEntry(QTextStream& out, const UserDictEntry& e) {
    if (e.pos == QStringLiteral("noun") || e.pos.isEmpty()) {
        out << e.reading << '\t' << e.word;
        if (!e.comment.isEmpty()) out << '\t' << e.comment;
    } else {
        out << e.reading << '\t' << e.word << '\t' << e.comment << '\t'
            << e.pos;
    }
}

/**
 * @brief 1つのフィールドがTSVの区切り・行終端文字を含まないかを返す
 *
 * サーバは本文を'\n'と'\r'の双方で行に分割するため(userDictionary.swift)、
 * '\r'の単独混入でも1エントリが2行に割れて壊れる
 * そのためフィールドには'\t' '\n' '\r'のいずれも許さない
 *
 * @param field 検査対象のフィールド
 * @return 区切り・行終端文字を含まなければtrue
 */
bool isSafeUserDictField(const QString& field) {
    return !field.contains(QLatin1Char('\t')) &&
           !field.contains(QLatin1Char('\n')) &&
           !field.contains(QLatin1Char('\r'));
}

}  // namespace

bool isValidUserDictEntry(const UserDictEntry& e) {
    return isSafeUserDictField(e.reading) && isSafeUserDictField(e.word) &&
           isSafeUserDictField(e.comment) && isSafeUserDictField(e.pos);
}

QStringList splitUserDictionaryRecords(const QString& line) {
    // QTextStream::readLine()が除去するのは'\n'と"\r\n"だけで、単独の'\r'は行内に残る
    // サーバは'\r'も行区切りとして扱うため、同じ規則で分割し空行は捨てる
    return line.split(QLatin1Char('\r'), Qt::SkipEmptyParts);
}

bool writeUserDictionaryFile(const QString& path,
                             const QVector<UserDictEntry>& entries) {
    // 書込時の方針:
    //   不正なフィールド(タブ・CR・LF)を持つエントリが1件でもあれば、ファイルを一切開かずに失敗を返す
    //   黙って変形せず、既存ファイルも変更しない
    for (const auto& e : entries) {
        if (!isValidUserDictEntry(e)) return false;
    }

    QSaveFile file(path);
    // 保存先への直接書込にはフォールバックしない
    // 途中まで書かれた辞書が既存の辞書を置き換えてはならないため
    file.setDirectWriteFallback(false);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) return false;
    // QSaveFileは新規ファイルにはumask依存の権限、既存ファイルには旧権限を最終権限として記録する
    // open()後に上書きすれば、commit()が改名前の一時ファイル(作成時0600)へ適用するため、
    // 0644などの公開状態が一瞬でも現れない
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << "# reading<TAB>word<TAB>comment[<TAB>pos]\n";
    for (const auto& e : entries) {
        writeUserDictEntry(out, e);
        out << '\n';
    }
    out.flush();
    if (out.status() != QTextStream::Ok) {
        file.cancelWriting();
        return false;
    }
    return file.commit();
}

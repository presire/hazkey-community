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

}  // namespace

bool writeUserDictionaryFile(const QString& path,
                             const QVector<UserDictEntry>& entries) {
    QSaveFile file(path);
    // Never fall back to writing the target file directly: a partially
    // written dictionary must never replace the existing one.
    file.setDirectWriteFallback(false);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) return false;

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

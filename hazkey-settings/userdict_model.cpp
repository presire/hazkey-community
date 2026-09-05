#include "userdict_model.h"

#include <QIODevice>
#include <QSaveFile>
#include <QTextStream>

namespace {

// Canonical per-row rendering shared by saves and exports.  noun (or an
// empty pos) omits the trailing columns; any other POS always keeps the
// fourth column.
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

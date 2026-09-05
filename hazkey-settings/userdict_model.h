#ifndef USERDICT_MODEL_H
#define USERDICT_MODEL_H

#include <QString>
#include <QVector>

// One row of the user dictionary TSV ($XDG_CONFIG_HOME/hazkey/
// user_dictionary.tsv).  Lives in a model header instead of mainwindow.h so
// the UI and the unit tests share the type and the canonical file writer.
struct UserDictEntry {
    QString reading;
    QString word;
    QString comment;
    QString pos;
};

// Writes the canonical UTF-8 TSV representation of `entries` to `path`
// atomically.  Uses QSaveFile with direct-write fallback disabled: the
// target file is replaced only when the entire content was written,
// flushed, and commit() succeeded.  On any stream error the pending write
// is cancelled and a pre-existing file is left untouched.  Returns true
// only when the write was committed successfully.
bool writeUserDictionaryFile(const QString& path,
                             const QVector<UserDictEntry>& entries);

#endif  // USERDICT_MODEL_H

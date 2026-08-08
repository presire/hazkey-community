#ifndef HAZKEY_KEYSEQUENCE_UTIL_H
#define HAZKEY_KEYSEQUENCE_UTIL_H

#include <QKeySequence>
#include <QString>

// Converts a QKeySequence to the fcitx5 Key string format.
// E.g. "Ctrl+Shift+L" -> "Control+Shift+L", "Meta+K" -> "Super+K".
QString fcitxKeyStringFromQKeySequence(const QKeySequence& seq);

// Converts an fcitx5 Key string to a QKeySequence.
// E.g. "Control+Shift+L" -> "Ctrl+Shift+L", "Super+K" -> "Meta+K".
QKeySequence qKeySequenceFromFcitxKeyString(const QString& fcitxStr);

#endif  // HAZKEY_KEYSEQUENCE_UTIL_H

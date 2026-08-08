#include "keysequence_util.h"

#include <functional>

#include <QStringList>

namespace {

// Splits a key sequence string into its `+`-separated tokens, applies the
// per-token conversion, and rejoins with `+`. Passing the identity function
// as `convert` leaves the tokens unchanged.
QString convertTokens(const QString& sequence,
                      std::function<QString(const QString&)> convert) {
    if (sequence.isEmpty()) {
        return QString();
    }
    const QStringList tokens = sequence.split(QLatin1Char('+'));
    QStringList converted;
    converted.reserve(tokens.size());
    for (const QString& token : tokens) {
        converted.append(convert(token));
    }
    return converted.join(QLatin1Char('+'));
}

QString qtTokenToFcitx(const QString& token) {
    if (token == QLatin1String("Ctrl")) {
        return QStringLiteral("Control");
    }
    if (token == QLatin1String("Meta")) {
        return QStringLiteral("Super");
    }
    return token;
}

QString fcitxTokenToQt(const QString& token) {
    if (token == QLatin1String("Control")) {
        return QStringLiteral("Ctrl");
    }
    if (token == QLatin1String("Super")) {
        return QStringLiteral("Meta");
    }
    return token;
}

}  // namespace

QString fcitxKeyStringFromQKeySequence(const QKeySequence& seq) {
    return convertTokens(seq.toString(QKeySequence::PortableText),
                         qtTokenToFcitx);
}

QKeySequence qKeySequenceFromFcitxKeyString(const QString& fcitxStr) {
    const QString converted = convertTokens(fcitxStr, fcitxTokenToQt);
    return QKeySequence::fromString(converted, QKeySequence::PortableText);
}

/**
 * @file keysequence_util.cpp
 * @brief keysequence_util.h の実装
 *
 * 公開APIの仕様はヘッダ (keysequence_util.h) を参照のこと
 * 本ファイルにはトークン単位の変換を担う内部ヘルパのみを実装する
 */

#include "keysequence_util.h"
#include <functional>
#include <QStringList>

namespace {

/**
 * @brief キーシーケンス文字列を「+」区切りのトークンに分割し、
 *        各トークンに変換関数を適用して「+」で再結合する
 *
 * @internal 匿名名前空間内の実装専用ヘルパ (公開APIからは直接呼ばれない)
 *
 * @param sequence 変換対象のキーシーケンス文字列
 * @param convert  各トークンに適用する変換関数
 *                 恒等関数を渡すとトークンは変更されずにそのまま返る
 * @return 変換後のキーシーケンス文字列
 *         sequence が空の場合は空文字列を返す
 */
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

/**
 * @brief Qt表記のトークンをfcitx5表記に変換する
 *
 * @internal 匿名名前空間内の実装専用ヘルパ
 *
 * @param token 変換対象のトークン
 * @return 変換後のトークン ("Ctrl" → "Control"、"Meta" → "Super"、それ以外は入力トークンをそのまま返す)
 */
QString qtTokenToFcitx(const QString& token) {
    if (token == QLatin1String("Ctrl")) {
        return QStringLiteral("Control");
    }
    if (token == QLatin1String("Meta")) {
        return QStringLiteral("Super");
    }
    return token;
}

/**
 * @brief fcitx5表記のトークンをQt表記に変換する
 *
 * @internal 匿名名前空間内の実装専用ヘルパ
 *
 * @param token 変換対象のトークン
 * @return 変換後のトークン ("Control" → "Ctrl"、"Super" → "Meta"、それ以外は入力トークンをそのまま返す)
 */
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

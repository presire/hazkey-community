/**
 * @file keysequence_util.h
 * @brief QtのQKeySequenceとfcitx5のKey文字列との相互変換ユーティリティ
 *
 * hazkey-settingsは、fcitx5の設定スキーマ (hazkey_config.h) とQtのQKeySequenceEditの両方でホットキーを扱うため、
 * 両形式の間でキーシーケンスを変換する必要がある
 * 本ヘッダはその変換APIを提供する
 *
 * 変換は「+」区切りのトークン単位で行われ、以下の2組の表記のみが書き換えられる:
 * - Qtの"Ctrl" ⇔ fcitx5の"Control"
 * - Qtの"Meta" ⇔ fcitx5の"Super"
 *
 * それ以外のトークン (Shift / Alt / 英数字 / F1〜F12 等) はそのまま維持される
 */

#ifndef HAZKEY_KEYSEQUENCE_UTIL_H
#define HAZKEY_KEYSEQUENCE_UTIL_H

#include <QKeySequence>
#include <QString>

/**
 * @brief QKeySequenceをfcitx5のKey文字列形式に変換する
 *
 * 入力シーケンスはPortableText形式で文字列化され、各トークンがfcitx5表記に変換される
 *
 * @param seq 変換対象のQKeySequence
 * @return fcitx5のKey文字列 (例: "Ctrl+Shift+L" → "Control+Shift+L"、"Meta+K" → "Super+K")
 *
 * @note 空のQKeySequenceを渡した場合は空文字列を返す
 * @note Qtの"Ctrl"はfcitx5の"Control"に、"Meta"は"Super"にそれぞれ変換され、それ以外のトークンは変更されない
 */
QString fcitxKeyStringFromQKeySequence(const QKeySequence& seq);

/**
 * @brief fcitx5のKey文字列をQKeySequenceに変換する
 *
 * 入力文字列を「+」で分割し、各トークンをQt表記に変換した上でPortableText形式として、QKeySequenceを構築する
 *
 * @param fcitxStr 変換対象のfcitx5 Key文字列
 * @return 変換結果の QKeySequence (例: "Control+Shift+L" → "Ctrl+Shift+L"、"Super+K" → "Meta+K")
 *
 * @note 空文字列を渡した場合は、空のQKeySequenceを返す
 * @note fcitx5の"Control"はQtの"Ctrl"に、"Super"は"Meta"にそれぞれ変換され、それ以外のトークンは変更されない
 */
QKeySequence qKeySequenceFromFcitxKeyString(const QString& fcitxStr);

#endif  // HAZKEY_KEYSEQUENCE_UTIL_H

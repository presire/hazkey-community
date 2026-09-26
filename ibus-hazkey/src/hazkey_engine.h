#ifndef IBUS_HAZKEY_HAZKEY_ENGINE_H
#define IBUS_HAZKEY_HAZKEY_ENGINE_H

/**
 * @file hazkey_engine.h
 * @brief IBus入力エンジン型の公開宣言を定義する
 *
 * IBusデーモンがエンジン型を解決するための型取得関数と型マクロだけを公開する
 */

#include <ibus.h>

/**
 * @brief HazkeyエンジンのGTypeを取得する
 *
 * @return Hazkeyエンジン型を示すGType
 */
GType ibus_hazkey_engine_get_type(void);

/** @brief Hazkeyエンジン型を示す型マクロ */
#define IBUS_TYPE_HAZKEY_ENGINE (ibus_hazkey_engine_get_type())

#endif  // IBUS_HAZKEY_HAZKEY_ENGINE_H

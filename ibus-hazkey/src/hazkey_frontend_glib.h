/**
 * @file hazkey_frontend_glib.h
 * @brief GLibフックの導入口を宣言する
 */
#ifndef IBUS_HAZKEY_HAZKEY_FRONTEND_GLIB_H
#define IBUS_HAZKEY_HAZKEY_FRONTEND_GLIB_H

/** @brief IBusフロントエンドの名前空間 */
namespace hazkey::ibus {

/**
 * @brief GLib向けのフロントエンドフックを導入する
 *
 * メインループ配送、ログ出力、サーバ起動をGLib実装へ結び付ける
 * 実行中ワーカーとの競合を避けるため、フロントエンド構築より前に1回だけ呼ぶこと
 */
void installGlibFrontendHooks();

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_FRONTEND_GLIB_H

#ifndef IBUS_HAZKEY_LIVE_CONVERT_MODE_H
#define IBUS_HAZKEY_LIVE_CONVERT_MODE_H

/**
 * @file live_convert_mode.h
 * @brief ライブ変換トグル時の次回自動変換モードを決めるフロントエンド非依存ロジック
 */

#include "config.pb.h"

/** @brief IBusフロントエンドのライブ変換トグルロジックの名前空間 */
namespace hazkey::ibus {

/**
 * @brief ホットキーでライブ変換を切り替えたときの次の自動変換モードを返す
 *
 * - currentがDISABLEDの場合: remembered (最後の非DISABLEDモード、デフォルトはALWAYS) を返す
 * - それ以外の場合: remembered = currentとして、DISABLEDを返す
 *
 * ホットキーで ALWAYS<->FOR_MULTIPLE_CHARS を直接行き来することはない
 * どちらも設定画面から到達でき、有効だった方がトグルオン時に復元される
 *
 * fcitx5-hazkey/src/live_convert_mode.cpp (名前空間: fcitx) の移植
 * 遷移はフロントエンドに依存しない (protobufのenumのみ) ため、IBusフロントエンドはFcitxアドオンモジュールへのリンクではなく、
 * 自身の名前空間にコピーを保持する
 *
 * @param current 現在の自動変換モード
 * @param remembered 最後の非DISABLEDモード (入出力)
 *                   トグルオフ時にcurrentが記録される
 * @return 次に適用する自動変換モード
 */
hazkey::config::Profile_AutoConvertMode computeNextAutoConvertMode(
    hazkey::config::Profile_AutoConvertMode current,
    hazkey::config::Profile_AutoConvertMode& remembered);

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_LIVE_CONVERT_MODE_H

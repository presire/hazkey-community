/**
 * @file composing_cursor_view.h
 * @brief 組成中カーソルの表示判定とキャレット位置計算を提供する
 *
 * 両フロントエンドで同じ一時停止動作を実現する純粋な表示規則を定義する
 * カーソルが末尾にない間は、ライブ変換表示を出さない
 *
 * 生かなの全文と実際のキャレット位置を表示する
 * かなの位置を変換後文字列へ対応付けられないためである
 *
 * 末尾へ戻った瞬間にライブ変換表示へ復帰する
 *
 * 判定と計算をここに集約する
 * 両フロントエンド間のずれを防ぐ
 *
 * @note Fcitx 5、IBus、GLibの型を使わない純粋関数のみを置く
 * @note 単位系のみが異なり、意味は同一である
 */

#ifndef HAZKEY_COMPOSING_CURSOR_VIEW_H
#define HAZKEY_COMPOSING_CURSOR_VIEW_H

#include <cstddef>
#include <string>
#include "config.pb.h"
#include "hazkey_frontend_hooks.h"

namespace hazkey::frontend {

/**
 * @brief サーバが返したカーソルが組成末尾にあるか判定する
 *
 * onCursorとafterがともに空の場合だけtrueを返す
 * 空合成は末尾扱いとする
 * 末尾文字上や途中位置では偽を返す
 *
 * @param parts サーバ報告の合成分割
 * @return 末尾にある場合はtrue
 */
bool cursorAtEnd(const ComposingTextWithCursor& parts);

/**
 * @brief 合成全文を結合して返す
 *
 * beforeとonCursorとafterを順に結合するだけである
 *
 * @param parts サーバ報告の合成分割
 * @return 合成全文
 */
std::string composingTextOf(const ComposingTextWithCursor& parts);

/**
 * @brief UTF-8バイト単位のキャレット位置を返す
 *
 * Fcitx 5の表示用
 * バイト単位で数える点が文字数版との違いである
 *
 * @param parts サーバ報告の合成分割
 * @return before部のバイト長
 */
std::size_t caretByteOffset(const ComposingTextWithCursor& parts);

/**
 * @brief UTF-8文字数単位のキャレット位置を返す
 *
 * IBusの表示用
 * バイト単位で数える版との違いである
 * GLibを使わずに数えるため枠組みに依存しない
 *
 * @param parts サーバ報告の合成分割
 * @return before部の文字数
 *
 * @note 不正な末尾バイトは例外にせず1文字として数える
 * @note 表示専用値に必要な寛容な数え方である
 */
std::size_t caretCharOffset(const ComposingTextWithCursor& parts);

/**
 * @brief 生かなの補助表示を出すべきか判定する
 *
 * 判定をフロントエンド側に置く
 * サーバの取得処理は純粋な構造報告のまま保てる
 *
 * @param mode 補助表示方式
 * @param cursorIsAtEnd カーソルが末尾にある場合はtrue
 * @return 表示する場合はtrue
 *
 * @note 無効指定では出さない
 * @note 常時表示では常に出す
 * @note 非末尾時のみ表示では末尾外の場合だけ出す
 * @note 未設定値は非末尾時のみ表示と同じ扱いである
 * @note サーバ既定の追随である
 */
bool shouldShowAuxText(hazkey::config::Profile_AuxTextMode mode,
                       bool cursorIsAtEnd);

}  // namespace hazkey::frontend

#endif  // HAZKEY_COMPOSING_CURSOR_VIEW_H

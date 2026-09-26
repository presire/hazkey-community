#ifndef _FCITX5_HAZKEY_HAZKEY_FRONTEND_ADAPTER_H_
#define _FCITX5_HAZKEY_HAZKEY_FRONTEND_ADAPTER_H_

#include <fcitx/text.h>

#include "hazkey_frontend_hooks.h"

namespace fcitx {

/// 共通transportへFcitxログ出力とサーバ起動処理を登録する
/// 最初のサーバ接続生成より前に呼び出す
void installHazkeyFrontendHooks();

/// 生成時にFcitx向け共通transportフックを登録するガード
class HazkeyFrontendHooksGuard {
   public:
    /// フックを登録する
    HazkeyFrontendHooksGuard() { installHazkeyFrontendHooks(); }
};

/// transportのカーソル位置情報を下線付きfcitxテキストへ変換する
/// @param parts カーソル前・カーソル上・カーソル後の文字列
/// @return カーソル上の部分に下線を付けたテキスト
Text composingTextWithCursorToFcitxText(
    const hazkey::frontend::ComposingTextWithCursor& parts);

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_HAZKEY_FRONTEND_ADAPTER_H_

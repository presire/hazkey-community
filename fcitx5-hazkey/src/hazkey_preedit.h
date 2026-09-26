#ifndef _FCITX5_HAZKEY_HAZKEY_PREEDIT_H_
#define _FCITX5_HAZKEY_HAZKEY_PREEDIT_H_

#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>

namespace fcitx {
/// Fcitx入力パネルのpreedit表示と確定を扱う
class HazkeyPreedit {
   public:
    /// 入力コンテキストを参照して表示操作を行う
    HazkeyPreedit(InputContext *ic) : ic_(ic) {}

    /// 現在のpreedit文字列を返す
    std::string text() const;
    /// 予測表示用のpreeditを強調表示する
    void setSimplePreeditHighlighted(const std::string &text);
    /// 単一セグメントのpreeditを下線表示する
    void setSimplePreedit(const std::string &text);
    /// 生かなpreeditを表示し、UTF-8バイト位置にカーソルを置く
    void setRawPreeditWithCaret(const std::string &text, int caretByteOffset);
    /// 複数セグメントのpreeditを指定位置の強調付きで表示する
    void setMultiSegmentPreedit(std::vector<std::string> &texts, int cursor);
    /// 指定テキストを入力パネルへ設定する
    void setPreedit(Text text);
    /// 現在のpreeditを確定文字列として送る
    void commitPreedit();

   private:
    InputContext *ic_;  ///< 非所有の入力コンテキスト参照
};

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_HAZKEY_PREEDIT_H_

#ifndef _FCITX5_HAZKEY_HAZKEY_PREEDIT_H_
#define _FCITX5_HAZKEY_HAZKEY_PREEDIT_H_

#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>

namespace fcitx {
class HazkeyPreedit {
   public:
    HazkeyPreedit(InputContext *ic) : ic_(ic) {}

    std::string text() const;
    // set the preedit text; prediction mode (highlighted)
    void setSimplePreeditHighlighted(const std::string &text);
    // set the preedit text; prediction mode (not highlighted)
    void setSimplePreedit(const std::string &text);
    // [community] set the raw-kana preedit with a REAL caret inside it.
    // caretByteOffset is a UTF-8 byte offset (fcitx::Text::setCursor() is
    // documented "by byte" in fcitx5's text.h). Used while live conversion is
    // paused, i.e. while the composition cursor is not at the end.
    void setRawPreeditWithCaret(const std::string &text, int caretByteOffset);
    // set the preedit text; multi-segment mode
    void setMultiSegmentPreedit(std::vector<std::string> &texts, int cursor);
    // set the preedit text
    void setPreedit(Text text);
    // commit the preedit text
    void commitPreedit();

   private:
    // fcitx input context pointer
    InputContext *ic_;
};

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_HAZKEY_PREEDIT_H_

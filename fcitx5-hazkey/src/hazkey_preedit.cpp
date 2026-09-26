#include "hazkey_preedit.h"

namespace fcitx {

/// 表示能力に応じたpreedit領域から文字列を取得する
std::string HazkeyPreedit::text() const {
    if (ic_->capabilityFlags().test(CapabilityFlag::Preedit)) {
        return ic_->inputPanel().clientPreedit().toString();
    } else {
        return ic_->inputPanel().preedit().toString();
    }
}

/// クライアントpreedit対応状況に合わせてテキストを設定する
void HazkeyPreedit::setPreedit(Text text) {
    if (ic_->capabilityFlags().test(CapabilityFlag::Preedit)) {
        ic_->inputPanel().setClientPreedit(text);
    } else {
        ic_->inputPanel().setPreedit(text);
    }
}

/// 単一セグメントを強調表示する
void HazkeyPreedit::setSimplePreeditHighlighted(const std::string &text) {
    std::vector<std::string> texts = {text};
    setMultiSegmentPreedit(texts, 0);
}

/// 単一セグメントを下線表示する
void HazkeyPreedit::setSimplePreedit(const std::string &text) {
    std::vector<std::string> texts = {text};
    setMultiSegmentPreedit(texts, -1);
}

/// 生かなを下線表示し、指定バイト位置にカーソルを置く
void HazkeyPreedit::setRawPreeditWithCaret(const std::string &text,
                                           int caretByteOffset) {
    auto preedit = Text();
    // setSimplePreedit()と同じ下線表示にする
    // cursorSegment = -1はsetMultiSegmentPreedit()の下線表示分岐に入るため、
    // ライブ変換の一時停止時は表示形式を変えずカーソルだけを加える
    preedit.append(text, TextFormatFlag::Underline);
    preedit.setCursor(caretByteOffset);
    setPreedit(preedit);
}

/// セグメント位置に応じて通常・強調・下線表示を設定する
void HazkeyPreedit::setMultiSegmentPreedit(std::vector<std::string> &texts,
                                           int cursorSegment = 0) {
    auto preedit = Text();
    for (int i = 0; size_t(i) < texts.size(); i++) {
        if (i < cursorSegment) {
            preedit.append(texts[i], TextFormatFlag::NoFlag);
        } else if (i == cursorSegment) {
            preedit.setCursor(preedit.textLength());
            preedit.append(texts[i], TextFormatFlag::HighLight);
            continue;
        } else {
            preedit.append(texts[i], TextFormatFlag::Underline);
        }
    }
    setPreedit(preedit);
}

/// 表示中のpreeditを入力コンテキストへ確定する
void HazkeyPreedit::commitPreedit() {
    if (ic_->capabilityFlags().test(CapabilityFlag::Preedit)) {
        ic_->commitString(
            ic_->inputPanel().clientPreedit().toStringForCommit());
    } else {
        ic_->commitString(ic_->inputPanel().preedit().toStringForCommit());
    }
}

}  // namespace fcitx

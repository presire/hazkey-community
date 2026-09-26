/**
 * @file composing_cursor_view_test.cpp
 * @brief 合成カーソル表示規則の単体検証をまとめる
 *
 * 末尾判定とバイト単位文字単位のcaret位置算出と補助表示開閉条件を検証して、両フロントエンドの共通判定がずれないことを保証する
 * サーバやソケットやtoolkitを使用しない純粋関数の検査である
 */

// 共通の組成カーソル表示規則を検証する
//
// 純粋関数をライブ変換一時停止の唯一の判定元として、
// fcitx5-hazkey-communityとibus-hazkey-communityの両方がモードやキャレット位置を個別に算出しないことを確認する
//
// hazkey-frontend-commonへ登録するため、IBus単独ビルドでも実行される
// [ENABLE_FCITX5=OFF]
//
// hazkey-community-server、ソケット、フロントエンドのツールキットは使用しない

#include "composing_cursor_view.h"
#include <cassert>
#include <iostream>
#include <string>

namespace {

using hazkey::frontend::caretByteOffset;
using hazkey::frontend::caretCharOffset;
using hazkey::frontend::composingTextOf;
using hazkey::frontend::ComposingTextWithCursor;
using hazkey::frontend::cursorAtEnd;
using hazkey::frontend::shouldShowAuxText;

/**
 * @brief 検証用の合成テキスト断片を組み立てる
 *
 * 前方文字列とカーソル上文字と後方文字列から、ComposingTextWithCursorを生成して各検証へ渡す
 * 空合成や末尾配置や中間配置の再現に使用する
 */
ComposingTextWithCursor parts(const std::string& before,
                              const std::string& onCursor,
                              const std::string& after) {
    return ComposingTextWithCursor{before, onCursor, after};
}

/**
 * @brief 空合成が末尾扱いであることを検証する
 *
 * 3つの領域が全て空の入力に対して末尾判定が真となり、バイト位置と文字位置が零となり合成全文が空であることを確認する
 * 空の場合にライブ変換を停止しない前提を保証する
 */
void testEmptyComposition() {
    // サーバが3つの空フィールドを返す組成なしの状態を作る
    const auto p = parts("", "", "");

    // 空組成は末尾扱いとなり、ライブ変換を停止せずキャレット位置は零となる
    assert(cursorAtEnd(p));
    assert(caretByteOffset(p) == 0);
    assert(caretCharOffset(p) == 0);
    assert(composingTextOf(p).empty());

    std::cout << "[PASS] empty composition is end mode with a zero caret\n";
}

/**
 * @brief カーソル末尾配置が末尾扱いであることを検証する
 *
 * 最終文字の直後にカーソルがある入力に対して末尾判定が真となり、バイト位置が全文長に一致し文字位置が文字数に一致することを確認する
 * 末尾ではライブ変換を継続する前提を保証する
 */
void testCursorAtEnd() {
    // カーソル上と後方が空で、最終文字の直後にカーソルがある状態を作る
    const auto p = parts("あいう", "", "");
    assert(cursorAtEnd(p));

    // キャレット位置はテキストの末尾となる
    assert(caretByteOffset(p) == std::string("あいう").size());
    assert(caretCharOffset(p) == 3);
    assert(composingTextOf(p) == "あいう");

    std::cout << "[PASS] cursor at end keeps live conversion enabled\n";
}

/**
 * @brief 最終文字上配置が内部扱いであることを検証する
 *
 * カーソル上文字に最終文字がある入力に対して末尾判定が偽となり、位置が前方文字列の長さに一致し全文が復元されることを確認する
 * 後方空文字だけでの誤判定を防ぐ事例である
 */
void testCursorOnLastCharacter() {
    // 後方は空でもカーソル上に最終文字がある状態を作る
    // 後方文字列だけを見る判定では末尾と誤認するケースである
    const auto p = parts("あい", "う", "");
    assert(!cursorAtEnd(p));
    assert(caretByteOffset(p) == std::string("あい").size());
    assert(caretCharOffset(p) == 2);
    assert(composingTextOf(p) == "あいう");

    std::cout << "[PASS] cursor on the last character is internal mode\n";
}

/**
 * @brief 中間配置が内部扱いであることを検証する
 *
 * 前方とカーソル上と後方に文字がある入力に対して末尾判定が偽となり、位置が前方文字列の長さに一致し全文が復元されることを確認する
 */
void testCursorInMiddle() {
    const auto p = parts("あ", "い", "うえ");
    assert(!cursorAtEnd(p));
    assert(caretByteOffset(p) == std::string("あ").size());
    assert(caretCharOffset(p) == 1);
    assert(composingTextOf(p) == "あいうえ");

    std::cout << "[PASS] cursor in the middle is internal mode\n";
}

/**
 * @brief バイト単位と文字単位の位置が別単位であることを検証する
 *
 * かなでは両単位が異なることと英字かな混在ではかな分だけ差が出ることと、純粋英字では両単位が一致することと絵文字が一文字扱いであることを確認する
 * 両フロントエンドで表示位置がずれない前提を保証する
 */
void testMultibyteCaretUnits() {
    // Fcitx 5は、バイト位置、IBusは文字位置を必要とする
    // UTF-8のかなは1文字3バイトのため、両者は異ならなければならない
    const auto kana = parts("あいう", "え", "お");
    assert(caretByteOffset(kana) == 9);
    assert(caretCharOffset(kana) == 3);
    assert(caretByteOffset(kana) != caretCharOffset(kana));

    // ASCIIとかなの混在では、かなだけがバイト位置を増やす
    const auto mixed = parts("abあ", "い", "");
    assert(caretByteOffset(mixed) == 5);
    assert(caretCharOffset(mixed) == 3);

    // ASCIIだけでは両単位が一致する
    const auto ascii = parts("abc", "d", "");
    assert(caretByteOffset(ascii) == 3);
    assert(caretCharOffset(ascii) == 3);

    // 4バイトのUTF-8絵文字も1文字として数える
    const auto emoji = parts("\xF0\x9F\x98\x80", "あ", "");
    assert(caretByteOffset(emoji) == 4);
    assert(caretCharOffset(emoji) == 1);

    std::cout << "[PASS] caret byte and character offsets are distinct units\n";
}

/**
 * @brief 補助表示の開閉条件が四方式で正しいことを検証する
 *
 * 無効では常に非表示となり常時表示では常に表示、末尾以外表示では内部位置でのみ表示となり、
 * 未指定では既定と同様に振る舞うことを確認する
 */
void testAuxTextGate() {
    using Mode = hazkey::config::Profile_AuxTextMode;

    // 無効ではカーソル位置にかかわらず表示しない
    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_DISABLED, /*cursorIsAtEnd=*/ true));
    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_DISABLED, /*cursorIsAtEnd=*/ false));

    // 常時表示ではカーソル位置にかかわらず表示する
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS, /*cursorIsAtEnd=*/ true));
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS, /*cursorIsAtEnd=*/ false));

    // 末尾以外表示では内部位置でだけ表示する
    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END, /*cursorIsAtEnd=*/ true));
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END, /*cursorIsAtEnd=*/ false));

    // 未指定は非表示ではなく、サーバ既定の末尾以外表示へフォールバックする
    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_MODE_UNSPECIFIED, /*cursorIsAtEnd=*/ true));
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_MODE_UNSPECIFIED, /*cursorIsAtEnd=*/ false));

    std::cout << "[PASS] aux-text gate for all four modes x end/internal\n";
}

/**
 * @brief 開閉条件と末尾判定の組合せを検証する
 *
 * 末尾以外表示方式に末尾判定の結果を渡した時に、末尾配置では非表示となり、内部配置では表示となることを確認する
 * 呼び出し順の反転を防ぐための結合検査である
 */
void testGateComposesWithCursorAtEnd() {
    // フロントエンドは、2つの関数を組み合わせて呼ぶ
    // 将来のシグネチャ変更で判定が逆転しないことを確認する
    using Mode = hazkey::config::Profile_AuxTextMode;
    const auto atEnd = parts("あいう", "", "");
    const auto internalPos = parts("あい", "う", "");

    assert(!shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END, cursorAtEnd(atEnd)));
    assert(shouldShowAuxText(Mode::Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END, cursorAtEnd(internalPos)));

    std::cout << "[PASS] gate composed with cursorAtEnd()\n";
}

}  // namespace

/**
 * @brief 全ての合成カーソル検証を順に実行する
 *
 * 空合成・末尾配置・最終文字上配置・中間配置・多バイト単位・補助表示条件・判定組合せを呼び出して成功を報告する
 */
int main() {
    testEmptyComposition();
    testCursorAtEnd();
    testCursorOnLastCharacter();
    testCursorInMiddle();
    testMultibyteCaretUnits();
    testAuxTextGate();
    testGateComposesWithCursorAtEnd();
    std::cout << "composing_cursor_view_test: all checks passed\n";
    return 0;
}

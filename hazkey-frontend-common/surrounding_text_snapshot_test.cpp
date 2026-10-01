/**
 * @file surrounding_text_snapshot_test.cpp
 * @brief 周辺テキストのスナップショット生成規則を単体検証する
 *
 * 選択範囲の除去とカーソル位置への追記文字挿入と符号点単位のアンカー算出を検証する
 * 両フロントエンドが同じ送信内容を組み立てるための純粋関数の検査である
 */

// 共通の周辺テキストスナップショット生成規則を検証する
//
// 位置の単位は符号点であり、カーソルとアンカーの大小関係から選択範囲を除去して
// 追記文字をカーソル位置へ挿入し、アンカーを追記文字の符号点数だけ進める
//
// 不正なUTF-8や空文字列は周辺テキスト無しと同じ扱いになることを確認する
// hazkey-community-server、ソケット、フロントエンドのツールキットは使用しない
//
// hazkey-frontend-commonへ登録するため、IBus単独ビルドでも実行される

#include "surrounding_text_snapshot.h"
#include <iostream>
#include <string>

namespace {

using hazkey::frontend::buildSurroundingSnapshot;
using hazkey::frontend::SurroundingSnapshot;

int checks = 0;    ///< 検証した条件の総数
int failures = 0;  ///< 失敗した条件の総数

/**
 * @brief 生成結果が期待する文字列とアンカーに一致することを検証する
 *
 * 不一致の場合は、検証名と実際値と期待値を出力して失敗数を数える
 */
void expect(const std::string& label, const SurroundingSnapshot& got,
            const std::string& wantText, int wantAnchor) {
    ++checks;
    if (got.text != wantText || got.anchor != wantAnchor) {
        ++failures;
        std::cerr << "FAIL [" << label << "] got {text=\"" << got.text
                  << "\", anchor=" << got.anchor << "} want {text=\"" << wantText
                  << "\", anchor=" << wantAnchor << "}\n";
    }
}

/**
 * @brief 検証一件を実行し、その間に失敗が無ければ合格を報告する
 *
 * 検証名と条件の対応を出力へ残し、失敗時は不合格として報告する
 */
void runCase(const char* name, void (*body)()) {
    const int before = failures;
    body();
    if (failures == before) {
        std::cout << "[PASS] " << name << "\n";
    } else {
        std::cerr << "[FAIL] " << name << "\n";
    }
}

/**
 * @brief (a) 末尾カーソルかつ選択なしかつ追記なしでは入力と同一であることを検証する
 *
 * 追記が空でカーソルとアンカーが末尾を指すとき、生成結果が入力の全文とアンカーをそのまま返すことを確認する
 */
void testTailCursorNoSelectionNoAppend() {
    const auto kana = buildSurroundingSnapshot("あいうえお", 5, 5, "");
    expect("(a) kana tail identical", kana, "あいうえお", 5);

    const auto ascii = buildSurroundingSnapshot("abc", 3, 3, "");
    expect("(a) ascii tail identical", ascii, "abc", 3);
}

/**
 * @brief (b) 末尾カーソルへ追記すると末尾へ連結されアンカーが1進むことを検証する
 *
 * 今日の送信内容(textとappendの連結、anchorとappend符号点数の加算)と一致することを確認する
 */
void testTailCursorAppend() {
    const auto ascii = buildSurroundingSnapshot("abc", 3, 3, "X");
    expect("(b) ascii append at tail", ascii, "abcX", 4);

    const auto kana = buildSurroundingSnapshot("あい", 2, 2, "X");
    expect("(b) kana append at tail", kana, "あいX", 3);
}

/**
 * @brief (c) 文中カーソルへ追記するとその位置へ挿入されることを検証する
 *
 * 選択の無いカーソル位置(左3符号点、右2符号点)へ追記文字が入り、アンカーが追記後の位置になることを確認する
 */
void testMidCursorAppend() {
    const auto got = buildSurroundingSnapshot("あいうえお", 3, 3, "X");
    expect("(c) mid cursor insert", got, "あいうXえお", 4);
}

/**
 * @brief (d) 選択範囲が除去されカーソルとアンカーの大小によらず同じ結果になることを検証する
 *
 * 選択[1,3)の文字が結果に残らず、アンカーが選択開始位置と追記符号点数の和になることを確認する
 */
void testSelectionRemoved() {
    const auto cursorBeforeAnchor = buildSurroundingSnapshot("あいうえお", 1, 3, "X");
    expect("(d) cursor < anchor", cursorBeforeAnchor, "あXえお", 2);

    const auto cursorAfterAnchor = buildSurroundingSnapshot("あいうえお", 3, 1, "X");
    expect("(d) cursor > anchor", cursorAfterAnchor, "あXえお", 2);

    const auto asciiSelection = buildSurroundingSnapshot("abcdef", 1, 3, "");
    expect("(d) ascii selection no append", asciiSelection, "adef", 1);
}

/**
 * @brief (e) 結合絵文字の内部を分割しないことを検証する
 *
 * ZWJで結合した家族絵文字(5符号点)の直後をカーソルとするとき、左に絵文字全体が残り右に後続が残ることを確認する
 */
void testZwjEmojiSplit() {
    // 👨 ZWJ 👩 ZWJ 👧 はUTF-8で5符号点
    const std::string family =
        "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
    const auto got = buildSurroundingSnapshot(family + "abc", 5, 5, "");
    expect("(e) zwj family stays whole", got, family + "abc", 5);

    const auto appended = buildSurroundingSnapshot(family + "abc", 5, 5, "X");
    expect("(e) append after zwj family", appended, family + "Xabc", 6);
}

/**
 * @brief (f) 範囲外のカーソルとアンカーがクランプされることを検証する
 *
 * 負数と符号点数超過の両方をクランプして、選択範囲が全文除去や末尾挿入として扱われることを確認する
 */
void testClampOutOfRange() {
    const auto negative = buildSurroundingSnapshot("abc", -5, 100, "X");
    expect("(f) negative cursor, overflow anchor", negative, "X", 1);

    const auto overflow = buildSurroundingSnapshot("abc", 100, 100, "");
    expect("(f) overflow both", overflow, "abc", 3);

    const auto mixed = buildSurroundingSnapshot("あいう", -1, 1, "X");
    expect("(f) negative anchor", mixed, "Xいう", 1);
}

/**
 * @brief (g) 空文字列と不正UTF-8が空スナップショットを返すことを検証する
 *
 * 空入力と不正バイトを含む入力の双方で周辺テキスト無しと同じ結果になることを確認する
 */
void testEmptyAndInvalidUtf8() {
    const auto empty = buildSurroundingSnapshot("", 0, 0, "");
    expect("(g) empty text", empty, "", 0);

    const auto invalidText = buildSurroundingSnapshot("\xff", 0, 0, "X");
    expect("(g) invalid text byte", invalidText, "", 0);

    const auto invalidAppend = buildSurroundingSnapshot("abc", 1, 1, "\xff");
    expect("(g) invalid append byte", invalidAppend, "", 0);
}

/**
 * @brief (h) マルチバイトの追記でアンカーが符号点数だけ進むことを検証する
 *
 * 3バイト1符号点のかなを追記したとき、バイト数ではなく符号点数でアンカーが進むことを確認する
 */
void testMultibyteAppendAnchor() {
    const auto got = buildSurroundingSnapshot("ab", 2, 2, "あ");
    expect("(h) multibyte append anchor", got, "abあ", 3);

    const auto mid = buildSurroundingSnapshot("abcd", 2, 2, "あ");
    expect("(h) multibyte append mid", mid, "abあcd", 3);
}

}  // namespace

/**
 * @brief 全ての周辺テキストスナップショット検証を順に実行する
 *
 * (a)から(h)までの各条件を実行し、失敗が無ければ成功を報告して終了する
 */
int main() {
    runCase("(a) tail cursor, no selection, no append", testTailCursorNoSelectionNoAppend);
    runCase("(b) tail cursor with append", testTailCursorAppend);
    runCase("(c) mid cursor with append", testMidCursorAppend);
    runCase("(d) selection removal", testSelectionRemoved);
    runCase("(e) zwj emoji split", testZwjEmojiSplit);
    runCase("(f) clamp out of range", testClampOutOfRange);
    runCase("(g) empty and invalid utf8", testEmptyAndInvalidUtf8);
    runCase("(h) multibyte append anchor", testMultibyteAppendAnchor);

    std::cout << "surrounding_text_snapshot_test: " << checks << " checks, "
              << failures << " failures\n";
    if (failures == 0) {
        std::cout << "surrounding_text_snapshot_test: all checks passed\n";
        return 0;
    }
    std::cerr << "surrounding_text_snapshot_test: FAILED\n";
    return 1;
}

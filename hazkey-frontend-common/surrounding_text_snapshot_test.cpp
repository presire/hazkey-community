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
using hazkey::frontend::CompositionSurroundingFreeze;
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

/**
 * @brief (i) 組成開始時の周辺テキストが固定され、後から届くpreedit混入のライブ値に影響されないことを検証する
 *
 * Kateは組成中のpreeditを文書へ挿入して周辺テキストに含める
 * カーソルはpreedit先頭にあるため、ライブ値の右側へ読みが混入する
 * 固定後の送信内容は、組成開始時点の右文脈 (ここでは空) のままであることを確認する
 */
void testFreezeIgnoresPreeditContamination() {
    CompositionSurroundingFreeze freeze;
    expect("(i) first resolve uses live", freeze.resolve("こんにちは", 5, 5, ""),
           "こんにちは", 5);
    expect("(i) contaminated live ignored",
           freeze.resolve("こんにちはあいそれはゆ", 5, 5, ""), "こんにちは", 5);
    expect("(i) still frozen after more updates",
           freeze.resolve("こんにちはあいそれはゆめ", 5, 5, ""), "こんにちは", 5);
}

/**
 * @brief (j) 部分確定の追記が固定内容へ積み重なることを検証する
 *
 * 文節確定でappendした文字が固定内容のカーソル位置へ入り、以後の送信でも保持されることを確認する
 */
void testFreezeAccumulatesAppend() {
    CompositionSurroundingFreeze freeze;
    freeze.resolve("今日は", 3, 3, "");
    expect("(j) append inserts at frozen cursor",
           freeze.resolve("無視される", 0, 0, "愛"), "今日は愛", 4);
    expect("(j) append persists", freeze.resolve("無視される", 0, 0, ""),
           "今日は愛", 4);
}

/**
 * @brief (k) 右文脈が固定内容に保たれ、カーソルより後ろだけが右文脈として残ることを検証する
 *
 * 文中カーソルでの組成開始時の右側テキストが固定され、追記はカーソル位置へ入ることを確認する
 */
void testFreezeKeepsRightSide() {
    CompositionSurroundingFreeze freeze;
    expect("(k) mid cursor frozen", freeze.resolve("前後", 1, 1, ""), "前後", 1);
    expect("(k) append keeps right side",
           freeze.resolve("前ひらがな後", 1, 1, "X"), "前X後", 2);
}

/**
 * @brief (l) 開始時の選択範囲が除去された状態で固定されることを検証する
 *
 * 選択範囲を除去した内容と、選択開始位置のカーソルで固定され、以後も選択が復活しないことを確認する
 */
void testFreezeRemovesSelection() {
    CompositionSurroundingFreeze freeze;
    expect("(l) selection removed at freeze",
           freeze.resolve("あいうえお", 1, 3, ""), "あえお", 1);
    expect("(l) selection does not return",
           freeze.resolve("あいうえお", 1, 3, ""), "あえお", 1);
}

/**
 * @brief (m) 解除後は次の組成開始時にライブ値を取り直すことを検証する
 *
 * release()後は未固定へ戻り、新しいライブ値で固定し直されることを確認する
 */
void testFreezeReleaseRecapturesLive() {
    CompositionSurroundingFreeze freeze;
    ++checks;
    if (freeze.frozen()) {
        ++failures;
        std::cerr << "FAIL [(m) initially not frozen]\n";
    }
    freeze.resolve("古い", 2, 2, "");
    ++checks;
    if (!freeze.frozen()) {
        ++failures;
        std::cerr << "FAIL [(m) frozen after resolve]\n";
    }
    freeze.release();
    ++checks;
    if (freeze.frozen()) {
        ++failures;
        std::cerr << "FAIL [(m) not frozen after release]\n";
    }
    expect("(m) recaptures live after release",
           freeze.resolve("新しい文", 4, 4, ""), "新しい文", 4);
}

/**
 * @brief (n) コピーした固定状態を復元すると、リセットをまたいで引き継げることを検証する
 *
 * 確定直後に新しい組成を始める経路では、解除前の固定状態を戻して確定文字を追記する
 * 戻した状態が、解除前と同じ内容で動くことを確認する
 */
void testFreezeCopyCarriesAcrossRelease() {
    CompositionSurroundingFreeze freeze;
    freeze.resolve("今日は", 3, 3, "");
    const CompositionSurroundingFreeze carried = freeze;
    freeze.release();
    freeze = carried;
    expect("(n) carried freeze appends commit",
           freeze.resolve("preedit混入", 0, 0, "愛"), "今日は愛", 4);
}

/**
 * @brief (o) 組成開始時に周辺テキストが未着でも、空の内容で固定され後から届く混入値を採用しないことを検証する
 *
 * 初回の打鍵ではクライアントから周辺テキストが届いていないことがある
 * その後にpreedit混入済みの値が届いても、右文脈へ読みが入らないことを確認する
 */
void testFreezeEmptyWhenLiveNotYetArrived() {
    CompositionSurroundingFreeze freeze;
    expect("(o) first resolve without live text", freeze.resolve("", 0, 0, ""),
           "", 0);
    expect("(o) late contaminated live ignored",
           freeze.resolve("あ", 0, 0, ""), "", 0);
    expect("(o) append still accumulates", freeze.resolve("あい", 0, 0, "愛"),
           "愛", 1);
}

}  // namespace

/**
 * @brief 全ての周辺テキストスナップショット検証を順に実行する
 *
 * (a)から(o)までの各条件を実行し、失敗が無ければ成功を報告して終了する
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
    runCase("(i) freeze ignores preedit contamination", testFreezeIgnoresPreeditContamination);
    runCase("(j) freeze accumulates append", testFreezeAccumulatesAppend);
    runCase("(k) freeze keeps right side", testFreezeKeepsRightSide);
    runCase("(l) freeze removes selection", testFreezeRemovesSelection);
    runCase("(m) freeze release recaptures live", testFreezeReleaseRecapturesLive);
    runCase("(n) freeze copy carries across release", testFreezeCopyCarriesAcrossRelease);
    runCase("(o) freeze empty when live not yet arrived", testFreezeEmptyWhenLiveNotYetArrived);

    std::cout << "surrounding_text_snapshot_test: " << checks << " checks, "
              << failures << " failures\n";
    if (failures == 0) {
        std::cout << "surrounding_text_snapshot_test: all checks passed\n";
        return 0;
    }
    std::cerr << "surrounding_text_snapshot_test: FAILED\n";
    return 1;
}

/**
 * @file candidate_annotation_test.cpp
 * @brief 候補の注記の桁揃えで使う表示桁数の検証をまとめる
 *
 * 結合文字 (結合ダイアクリティカルマーク・同拡張・同補助・記号用・半角形) を幅0と数え、結合文字を含む表記でも注記の位置がずれないことを確認する
 * サーバやソケットやtoolkitを使用しない純粋関数の検査である
 */

#include "candidate_annotation.h"
#include <iostream>
#include <string>

namespace {

using hazkey::frontend::annotationGap;
using hazkey::frontend::displayColumns;

constexpr const char* kBaseGap = "\u3000\u3000";
constexpr const char* kHalfWidthSpace = "\u2002";

int failures = 0;

void expectColumns(const char* label, const std::string& text, int want) {
    const int got = displayColumns(text);
    if (got != want) {
        std::cerr << "FAIL [" << label << "] got " << got << " want " << want << "\n";
        ++failures;
    }
}

/**
 * @brief 既存の幅の規則 (半角1桁・全角2桁・既知の結合文字0桁) を確かめる
 */
void testBasicWidths() {
    expectColumns("ascii", "abc", 3);
    expectColumns("hiragana", "あい", 4);
    expectColumns("combining acute U+0301", "e\u0301", 1);
    expectColumns("dakuten U+3099", "か\u3099", 2);
    expectColumns("variation selector U+FE0F", "a\uFE0F", 1);
}

/**
 * @brief 結合文字の各ブロックの先頭と末尾を幅0と数えることを確かめる
 */
void testCombiningBlocksAreZeroWidth() {
    expectColumns("U+1AB0 extended first", "a\u1AB0", 1);
    expectColumns("U+1AFF extended last", "a\u1AFF", 1);
    expectColumns("U+1DC0 supplement first", "a\u1DC0", 1);
    expectColumns("U+1DFF supplement last", "a\u1DFF", 1);
    expectColumns("U+20D0 for symbols first", "a\u20D0", 1);
    expectColumns("U+20FF for symbols last", "a\u20FF", 1);
    expectColumns("U+FE20 half marks first", "a\uFE20", 1);
    expectColumns("U+FE2F half marks last", "a\uFE2F", 1);
    expectColumns("adjacent U+1AAF stays narrow", "a\u1AAF", 2);
    expectColumns("adjacent U+FE30 stays wide", "a\uFE30", 3);
}

/**
 * @brief 結合文字を含む表記も、同じ桁数の表記と同じ位置へ注記を揃えることを確かめる
 */
void testGapIgnoresCombiningMarks() {
    const std::string plain = annotationGap("ab", 3);
    const std::string combined = annotationGap("a\u20D7b\u1DC4", 3);
    if (combined != plain || plain != std::string(kHalfWidthSpace) + kBaseGap) {
        std::cerr << "FAIL [gap with combining marks]\n";
        ++failures;
    }
}

}  // namespace

int main() {
    testBasicWidths();
    testCombiningBlocksAreZeroWidth();
    testGapIgnoresCombiningMarks();
    if (failures > 0) {
        std::cerr << "candidate_annotation_test: " << failures << " failures\n";
        return 1;
    }
    std::cout << "candidate_annotation_test: OK\n";
    return 0;
}

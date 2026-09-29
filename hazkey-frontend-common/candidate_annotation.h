/**
 * @file candidate_annotation.h
 * @brief 候補の注記 (誤字の訂正候補の「*[訂正]*」) の位置揃えを提供する
 *
 * 候補UIは注記を表記の直後に続けて描画し、列を揃える手段を持たない
 * そのため表記の表示幅を全角 = 2桁・その他 = 1桁で数え、表記と注記の間の空白で最長の表記に揃える
 *
 * @note Fcitx 5、IBus、GLibの型を使わない純粋関数のみを置く
 * @note 桁数による近似のため、プロポーショナルフォントでは数ピクセルずれることがある
 */

#ifndef HAZKEY_CANDIDATE_ANNOTATION_H
#define HAZKEY_CANDIDATE_ANNOTATION_H

#include <string>
#include <string_view>

namespace hazkey::frontend {

/**
 * @brief UTF-8文字列の表示桁数を返す
 *
 * 東アジアの全角文字 (かな・漢字・全角英数・絵文字等) は2桁、結合文字等の幅を持たない文字は0桁、その他は1桁で数える
 *
 * @param utf8 UTF-8文字列 (不正なバイトは1桁として数える)
 * @return 表示桁数
 */
int displayColumns(std::string_view utf8);

/**
 * @brief 表記と注記の間に入れる空白を返す
 *
 * 表記をalignColumns桁まで空白で埋めた後に、全角空白2個の間隔を空ける
 * 2桁は全角空白 (U+3000)、端数の1桁はEN SPACE (U+2002) で埋める
 *
 * @param text 候補の表記
 * @param alignColumns 揃える表示桁数 (同じ候補一覧にある注記付き候補の表記の最大桁数)
 * @return 表記と注記の間の空白 (表記がalignColumns桁以上なら全角空白2個のみ)
 */
std::string annotationGap(std::string_view text, int alignColumns);

}  // namespace hazkey::frontend

#endif  // HAZKEY_CANDIDATE_ANNOTATION_H

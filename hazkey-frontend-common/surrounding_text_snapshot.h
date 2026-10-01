/**
 * @file surrounding_text_snapshot.h
 * @brief 周辺テキストの送信スナップショットを組み立てる純関数を提供する
 *
 * 選択範囲の除去と確定文字のカーソル位置挿入と符号点単位のアンカー算出を両フロントエンドで共有し、送信内容のずれを防ぐ
 *
 * 位置の単位はUnicode符号点である
 * Fcitx 5とIBusの周辺テキストはこの単位でカーソルとアンカーを報告する
 *
 * 不正なUTF-8は周辺テキスト無しと同じ扱いにする
 * 文脈として使えない壊れた文字列をそのまま送らないためである
 *
 * @note Fcitx 5、IBus、GLibの型を使わない純粋関数のみを置く
 */

#ifndef HAZKEY_SURROUNDING_TEXT_SNAPSHOT_H
#define HAZKEY_SURROUNDING_TEXT_SNAPSHOT_H

#include <string>

namespace hazkey::frontend {

/**
 * @brief サーバへ送る周辺テキストとアンカー位置の組
 */
struct SurroundingSnapshot {
    std::string text;  // 選択を除去し確定文字を挿入した周辺テキスト
    int anchor;        // カーソルまたは選択開始位置を表す符号点単位の位置
};

/**
 * @brief 周辺テキストとカーソルと選択範囲から送信用スナップショットを組み立てる
 *
 * cursorとanchorは符号点単位で[0, textの符号点数]へクランプする
 * lo = min(cursor, anchor)、hi = max(cursor, anchor)として、結果のtextはtextの[0, lo)とappendとtextの[hi, 末尾)を連結したものである
 * これにより、選択範囲[lo, hi)の文字は結果へ入らない
 * 結果のanchorは、loへappendの符号点数を加えた位置である
 *
 * カーソルが末尾で選択が無い場合は、今日の送信内容 (textへのappendの連結とanchorへのappend符号点数の加算) と一致する
 *
 * @param text 対象の周辺テキスト(符号点単位で解釈する)
 * @param cursor カーソル位置(符号点単位)
 * @param anchor 選択アンカー位置(符号点単位)
 * @param append カーソル位置へ挿入する確定文字列
 * @return 送信用スナップショット
 *
 * @note textまたはappendが不正なUTF-8なら空のスナップショット({"", 0})を返す
 * @note 空文字列は不正ではなく、空の周辺テキストとして扱う
 */
SurroundingSnapshot buildSurroundingSnapshot(const std::string& text, int cursor,
                                              int anchor,
                                              const std::string& append);

/**
 * @brief 組成中の周辺テキストを、組成開始時点の内容に固定する
 *
 * Kateなどは、組成中のpreeditを文書へ実際に挿入して周辺テキストに含めて報告する
 * カーソルはpreeditの先頭にあるため、そのまま送ると右文脈へ直前のpreedit (読みのひらがな) が混入し、
 * Zenzaiが右文脈に引きずられて変換しなくなる
 * 組成開始時にはpreeditが存在しないため、その時点の周辺テキストを組成が終わるまで使い続ける
 *
 * 初回のresolve()でライブの周辺テキストを取り込んで固定し、以後のresolve()は固定済みの内容へappendを積み重ねる
 * 部分確定でappendした確定文字は、固定済みのカーソル位置へ挿入されて保持される
 * 組成の終了時にrelease()を呼び、次の組成開始時にライブの周辺テキストを取り直す
 *
 * @note Fcitx 5、IBus、GLibの型を使わない純粋なクラスである
 */
class CompositionSurroundingFreeze {
   public:
    /**
     * @brief 送信用スナップショットを求めて、組成が終わるまで固定する
     *
     * 固定済みならlive*引数は無視して固定済みの内容を使う
     * 未固定ならlive*引数から求めた結果を固定する
     * 固定内容は選択範囲を除去した後の文字列で、カーソルとアンカーは同じ位置になる
     *
     * @param liveText ライブの周辺テキスト(未固定のときだけ使う)
     * @param liveCursor ライブのカーソル位置(符号点単位)
     * @param liveAnchor ライブのアンカー位置(符号点単位)
     * @param append カーソル位置へ挿入する確定文字列
     * @return 送信用スナップショット
     */
    SurroundingSnapshot resolve(const std::string& liveText, int liveCursor,
                                int liveAnchor, const std::string& append);

    /** @brief 固定を解除する。組成の終了時に呼ぶ */
    void release();

    /** @brief 固定済みか */
    bool frozen() const { return frozen_; }

   private:
    bool frozen_ = false;
    std::string text_;
    int cursor_ = 0;
};

}  // namespace hazkey::frontend

#endif  // HAZKEY_SURROUNDING_TEXT_SNAPSHOT_H

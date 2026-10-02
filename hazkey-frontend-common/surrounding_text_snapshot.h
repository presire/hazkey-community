/**
 * @file surrounding_text_snapshot.h
 * @brief 周辺テキストの送信スナップショットを組み立てる純関数を提供する
 *
 * 選択範囲の除去と確定文字のカーソル位置挿入と符号点単位のアンカー算出を両フロントエンドで共有して、送信内容のズレを防ぐ
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
 * Kate等のテキストエディタでは、組成中のpreeditを文書へ実際に挿入して周辺テキストに含めて報告する
 * カーソルはpreeditの先頭にあるため、そのまま送ると右文脈へ直前のpreedit (読みのひらがな) が混入して、Zenzaiが右文脈に引きずられて変換しなくなる
 * 組成開始時にはpreeditが存在しないため、その時点の周辺テキストを組成が終わるまで使用し続ける
 *
 * 初回のresolve()でライブの周辺テキストを取り込んで固定して、以後のresolve()は固定済みの内容へappendを積み重ねる
 * 部分確定でappendした確定文字は、固定済みのカーソル位置へ挿入されて保持される
 *
 * 組成の終了時 (確定・取消) は、finish()を呼ぶ
 * 確定直後のアプリの周辺テキストは確定を反映しておらず、Kateでは組成中のpreedit混入済みの値のままのことがある
 * そこで固定内容 (appendCommitted()で積んだ確定文字を含む) を次の組成へ持ち越し、終了時点のライブ値を併せて記録する
 *
 * 次の組成開始時のresolve()は、ライブ値が終了時点から変わっていなければ持ち越した内容を使用する
 * 変わっていても、確定より前に生成されて遅れて届いた値なら持ち越した内容を使用する
 *
 * 確定はカーソル位置へ挿入されるだけなので、カーソルより左が持ち越した内容の左側の真の先頭部分
 * (固定時のライブ値の左側以上の長さ) に留まる値は、まだ確定を反映していない
 *
 * ただし、選択範囲がある値と、文字列全体が持ち越した内容と一致する値 (確定を反映した上でカーソルが動いた値) はライブ値を使用する
 * それ以外は新しいライブ値を使用する
 * フォーカス移動等で持ち越しを捨てる時は、release()を呼ぶ
 *
 * @note Fcitx 5、IBus、GLibの型を使用しない純粋なクラスである
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
     * @param liveText ライブの周辺テキスト (未固定の時のみ使用する)
     * @param liveCursor ライブのカーソル位置 (符号点単位)
     * @param liveAnchor ライブのアンカー位置 (符号点単位)
     * @param append カーソル位置へ挿入する確定文字列
     * @return 送信用スナップショット
     */
    SurroundingSnapshot resolve(const std::string& liveText, int liveCursor,
                                int liveAnchor, const std::string& append);

    /**
     * @brief 確定した文字列を、固定済みまたは持ち越し中の内容のカーソル位置へ積む
     *
     * サーバへ送らずに確定する経路 ([Enter]等) で、次の組成の左文脈へ確定文字を残すために呼ぶ
     * 固定も持ち越しもしていなければ何もしない
     *
     * @param committed 確定した文字列
     */
    void appendCommitted(const std::string& committed);

    /**
     * @brief 組成の終了時に固定を解除して、固定内容を次の組成へ持ち越す
     *
     * 固定済みでライブの周辺テキストが利用可能なら、固定内容とこの時点のライブ値を記録して持ち越す
     * 持ち越し中なら、持ち越した内容 (その後にappendCommitted()で積んだ確定文字を含む) を保ち、記録するライブ値だけをこの時点の値へ更新する
     *
     * ライブの周辺テキストが利用できなければ、持ち越しも捨てる
     * 固定も持ち越しもしていなければ何もしない
     *
     * @param liveAvailable ライブの周辺テキストが利用可能か
     * @param liveText ライブの周辺テキスト
     * @param liveCursor ライブのカーソル位置(符号点単位)
     * @param liveAnchor ライブのアンカー位置(符号点単位)
     */
    void finish(bool liveAvailable, const std::string& liveText, int liveCursor,
                int liveAnchor);

    /** @brief 固定と持ち越しを捨てる。次の組成開始時はライブの周辺テキストを使用する */
    void release();

    /** @brief 固定済みか */
    bool frozen() const { return state_ == State::Frozen; }

   private:
    enum class State { Idle, Frozen, Carried };

    /** @brief 持ち越し中に届いたライブ値が、確定より前に生成された遅延値か */
    bool liveLagsBehindCarry(const std::string& liveText, int liveCursor,
                             int liveAnchor) const;

    State state_ = State::Idle;
    std::string text_;             // 固定内容または持ち越し内容
    int cursor_ = 0;               // text_内のカーソル位置 (符号点単位)
    int baseCursor_ = 0;           // 固定内容をライブ値から取り込んだ時点のカーソル位置 (確定文字を含まない)
    std::string carriedLiveText_;  // 持ち越し開始時点のライブの周辺テキスト
    int carriedLiveCursor_ = 0;    // 持ち越し開始時点のライブのカーソル位置
    int carriedLiveAnchor_ = 0;    // 持ち越し開始時点のライブのアンカー位置
};

}  // namespace hazkey::frontend

#endif  // HAZKEY_SURROUNDING_TEXT_SNAPSHOT_H

#ifndef FCITX5_HAZKEY_HAZKEY_CANDIDATE_H_
#define FCITX5_HAZKEY_HAZKEY_CANDIDATE_H_

#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/text.h>
#include <fcitx-utils/i18n.h>
#include <functional>
#include <string>
#include <vector>
#include "candidate_annotation.h"
#include "commands.pb.h"

namespace fcitx {

class HazkeyState;

/// 候補選択に使う数字キーを、候補表示順に並べた一覧
const KeyList defaultSelectionKeys = {
    Key{FcitxKey_1}, Key{FcitxKey_2}, Key{FcitxKey_3}, Key{FcitxKey_4},
    Key{FcitxKey_5}, Key{FcitxKey_6}, Key{FcitxKey_7}, Key{FcitxKey_8},
    Key{FcitxKey_9}, Key{FcitxKey_0},
};

/// サーバ候補をFcitx 5の候補項目として保持する
class HazkeyCandidateWord : public CandidateWord {
   public:
    /// 候補データと選択時の通知先を保持する
    /// @param index 候補一覧内のグローバル位置
    /// @param data サーバから受け取った候補
    /// @param selectCandidate 選択位置を通知する関数
    /// @param annotationAlignColumns 注記の位置を揃える表記の表示桁数 (一覧内の訂正候補の表記の最大桁数)
    HazkeyCandidateWord(const int index, const hazkey::commands::CandidatesResult_Candidate data, std::function<void(int)> selectCandidate,
                        int annotationAlignColumns = 0)
        : CandidateWord(Text(data.text())),
          index_(index),
          candidate_(std::move(data.text())),
          hiragana_(std::move(data.sub_hiragana())),
          hasLearningEntry_(data.has_learning_entry()),
          isTypoCorrection_(data.is_typo_correction()),
          selectCandidate_(std::move(selectCandidate)) {
        setText(Text(data.text()));
#ifdef HAZKEY_HAS_CANDIDATE_COMMENT
        // 誤字の訂正候補には注記を付ける (確定・preeditには表記だけを使う)
        // 表記との間隔は、一覧内の訂正候補で注記の位置が揃うように空白で埋めた後に全角空白2個で空け、翻訳文字列には含めない
        // 注記の色は入力メソッドから指定できず、Fcitx 5のテーマ (CandidateCommentColor) に従う
        // 注記「*[訂正]*」だけを斜体にする (classicui は斜体を描画し、Kimpanel 等は書式を捨てて文字列のみ表示する)
        if (isTypoCorrection_) {
            Text comment(hazkey::frontend::annotationGap(data.text(), annotationAlignColumns));
            comment.append(_("*[訂正]*"), TextFormatFlag::Italic);
            setComment(std::move(comment));
        }
#endif
    }

    /// ポインティングデバイスで候補が選択された時に呼び出される
    void select(InputContext* ic) const override;

    /// 候補の表記と、存在する場合は対応するひらがなを返す
    std::vector<std::string> getPreedit() const;
    /// 学習データを持つ候補かを返す
    bool hasLearningEntry() const { return hasLearningEntry_; }
    /// 誤字の訂正候補かを返す
    bool isTypoCorrection() const { return isTypoCorrection_; }

    // int correspondingCount() const { return corresponding_count_; }

   private:
    const int index_;                                           ///< 候補一覧内のグローバル位置
    const std::string candidate_;                               ///< 候補の表記
    const std::string hiragana_;                                ///< 候補に対応するひらがな
    const bool hasLearningEntry_;                               ///< 学習データの有無
    const bool isTypoCorrection_;                               ///< 誤字の訂正候補か
    const std::function<void(int)> selectCandidate_;            ///< 選択位置の通知先
    // const int corresponding_count_;
    // const std::vector<std::string> parts_;
    // const std::vector<int> part_lens_;
};

/// 候補ページ、カーソル、選択通知を管理するFcitx 5候補一覧
class HazkeyCandidateList : public CommonCandidateList {
   public:
    using SelectionHandler = std::function<void(int)>;

    /// サーバ候補から一覧を構築する
    HazkeyCandidateList(google::protobuf::RepeatedPtrField<
                        hazkey::commands::CandidatesResult_Candidate>
                            candidates);

    /// 候補UIのレイアウト方向を返す
    CandidateLayoutHint layoutHint() const override;

    /// ページ内位置にある候補を返す
    const HazkeyCandidateWord& getCandidate(int localIndex) const;

    /// 現在ページの有効な位置にカーソルを設定する
    void setCursorIndex(int localIndex);

    /// ページ内位置が実在する候補を指すかを返す
    /// @param pageSize 1ページの候補数
    /// @param totalSize 一覧全体の候補数
    /// @param currentPage 0始まりのページ番号
    /// @param localIndex ページ内の0始まり位置
    /// @return 指定位置が現在ページ内にあればtrue
    static bool pageLocalIndexInRange(int pageSize, int totalSize,
                                      int currentPage, int localIndex);

    /// グローバル位置の候補を選択して、通知先があれば通知する
    bool selectCandidate(int globalIndex);
    /// 候補選択時の通知先を設定する
    void setSelectionHandler(SelectionHandler selectionHandler);

    /// 次ページへ移動して、先頭候補にカーソルを置く
    void nextPage();
    /// 前ページへ移動して、先頭候補にカーソルを置く
    void prevPage();

    /// 一覧の先頭候補にカーソルを置く
    void focus();

    /// 一覧にカーソルがあるかを返す
    bool focused() const;

   private:
    SelectionHandler selectionHandler_; ///< 候補選択時の通知先
};

}  // namespace fcitx

#endif  // FCITX5_HAZKEY_HAZKEY_CANDIDATE_H_

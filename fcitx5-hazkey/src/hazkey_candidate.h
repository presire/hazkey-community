#ifndef FCITX5_HAZKEY_HAZKEY_CANDIDATE_H_
#define FCITX5_HAZKEY_HAZKEY_CANDIDATE_H_

#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/text.h>

#include <functional>
#include <string>
#include <vector>

#include "commands.pb.h"

namespace fcitx {

class HazkeyState;

const KeyList defaultSelectionKeys = {
    Key{FcitxKey_1}, Key{FcitxKey_2}, Key{FcitxKey_3}, Key{FcitxKey_4},
    Key{FcitxKey_5}, Key{FcitxKey_6}, Key{FcitxKey_7}, Key{FcitxKey_8},
    Key{FcitxKey_9}, Key{FcitxKey_0},
};

class HazkeyCandidateWord : public CandidateWord {
   public:
    HazkeyCandidateWord(
        const int index, const hazkey::commands::CandidatesResult_Candidate data,
        std::function<void(int)> selectCandidate)
        : CandidateWord(Text(data.text())),
          index_(index),
          candidate_(std::move(data.text())),
          hiragana_(std::move(data.sub_hiragana())),
          selectCandidate_(std::move(selectCandidate)) {
        setText(Text(data.text()));
    }

    // Called when the candidate is selected by a pointing device.
    void select(InputContext* ic) const override;

    std::vector<std::string> getPreedit() const;

    // int correspondingCount() const { return corresponding_count_; }

   private:
    const int index_;
    const std::string candidate_;
    const std::string hiragana_;
    const std::function<void(int)> selectCandidate_;
    // const int corresponding_count_;
    // const std::vector<std::string> parts_;
    // const std::vector<int> part_lens_;
};

class HazkeyCandidateList : public CommonCandidateList {
   public:
    using SelectionHandler = std::function<void(int)>;

    HazkeyCandidateList(google::protobuf::RepeatedPtrField<
                        hazkey::commands::CandidatesResult_Candidate>
                            candidates);

    // return the direction of the candidate list
    // currently always vertical
    CandidateLayoutHint layoutHint() const override;

    const HazkeyCandidateWord& getCandidate(int localIndex) const;

    // defined to support fcitx < 5.1.9
    // recent versions of fcitx provide this function as a default
    void setCursorIndex(int localIndex);

    // Select a displayed candidate by its global index.
    bool selectCandidate(int globalIndex);
    void setSelectionHandler(SelectionHandler selectionHandler);

    // set the cursor top of the next/prev page
    void nextPage();
    void prevPage();

    // show cursor on the candidate list
    void focus();

    // whether the candidate list is focused
    bool focused() const;

   private:
    SelectionHandler selectionHandler_;
};

}  // namespace fcitx

#endif  // FCITX5_HAZKEY_HAZKEY_CANDIDATE_H_

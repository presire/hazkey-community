#include "hazkey_candidate.h"

#include <vector>

#include "commands.pb.h"

namespace fcitx {

/// CandidateWord

std::vector<std::string> HazkeyCandidateWord::getPreedit() const {
    if (hiragana_.empty()) return {candidate_};
    return {candidate_, hiragana_};
}

void HazkeyCandidateWord::select(InputContext* ic) const {
    FCITX_UNUSED(ic);
    selectCandidate_(index_);
}

/// CandidateList

HazkeyCandidateList::HazkeyCandidateList(
    const google::protobuf::RepeatedPtrField<
        ::hazkey::commands::CandidatesResult_Candidate>
        candidates)
    : CommonCandidateList() {
    // CandidateWord needs to know their own index
    int i = 0;
    for (const auto& candidate : candidates) {
        append(std::make_unique<HazkeyCandidateWord>(
            i, candidate,
            [this](int globalIndex) { selectCandidate(globalIndex); }));
        i++;
    }
}

CandidateLayoutHint HazkeyCandidateList::layoutHint() const {
    return CandidateLayoutHint::Vertical;
}

void HazkeyCandidateList::focus() { setGlobalCursorIndex(0); }

const HazkeyCandidateWord& HazkeyCandidateList::getCandidate(
    int localIndex) const {
    return static_cast<const HazkeyCandidateWord&>(candidate(localIndex));
}

void HazkeyCandidateList::setCursorIndex(int localIndex) {
    if (localIndex < 0 || localIndex >= size()) {
        return;
    }
    int globalIndex = pageSize() * currentPage() + localIndex;
    setGlobalCursorIndex(globalIndex);
}

bool HazkeyCandidateList::selectCandidate(int globalIndex) {
    const int localIndex = globalIndex - pageSize() * currentPage();
    if (localIndex < 0 || localIndex >= size()) {
        return false;
    }
    setCursorIndex(localIndex);
    if (selectionHandler_) {
        selectionHandler_(globalIndex);
    }
    return true;
}

void HazkeyCandidateList::setSelectionHandler(
    SelectionHandler selectionHandler) {
    selectionHandler_ = std::move(selectionHandler);
}

void HazkeyCandidateList::nextPage() {
    next();
    setCursorIndex(0);
}

void HazkeyCandidateList::prevPage() {
    prev();
    setCursorIndex(0);
}

bool HazkeyCandidateList::focused() const { return (globalCursorIndex() >= 0); }

}  // namespace fcitx

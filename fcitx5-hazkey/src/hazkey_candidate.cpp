#include "hazkey_candidate.h"

#include <fcitx-utils/i18n.h>

#include <algorithm>
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
    // Fcitx's candidate UI pages through PageableCandidateList::next()/prev()
    // directly (mouse wheel / page arrows), bypassing nextPage()/prevPage().
    // Keep the cursor on the displayed page after such a page change: with the
    // default DonotChange the global cursor stays on the previous page, so
    // focused() remains true while cursorIndex() returns -1, and the next key
    // event's getCandidate(cursorIndex()) would throw. ResetToFirst also
    // matches nextPage()/prevPage(), which move to the top of the new page.
    setCursorPositionAfterPaging(CursorPositionAfterPaging::ResetToFirst);
}
CandidateLayoutHint HazkeyCandidateList::layoutHint() const {
    return CandidateLayoutHint::Vertical;
}

void HazkeyCandidateList::focus() { setGlobalCursorIndex(0); }

const HazkeyCandidateWord& HazkeyCandidateList::getCandidate(
    int localIndex) const {
    return static_cast<const HazkeyCandidateWord&>(candidate(localIndex));
}

bool HazkeyCandidateList::pageLocalIndexInRange(int pageSize, int totalSize,
                                                int currentPage,
                                                int localIndex) {
    if (pageSize <= 0 || totalSize <= 0 || currentPage < 0 || localIndex < 0) {
        return false;
    }
    // Reject a page past the end before multiplying. This matches the IBus
    // mapper (which derives the page from a validated cursor position) and
    // keeps `pageSize * currentPage` from overflowing for an extreme page.
    if (currentPage > (totalSize - 1) / pageSize) {
        return false;
    }
    const int pageStart = pageSize * currentPage;
    const int pageCount = std::min(pageSize, totalSize - pageStart);
    return localIndex < pageCount;
}

void HazkeyCandidateList::setCursorIndex(int localIndex) {
    // Bound by the candidates that actually exist on the current page rather
    // than by pageSize() or the list total: the final partial page must reject
    // its empty trailing slots. Returning early (instead of letting the base
    // class throw on a raw invalid index) keeps stale or out-of-range requests
    // a no-op.
    if (!pageLocalIndexInRange(pageSize(), totalSize(), currentPage(),
                               localIndex)) {
        return;
    }
    int globalIndex = pageSize() * currentPage() + localIndex;
    setGlobalCursorIndex(globalIndex);
}

bool HazkeyCandidateList::selectCandidate(int globalIndex) {
    const int localIndex = globalIndex - pageSize() * currentPage();
    if (!pageLocalIndexInRange(pageSize(), totalSize(), currentPage(),
                               localIndex)) {
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

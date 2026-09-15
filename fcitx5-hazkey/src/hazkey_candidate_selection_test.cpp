#include <cassert>
#include <limits>
#include <string>

#include "hazkey_candidate.h"

namespace {

google::protobuf::RepeatedPtrField<
    hazkey::commands::CandidatesResult_Candidate>
makeCandidates(int count) {
    google::protobuf::RepeatedPtrField<
        hazkey::commands::CandidatesResult_Candidate>
        candidates;
    for (int index = 0; index < count; ++index) {
        candidates.Add()->set_text(std::to_string(index));
    }
    return candidates;
}

google::protobuf::RepeatedPtrField<
    hazkey::commands::CandidatesResult_Candidate>
makeCandidatesWithLearningMetadata() {
    google::protobuf::RepeatedPtrField<
        hazkey::commands::CandidatesResult_Candidate>
        candidates;
    auto* learnedCandidate = candidates.Add();
    learnedCandidate->set_text("learned");
    learnedCandidate->set_has_learning_entry(true);
    candidates.Add()->set_text("ordinary");
    return candidates;
}

// Mirrors the IBus frontend's testMultiPageResolution(): a page-local slot is
// valid only when a candidate actually exists in it. The final partial page
// (13 candidates at 5 per page -> pages of 5 / 5 / 3) must reject slots 3/4.
void testPageLocalIndexInRangeMultiPage() {
    using fcitx::HazkeyCandidateList;
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 0, 0));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 0, 4));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 0, 5));

    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 0));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 2));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 4));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 5));

    // Final partial page: 3 real slots; slots 3/4 name absent candidates and
    // must not fall through to a later page.
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 0));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 2));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 3));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 4));

    // A page past the end exposes nothing rather than wrapping.
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 3, 0));
}

// Mirrors the IBus frontend's testServerPageShapes(): the server's non-suggest
// (page_size 9) and suggest (page_size 3) page shapes.
void testPageLocalIndexInRangeServerShapes() {
    using fcitx::HazkeyCandidateList;
    // Non-suggest conversion with 10 candidates: key "0" (local 9) is absent
    // from page 0, and page 1 holds a single candidate.
    assert(HazkeyCandidateList::pageLocalIndexInRange(9, 10, 0, 8));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(9, 10, 0, 9));
    assert(HazkeyCandidateList::pageLocalIndexInRange(9, 10, 1, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(9, 10, 1, 1));

    // Suggest list that exactly fills a single page.
    assert(HazkeyCandidateList::pageLocalIndexInRange(3, 3, 0, 2));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(3, 3, 0, 3));
}

// Mirrors the IBus frontend's testInvalidInput().
void testPageLocalIndexInRangeInvalidInput() {
    using fcitx::HazkeyCandidateList;
    assert(!HazkeyCandidateList::pageLocalIndexInRange(0, 5, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(-1, 5, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 0, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, -1, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 5, -1, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 5, 0, -1));

    // An extreme page must be rejected without overflowing `pageSize * page`.
    const int hugePage = std::numeric_limits<int>::max();
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, hugePage, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(10, 13, hugePage, 0));
}

// The list-level guarantee that backs the digit-selection gate: a digit naming
// an empty final-page slot is a no-op (no cursor move, no throw), while a real
// slot still selects.
void testFinalPageEmptySlotIsNoOp() {
    fcitx::HazkeyCandidateList candidates(makeCandidates(13));
    candidates.setPageSize(5);
    candidates.setPage(2);

    candidates.setCursorIndex(0);
    assert(candidates.globalCursorIndex() == 10);

    candidates.setCursorIndex(3);
    assert(candidates.globalCursorIndex() == 10);
    candidates.setCursorIndex(4);
    assert(candidates.globalCursorIndex() == 10);

    candidates.setCursorIndex(2);
    assert(candidates.globalCursorIndex() == 12);
}

// Fcitx's candidate UI (mouse wheel / page arrows) pages through
// PageableCandidateList::next()/prev() directly, bypassing
// HazkeyCandidateList::nextPage()/prevPage(). The list itself must therefore
// move the cursor onto the newly displayed page; otherwise focused() stays true
// while cursorIndex() is -1, and the next key event reads getCandidate(-1).
void testFocusedListStaysSelectableAfterPaging() {
    fcitx::HazkeyCandidateList candidates(makeCandidates(13));
    candidates.setPageSize(5);
    candidates.focus();
    assert(candidates.focused());
    assert(candidates.cursorIndex() == 0);

    candidates.toPageable()->next();
    assert(candidates.currentPage() == 1);
    assert(candidates.cursorIndex() == 0);
    assert(candidates.globalCursorIndex() == 5);
    // The cursor read performed after every key event is safe.
    (void)candidates.getCandidate(candidates.cursorIndex());

    candidates.toPageable()->next();
    assert(candidates.currentPage() == 2);
    assert(candidates.cursorIndex() == 0);
    assert(candidates.globalCursorIndex() == 10);
    (void)candidates.getCandidate(candidates.cursorIndex());
}

// An unfocused list (the suggest list before Tab/Down) has no cursor, and a
// UI page change must not invent one: ResetToFirst keeps it unselected.
void testUnfocusedListHasNoCursorAcrossPaging() {
    fcitx::HazkeyCandidateList candidates(makeCandidates(13));
    candidates.setPageSize(5);
    assert(candidates.cursorIndex() == -1);
    assert(!candidates.focused());

    candidates.toPageable()->next();
    assert(candidates.currentPage() == 1);
    assert(candidates.cursorIndex() == -1);
    assert(!candidates.focused());
}

}  // namespace

int main() {
    testPageLocalIndexInRangeMultiPage();
    testPageLocalIndexInRangeServerShapes();
    testPageLocalIndexInRangeInvalidInput();
    testFinalPageEmptySlotIsNoOp();
    testFocusedListStaysSelectableAfterPaging();
    testUnfocusedListHasNoCursorAcrossPaging();

    // Given: learned and ordinary candidates.
    fcitx::HazkeyCandidateList candidatesWithLearningMetadata(
        makeCandidatesWithLearningMetadata());

    // When: their learning metadata is inspected for focused-candidate UI.
    const auto& learnedCandidate = candidatesWithLearningMetadata.getCandidate(0);
    const auto& ordinaryCandidate = candidatesWithLearningMetadata.getCandidate(1);

    // Then: the read-only accessor matches server metadata. AuxDown owns the
    // focused-candidate affordance.
    assert(learnedCandidate.hasLearningEntry());
    assert(!ordinaryCandidate.hasLearningEntry());

    // Given: thirteen candidates displayed five at a time.
    fcitx::HazkeyCandidateList candidates(makeCandidates(13));
    candidates.setPageSize(5);

    // When: the first displayed candidate is selected by pointer.
    candidates.candidate(0).select(nullptr);

    // Then: its global index is selected.
    assert(candidates.globalCursorIndex() == 0);

    // Given: the second page is displayed.
    candidates.setPage(1);

    // When: its third displayed candidate is selected by pointer.
    candidates.candidate(2).select(nullptr);

    // Then: the cursor uses the global, rather than page-local, index.
    assert(candidates.globalCursorIndex() == 7);

    // Given: the final partial page is displayed.
    candidates.setPage(2);

    // When: its final displayed candidate is selected by pointer.
    candidates.candidate(2).select(nullptr);

    // Then: the final global index is selected.
    assert(candidates.globalCursorIndex() == 12);

    // Given: the cursor is on the final valid candidate.
    // When: an out-of-range global index is offered for selection.
    const bool selected = candidates.selectCandidate(13);

    // Then: selection is rejected and the cursor is unchanged.
    assert(!selected);
    assert(candidates.globalCursorIndex() == 12);

    return 0;
}

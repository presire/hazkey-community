#include <cassert>
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

}  // namespace

int main() {
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

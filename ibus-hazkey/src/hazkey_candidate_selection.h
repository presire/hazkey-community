#ifndef IBUS_HAZKEY_CANDIDATE_SELECTION_H
#define IBUS_HAZKEY_CANDIDATE_SELECTION_H

#include <algorithm>

namespace hazkey::ibus {

inline constexpr int kCandidateSelectionLabelCount = 10;

inline int clampCandidatePageSize(int pageSize) {
    return std::clamp(pageSize, 1, kCandidateSelectionLabelCount);
}

}

#endif

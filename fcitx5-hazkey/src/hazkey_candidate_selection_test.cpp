#include <cassert>
#include <limits>
#include <string>
#include "hazkey_candidate.h"

namespace {

/** 指定数の候補を連番テキストで生成する */
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

/** 学習情報の有無が異なる候補を生成する */
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

/** 訂正候補と通常候補を生成する */
google::protobuf::RepeatedPtrField<
    hazkey::commands::CandidatesResult_Candidate>
makeCandidatesWithTypoCorrection() {
    google::protobuf::RepeatedPtrField<
        hazkey::commands::CandidatesResult_Candidate>
        candidates;
    candidates.Add()->set_text("しっっぱいした");
    auto* corrected = candidates.Add();
    corrected->set_text("失敗した");
    corrected->set_is_typo_correction(true);
    return candidates;
}

/** 訂正候補だけが注記「*[訂正]*」を持ち (注記部分のみ斜体)、表記は変わらない
 *  (注記はFcitx 5.1.9以降のみ。それ以前は訂正フラグと表記だけを検証する) */
void testTypoCorrectionCandidateHasComment() {
    fcitx::HazkeyCandidateList candidates(makeCandidatesWithTypoCorrection());

    const auto& ordinary = candidates.getCandidate(0);
    const auto& corrected = candidates.getCandidate(1);

    assert(!ordinary.isTypoCorrection());
    assert(corrected.isTypoCorrection());
#ifdef HAZKEY_HAS_CANDIDATE_COMMENT
    assert(ordinary.comment().empty());
    // 表記との間隔として、全角空白2個を注記の先頭に付ける
    const auto& comment = corrected.comment();
    assert(comment.toString() == "\u3000\u3000*[訂正]*");
    // 間隔は通常書体、注記「*[訂正]*」だけが斜体
    assert(comment.size() == 2);
    assert(comment.stringAt(0) == "\u3000\u3000");
    assert(!(comment.formatAt(0) & fcitx::TextFormatFlag::Italic));
    assert(comment.stringAt(1) == "*[訂正]*");
    assert(comment.formatAt(1) & fcitx::TextFormatFlag::Italic);
#endif
    assert(corrected.text().toString() == "失敗した");
    assert(corrected.getPreedit().front() == "失敗した");
}

/** 複数の訂正候補の注記は、最も長い訂正候補の表記の後ろに揃う (通常候補の表記は揃える対象外) */
void testTypoCorrectionCommentsAreAligned() {
    google::protobuf::RepeatedPtrField<
        hazkey::commands::CandidatesResult_Candidate>
        data;
    data.Add()->set_text("m違える");
    for (const char* text : {"みちがえる", "間違える", "違える"}) {
        auto* corrected = data.Add();
        corrected->set_text(text);
        corrected->set_is_typo_correction(true);
    }
    data.Add()->set_text("mちがえる");
    fcitx::HazkeyCandidateList candidates(data);

#ifdef HAZKEY_HAS_CANDIDATE_COMMENT
    assert(candidates.getCandidate(0).comment().empty());
    assert(candidates.getCandidate(1).comment().stringAt(0) == "\u3000\u3000");
    assert(candidates.getCandidate(2).comment().stringAt(0) ==
           "\u3000\u3000\u3000");
    assert(candidates.getCandidate(3).comment().stringAt(0) ==
           "\u3000\u3000\u3000\u3000");
    assert(candidates.getCandidate(4).comment().empty());
    for (int i = 1; i <= 3; ++i) {
        const auto& comment = candidates.getCandidate(i).comment();
        assert(hazkey::frontend::displayColumns(
                   candidates.getCandidate(i).text().toString() +
                   comment.stringAt(0)) == 14);
        assert(comment.stringAt(1) == "*[訂正]*");
    }
#endif
    assert(candidates.getCandidate(2).text().toString() == "間違える");
}

/** 複数ページと末尾の不完全ページで、有効なページ内位置を判定する */
void testPageLocalIndexInRangeMultiPage() {
    using fcitx::HazkeyCandidateList;
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 0, 0));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 0, 4));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 0, 5));

    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 0));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 2));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 4));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 1, 5));

    /** 末尾ページに存在しない位置を拒否する */
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 0));
    assert(HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 2));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 3));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 2, 4));

    /** 範囲外ページが折り返さず、候補を持たないことを確認する */
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, 3, 0));
}

/** 通常変換とサジェストのページサイズで位置判定する */
void testPageLocalIndexInRangeServerShapes() {
    using fcitx::HazkeyCandidateList;
    /** 通常変換の最終ページが単一候補となる形を確認する */
    assert(HazkeyCandidateList::pageLocalIndexInRange(9, 10, 0, 8));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(9, 10, 0, 9));
    assert(HazkeyCandidateList::pageLocalIndexInRange(9, 10, 1, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(9, 10, 1, 1));

    /** サジェスト候補がページをちょうど満たす形を確認する */
    assert(HazkeyCandidateList::pageLocalIndexInRange(3, 3, 0, 2));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(3, 3, 0, 3));
}

/** 不正なページ寸法や位置および極端なページ番号を拒否する */
void testPageLocalIndexInRangeInvalidInput() {
    using fcitx::HazkeyCandidateList;
    assert(!HazkeyCandidateList::pageLocalIndexInRange(0, 5, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(-1, 5, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 0, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, -1, 0, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 5, -1, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 5, 0, -1));

    /** 極端なページ番号を安全に拒否する */
    const int hugePage = std::numeric_limits<int>::max();
    assert(!HazkeyCandidateList::pageLocalIndexInRange(5, 13, hugePage, 0));
    assert(!HazkeyCandidateList::pageLocalIndexInRange(10, 13, hugePage, 0));
}

/** 末尾ページの空き位置では選択せず、実在位置は選択する */
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

/** フォーカス中のページ移動後も候補カーソルを選択可能に保つ */
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
    /** ページ移動後にカーソル位置の候補を安全に取得できる */
    (void)candidates.getCandidate(candidates.cursorIndex());

    candidates.toPageable()->next();
    assert(candidates.currentPage() == 2);
    assert(candidates.cursorIndex() == 0);
    assert(candidates.globalCursorIndex() == 10);
    (void)candidates.getCandidate(candidates.cursorIndex());
}

/** 非フォーカスのページ移動でカーソルを新たに設定しない */
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

/** 候補ページ位置、カーソル状態、選択操作の振る舞いを確認する */
int main() {
    testPageLocalIndexInRangeMultiPage();
    testPageLocalIndexInRangeServerShapes();
    testPageLocalIndexInRangeInvalidInput();
    testFinalPageEmptySlotIsNoOp();
    testFocusedListStaysSelectableAfterPaging();
    testUnfocusedListHasNoCursorAcrossPaging();
    testTypoCorrectionCandidateHasComment();
    testTypoCorrectionCommentsAreAligned();

    /** 学習情報の読み取り専用アクセスが候補メタデータを反映する */
    fcitx::HazkeyCandidateList candidatesWithLearningMetadata(
        makeCandidatesWithLearningMetadata());

    const auto& learnedCandidate = candidatesWithLearningMetadata.getCandidate(0);
    const auto& ordinaryCandidate = candidatesWithLearningMetadata.getCandidate(1);

    assert(learnedCandidate.hasLearningEntry());
    assert(!ordinaryCandidate.hasLearningEntry());

    /** ポインタ選択時にページ内位置を全体位置へ変換する */
    fcitx::HazkeyCandidateList candidates(makeCandidates(13));
    candidates.setPageSize(5);

    candidates.candidate(0).select(nullptr);

    assert(candidates.globalCursorIndex() == 0);

    candidates.setPage(1);

    candidates.candidate(2).select(nullptr);

    assert(candidates.globalCursorIndex() == 7);

    /** 末尾の不完全ページでもポインタ選択を全体位置に反映する */
    candidates.setPage(2);

    candidates.candidate(2).select(nullptr);

    assert(candidates.globalCursorIndex() == 12);

    /** 範囲外の全体位置を拒否し現在の選択を維持する */
    const bool selected = candidates.selectCandidate(13);

    assert(!selected);
    assert(candidates.globalCursorIndex() == 12);

    return 0;
}

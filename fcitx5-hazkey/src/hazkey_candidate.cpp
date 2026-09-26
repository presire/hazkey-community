#include "hazkey_candidate.h"
#include <fcitx-utils/i18n.h>
#include <algorithm>
#include <vector>
#include "commands.pb.h"

namespace fcitx {

/// 候補の表示・選択処理

std::vector<std::string> HazkeyCandidateWord::getPreedit() const {
    if (hiragana_.empty()) return {candidate_};
    return {candidate_, hiragana_};
}

void HazkeyCandidateWord::select(InputContext* ic) const {
    FCITX_UNUSED(ic);
    selectCandidate_(index_);
}

/// 候補一覧のページ・カーソル処理

/// 候補項目を生成して、ページ移動後のカーソル位置を初期化する
HazkeyCandidateList::HazkeyCandidateList(
    const google::protobuf::RepeatedPtrField<
        ::hazkey::commands::CandidatesResult_Candidate>
        candidates)
    : CommonCandidateList() {
    // 候補項目が自身の位置を参照できるようにする
    int i = 0;
    for (const auto& candidate : candidates) {
        append(std::make_unique<HazkeyCandidateWord>(
            i, candidate,
            [this](int globalIndex) { selectCandidate(globalIndex); }));
        i++;
    }

    // 候補UIは、マウスホイールやページ移動キーで next() / prev()を直接呼び出し、nextPage() / prevPage()を経由しない
    // ページ移動後もカーソルを表示中ページに置く
    //
    // DonotChangeではカーソルが前ページに残り、focused()がtrueのまま、cursorIndex()が-1となるため、次のキー処理でgetCandidate()が失敗する
    // ResetToFirstは、nextPage() / prevPage()と同様に新しいページの先頭へ移動する
    setCursorPositionAfterPaging(CursorPositionAfterPaging::ResetToFirst);
}
/// 候補一覧を縦方向に表示する
CandidateLayoutHint HazkeyCandidateList::layoutHint() const {
    return CandidateLayoutHint::Vertical;
}

/// 一覧の先頭候補にカーソルを合わせる
void HazkeyCandidateList::focus() { setGlobalCursorIndex(0); }

/// ページ内位置の候補を型付きで返す
const HazkeyCandidateWord& HazkeyCandidateList::getCandidate(
    int localIndex) const {
    return static_cast<const HazkeyCandidateWord&>(candidate(localIndex));
}

/// 指定されたページ内位置が実在候補の範囲か判定する
bool HazkeyCandidateList::pageLocalIndexInRange(int pageSize, int totalSize, int currentPage, int localIndex) {
    if (pageSize <= 0 || totalSize <= 0 || currentPage < 0 || localIndex < 0) {
        return false;
    }
    // 乗算前に末尾を越えるページを拒否する
    // 有効なカーソル位置からページ番号を求めるIBus側の処理と整合して、極端なページ番号によるpageSize * currentPageのオーバーフローも防ぐ
    if (currentPage > (totalSize - 1) / pageSize) {
        return false;
    }
    const int pageStart = pageSize * currentPage;
    const int pageCount = std::min(pageSize, totalSize - pageStart);
    return localIndex < pageCount;
}

/// 有効なページ内位置だけカーソルへ反映する
void HazkeyCandidateList::setCursorIndex(int localIndex) {
    // pageSize()や一覧全体の数ではなく、現在のページに実在する候補数で検証する
    // 最終ページの空きスロットは選択対象にしない
    // 基底クラスに不正な位置を渡して例外にせず、古い要求や範囲外の要求を無視する
    if (!pageLocalIndexInRange(pageSize(), totalSize(), currentPage(), localIndex)) {
        return;
    }

    int globalIndex = pageSize() * currentPage() + localIndex;
    setGlobalCursorIndex(globalIndex);
}

/// 候補位置を検証して選択通知を行う
bool HazkeyCandidateList::selectCandidate(int globalIndex) {
    const int localIndex = globalIndex - pageSize() * currentPage();
    if (!pageLocalIndexInRange(pageSize(), totalSize(), currentPage(), localIndex)) {
        return false;
    }

    setCursorIndex(localIndex);

    if (selectionHandler_) {
        selectionHandler_(globalIndex);
    }
    return true;
}

/// 選択通知関数を保持する
void HazkeyCandidateList::setSelectionHandler(
    SelectionHandler selectionHandler) {
    selectionHandler_ = std::move(selectionHandler);
}

/// 次ページへ進み、先頭候補を選択する
void HazkeyCandidateList::nextPage() {
    next();
    setCursorIndex(0);
}

/// 前ページへ戻り、先頭候補を選択する
void HazkeyCandidateList::prevPage() {
    prev();
    setCursorIndex(0);
}

/// カーソルが一覧内にあるかを返す
bool HazkeyCandidateList::focused() const { return (globalCursorIndex() >= 0); }

}  // namespace fcitx

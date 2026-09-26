/**
 * @file candidate_refresh_coalescer.h
 * @brief 表示専用の候補更新要求をまとめる判定を提供する
 *
 * 先頭の要求はすぐに実行する
 * 連続入力中の後続要求は、最新の要求を1回だけ実行するようにまとめる
 *
 * 本方針はタイマも時計も持たない
 *
 * 呼び出し側が渡す時刻だけを見て判定する
 * 実際のタイマはフロントエンドの状態側が所有し駆動する
 */

#ifndef _HAZKEY_FRONTEND_COMMON_CANDIDATE_REFRESH_COALESCER_H_
#define _HAZKEY_FRONTEND_COMMON_CANDIDATE_REFRESH_COALESCER_H_

#include <cstdint>

namespace hazkey::frontend {

/**
 * @brief 表示専用更新を遅延させる最小間隔を示す定数[us]
 *
 * フロントエンドで使う既定値を1箇所にまとめる
 * テストでは、shouldScheduleやshouldFireへ小さい値を直接渡せる
 *
 * @note 方針自体はこの定数を参照しない
 * @note 呼び出し側が既定値として使うための提案値である
 */
inline constexpr uint64_t kCandidateRefreshCoalesceUsec = 30000;  ///< 30ms相当

/**
 * @class CandidateRefreshCoalescer
 * @brief 連続する表示専用候補更新要求をまとめる純粋な判定クラス
 *
 * @details 先頭の要求はすぐに実行する
 *          後続の要求は期限を更新し、最新の要求だけを遅延実行する
 *          最初の更新を遅らせず、連続入力中の描画負荷だけを抑える
 *
 *          タイマも時計も持たない
 *          呼び出し側が渡す時刻だけを記録する
 *          実際のタイマはフロントエンドの状態側が所有し駆動する
 *          本クラスは即時実行、再スケジュール、実行時刻到達だけを判定する
 *
 *          呼び出し側の典型手順は次のとおりである
 *          - 要求時は、shouldRunImmediatelyで即時可否を判定する
 *          - 実行可能ならタイマを取り消し、onRun後に同期実行する
 *          - 実行できなければ、shouldScheduleで期限を更新する
 *          - タイマイベント開始時は、shouldFireを確認してからonRun後に最新要求を実行する
 *          - 破棄時は、onCancelまたはresetPolicyで保留状態を消す
 *
 * @note 表示専用更新だけを対象とし確定処理には使用しない
 * @note 時刻は呼び出し側が単調増加する値[us]で渡すこと
 */
class CandidateRefreshCoalescer {
   public:
    /**
     * @brief 先頭の要求をすぐに実行できるか判定する
     *
     * 保留要求がなく、前回実行から最小間隔以上が経過した場合だけtrueを返す
     * 保留中はタイマが次の実行を管理する
     *
     * @param nowUsec 現在時刻[us]
     * @param minIntervalUsec 最小間隔[us]
     * @return 即時実行できる場合は真
     *
     * @note 実行の前後でonRunとonRunFinishedを呼ぶこと
     */
    bool shouldRunImmediately(uint64_t nowUsec, uint64_t minIntervalUsec) const {
        if (pending_) {
            return false;
        }
        if (!hasRun_) {
            return true;
        }
        return nowUsec - lastRunUsec_ >= minIntervalUsec;
    }

    /**
     * @brief 要求を受けて保留中の実行期限を更新する
     *
     * 期限を現在時刻と最小間隔から計算し直す
     * 最新の要求だけを残すことで、連続入力を1回の更新にまとめる
     *
     * @param nowUsec 現在時刻[us]
     * @param minIntervalUsec 最小間隔[us]
     * @return 常に真
     *
     * @note 呼び出し側は、実際のタイマを新しい期限へ設定し直す
     * @note 戻り値は、将来の意味変更に備えて明示するものである
     * @note 即時実行可否の判定には使用しないこと
     */
    bool shouldSchedule(uint64_t nowUsec, uint64_t minIntervalUsec) {
        lastRequestUsec_ = nowUsec;
        pendingDeadlineUsec_ = nowUsec + minIntervalUsec;
        pending_ = true;
        return true;
    }

    /**
     * @brief 保留中の更新を今実行すべきか判定する
     *
     * 保留がなく発火済みまたは取消済みまたは未設定の場合は偽を返す
     * 期限未到達の早すぎる呼び出しにも偽を返す
     *
     * @param nowUsec 現在時刻[us]
     * @return 今実行すべき場合は真
     *
     * @note 古いタイマ呼び出しに対する防御であり、通常は到達しない経路である
     */
    bool shouldFire(uint64_t nowUsec) const {
        return pending_ && nowUsec >= pendingDeadlineUsec_;
    }

    /**
     * @brief 保留状態を消費して実行開始時刻を記録する
     *
     * 先頭同期実行と後方タイマ実行の双方で呼ぶこと
     * 次の最小間隔は、この実行時刻から測る
     *
     * @param nowUsec 実行開始時刻[us]
     */
    void onRun(uint64_t nowUsec) {
        pending_ = false;
        hasRun_ = true;
        lastRunUsec_ = nowUsec;
    }

    /**
     * @brief 最小間隔の基準を実行終了時刻へ更新する
     *
     * 変換完了直後に呼ぶこと
     * 変換が最小間隔より長くなる場合でも、待機中の要求を1回の遅延更新にまとめる
     *
     * @param nowUsec 実行終了時刻[us]
     *
     * @note 実行中にresetPolicyされた場合は何もしない
     * @note 新しい合成の先頭即時実行を保つためである
     */
    void onRunFinished(uint64_t nowUsec) {
        if (hasRun_ && nowUsec > lastRunUsec_) {
            lastRunUsec_ = nowUsec;
        }
    }

    /**
     * @brief 保留中の更新を実行せずに取り消す
     *
     * 再スケジュール時やフォーカスを失った時に使用する
     * 何度呼んでも同じ結果になる
     *
     * @note resetPolicyと保留消去の効果は同じである
     * @note 呼び出し箇所の意図を明確にする別名として残す
     */
    void onCancel() { pending_ = false; }

    /**
     * @brief 判定に使う全状態を初期化する
     *
     * 保留状態と実行履歴を消す
     * 新しい入力では最初の更新を遅延させない
     *
     * @note 古い時刻が次回判定に影響しないようにする
     */
    void resetPolicy() {
        pending_ = false;
        pendingDeadlineUsec_ = 0;
        lastRequestUsec_ = 0;
        hasRun_ = false;
        lastRunUsec_ = 0;
    }

    /**
     * @brief 主に単体テスト向けの内部状態参照を提供する
     *
     * 以下5件は、判定結果の確認用である
     * 製品側の通常経路では使用しない
     */

    /** @brief 保留要求があるかどうかを返す */
    bool hasPending() const { return pending_; }
    /** @brief 保留期限を返す (マイクロ秒単位) */
    uint64_t pendingDeadlineUsec() const { return pendingDeadlineUsec_; }
    /** @brief 最終要求時刻を返す (マイクロ秒単位) */
    uint64_t lastRequestUsec() const { return lastRequestUsec_; }
    /** @brief 実行履歴があるかどうかを返す */
    bool hasRun() const { return hasRun_; }
    /** @brief 最終実行時刻を返す (マイクロ秒単位) */
    uint64_t lastRunUsec() const { return lastRunUsec_; }

   private:
    // 保留中の更新
    bool pending_ = false;              ///< 保留中の要求がある場合はtrue
    uint64_t pendingDeadlineUsec_ = 0;  ///< 保留中の実行期限[us]
    uint64_t lastRequestUsec_ = 0;      ///< 最終要求時刻[us]

    // 実行履歴
    bool hasRun_ = false;               ///< 実行履歴がある場合はtrue
    uint64_t lastRunUsec_ = 0;          ///< 最終実行時刻[us]
};

}  // namespace hazkey::frontend

#endif  // _HAZKEY_FRONTEND_COMMON_CANDIDATE_REFRESH_COALESCER_H_

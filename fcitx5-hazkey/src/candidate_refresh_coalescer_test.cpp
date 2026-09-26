#include <cassert>
#include <iostream>
#include "candidate_refresh_coalescer.h"

using hazkey::frontend::CandidateRefreshCoalescer;

/** 候補更新の即時実行とデバウンス状態遷移を確認する */
int main() {
    /** 初回要求を遅延させず即時実行する動作を確認する */
    {
        CandidateRefreshCoalescer c;
        assert(c.shouldRunImmediately(/*nowUsec=*/ 0, /*minIntervalUsec=*/ 30000));
        c.onRun(0);
        assert(!c.hasPending());
        assert(c.hasRun());
        assert(c.lastRunUsec() == 0);
        std::cout << "[PASS] first request runs immediately (leading edge)\n";
    }

    /** 前回実行後の待機期間内の要求を保留する動作を確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        assert(!c.shouldRunImmediately(29999, 30000));
        bool shouldArm = c.shouldSchedule(/*nowUsec=*/29999, 30000);
        assert(shouldArm);
        assert(c.hasPending());
        assert(c.pendingDeadlineUsec() == 59999);
        std::cout << "[PASS] request inside the quiet period defers to the "
                     "trailing timer\n";
    }

    /** 待機期間経過後の要求を再び即時実行する動作を確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        assert(c.shouldRunImmediately(30000, 30000));
        assert(c.shouldRunImmediately(150000, 30000));
        std::cout << "[PASS] request after the quiet period runs immediately "
                     "again\n";
    }

    /** 保留中は期限付きタイマーが次の実行を担うことを確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(10000, 30000);
        assert(c.hasPending());
        /** 待機期間経過後も保留状態を優先し二重実行を防ぐ */
        assert(!c.shouldRunImmediately(999999, 30000));
        std::cout << "[PASS] pending refresh blocks an immediate run\n";
    }

    /** 連続要求で期限を最新要求に合わせて更新する動作を確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(1000, 30000);
        assert(c.pendingDeadlineUsec() == 31000);
        bool shouldArmAgain = c.shouldSchedule(/*nowUsec=*/5000, 30000);
        assert(shouldArmAgain);
        assert(c.hasPending());
        /** 連続要求が個別実行でなく最新期限の一度の実行にまとまることを確認する */
        assert(c.pendingDeadlineUsec() == 35000);
        assert(c.lastRequestUsec() == 5000);
        std::cout << "[PASS] rapid second request re-arms, latest-wins "
                     "deadline update\n";
    }

    /** 合成時刻を用いて、期限到達後に実行可能となることを確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        assert(!c.shouldFire(29999));
        assert(c.shouldFire(30000));
        assert(c.shouldFire(30001));  // 期限経過後も実行可能な状態を保つ
        std::cout << "[PASS] shouldFire only true once interval elapsed\n";
    }

    /** 保留実行後の時刻を、次の待機期間の基準にする動作を確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        assert(c.shouldFire(30000));
        c.onRun(30000);
        assert(!c.hasPending());
        assert(!c.shouldFire(30000));
        assert(!c.shouldFire(1000000));
        assert(c.lastRunUsec() == 30000);
        assert(!c.shouldRunImmediately(59999, 30000));
        assert(c.shouldRunImmediately(60000, 30000));
        std::cout << "[PASS] onRun consumes pending slot and rebases the "
                     "quiet period\n";
    }

    /** キャンセルとポリシー初期化の状態消去および初回即時実行を確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        assert(c.hasPending());
        c.onCancel();
        assert(!c.hasPending());
        /** キャンセルでは実行履歴を保持することを確認する */
        assert(c.hasRun());

        c.shouldSchedule(0, 30000);
        assert(c.hasPending());
        c.resetPolicy();
        assert(!c.hasPending());
        assert(c.pendingDeadlineUsec() == 0);
        assert(c.lastRequestUsec() == 0);
        assert(!c.hasRun());
        assert(c.lastRunUsec() == 0);
        /** 新しい入力期間では前期間の履歴にかかわらず初回更新を即時実行する */
        assert(c.shouldRunImmediately(0, 30000));
        std::cout << "[PASS] onCancel/resetPolicy clear pending state; "
                     "resetPolicy re-enables the leading edge\n";
    }

    /** スケジュール後のキャンセルで期限後の実行も抑止することを確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        c.onCancel();
        assert(!c.shouldFire(30000));
        assert(!c.shouldFire(1000000));
        std::cout << "[PASS] cancel after schedule prevents any later fire\n";
    }

    /** 更新処理が待機期間より長い場合、完了時刻基準で後続要求をまとめる */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.onRunFinished(250000);
        assert(c.lastRunUsec() == 250000);
        assert(!c.shouldRunImmediately(250001, 30000));
        c.shouldSchedule(250001, 30000);
        c.shouldSchedule(250002, 30000);
        assert(c.pendingDeadlineUsec() == 280002);
        assert(!c.shouldFire(280001));
        assert(c.shouldFire(280002));
        /** 完了から待機期間経過後の入力は遅延しないことを確認する */
        CandidateRefreshCoalescer slow;
        slow.onRun(0);
        slow.onRunFinished(250000);
        assert(slow.shouldRunImmediately(280000, 30000));
        std::cout << "[PASS] slow refresh rebases the quiet period on "
                     "completion\n";
    }

    /** 初期化後の完了通知が無効であり実行時刻が逆行しないことを確認する */
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.resetPolicy();
        c.onRunFinished(250000);
        assert(!c.hasRun());
        assert(c.lastRunUsec() == 0);
        assert(c.shouldRunImmediately(250001, 30000));

        CandidateRefreshCoalescer d;
        d.onRun(100000);
        d.onRunFinished(50000);
        assert(d.lastRunUsec() == 100000);
        std::cout << "[PASS] onRunFinished is a no-op after reset and "
                     "monotonic\n";
    }

    std::cout << "\nAll candidate refresh coalescer policy tests passed.\n";
    return 0;
}

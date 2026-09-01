#include <cassert>
#include <iostream>

#include "candidate_refresh_coalescer.h"

using fcitx::CandidateRefreshCoalescer;

int main() {
    // (a) first request schedules.
    {
        CandidateRefreshCoalescer c;
        bool shouldArm = c.shouldSchedule(/*nowUsec=*/0, /*minIntervalUsec=*/30000);
        assert(shouldArm);
        assert(c.hasPending());
        assert(c.pendingDeadlineUsec() == 30000);
        std::cout << "[PASS] first request schedules and arms at now+interval\n";
    }

    // (b) rapid second request before fire re-arms / keeps latest-wins
    // (pending deadline pushed out to the newest request).
    {
        CandidateRefreshCoalescer c;
        c.shouldSchedule(0, 30000);
        assert(c.pendingDeadlineUsec() == 30000);
        bool shouldArmAgain = c.shouldSchedule(/*nowUsec=*/5000, 30000);
        assert(shouldArmAgain);
        assert(c.hasPending());
        // Latest-wins: deadline is now relative to the SECOND request, not
        // the first -- proves rapid successive requests coalesce into one
        // later execution instead of firing once per request.
        assert(c.pendingDeadlineUsec() == 35000);
        assert(c.lastRequestUsec() == 5000);
        std::cout << "[PASS] rapid second request re-arms, latest-wins "
                     "deadline update\n";
    }

    // (c) shouldFire true only after interval elapsed (synthetic
    // timestamps).
    {
        CandidateRefreshCoalescer c;
        c.shouldSchedule(0, 30000);
        assert(!c.shouldFire(29999));
        assert(c.shouldFire(30000));
        assert(c.shouldFire(30001));  // still true after the deadline
        std::cout << "[PASS] shouldFire only true once interval elapsed\n";
    }

    // (d) onFire consumes the pending slot.
    {
        CandidateRefreshCoalescer c;
        c.shouldSchedule(0, 30000);
        assert(c.shouldFire(30000));
        c.onFire();
        assert(!c.hasPending());
        assert(!c.shouldFire(30000));
        assert(!c.shouldFire(1000000));
        std::cout << "[PASS] onFire consumes pending slot\n";
    }

    // (e) onCancel/resetPolicy clears pending state.
    {
        CandidateRefreshCoalescer c;
        c.shouldSchedule(0, 30000);
        assert(c.hasPending());
        c.onCancel();
        assert(!c.hasPending());

        c.shouldSchedule(0, 30000);
        assert(c.hasPending());
        c.resetPolicy();
        assert(!c.hasPending());
        assert(c.pendingDeadlineUsec() == 0);
        assert(c.lastRequestUsec() == 0);
        std::cout << "[PASS] onCancel/resetPolicy clear pending state\n";
    }

    // (f) a cancel after schedule prevents any later fire (models
    // reset/focus-out: no callback may execute after cancellation, even if
    // the deadline would otherwise have been reached).
    {
        CandidateRefreshCoalescer c;
        c.shouldSchedule(0, 30000);
        c.onCancel();
        assert(!c.shouldFire(30000));
        assert(!c.shouldFire(1000000));
        std::cout << "[PASS] cancel after schedule prevents any later fire\n";
    }

    std::cout << "\nAll candidate refresh coalescer policy tests passed.\n";
    return 0;
}

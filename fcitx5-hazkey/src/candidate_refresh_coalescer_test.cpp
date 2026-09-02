#include <cassert>
#include <iostream>

#include "candidate_refresh_coalescer.h"

using fcitx::CandidateRefreshCoalescer;

int main() {
    // (a) the very first request runs immediately (leading edge): nothing is
    // pending and no refresh has ever run, so there is nothing to coalesce
    // with and deferring would only add latency.
    {
        CandidateRefreshCoalescer c;
        assert(c.shouldRunImmediately(/*nowUsec=*/0, /*minIntervalUsec=*/30000));
        c.onRun(0);
        assert(!c.hasPending());
        assert(c.hasRun());
        assert(c.lastRunUsec() == 0);
        std::cout << "[PASS] first request runs immediately (leading edge)\n";
    }

    // (b) a request arriving within the quiet period after a run must NOT
    // run immediately -- that is the burst case the coalescer exists for.
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

    // (c) once the quiet period has fully elapsed since the last run, the
    // next request runs immediately again (ordinary typing speed never pays
    // the debounce delay).
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        assert(c.shouldRunImmediately(30000, 30000));
        assert(c.shouldRunImmediately(150000, 30000));
        std::cout << "[PASS] request after the quiet period runs immediately "
                     "again\n";
    }

    // (d) while a refresh is pending, no request may run immediately -- the
    // armed trailing timer owns the next execution.
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(10000, 30000);
        assert(c.hasPending());
        // Even far beyond the quiet period: pending wins, so the pending
        // slot cannot be executed twice.
        assert(!c.shouldRunImmediately(999999, 30000));
        std::cout << "[PASS] pending refresh blocks an immediate run\n";
    }

    // (e) rapid successive requests before fire re-arm / keep latest-wins
    // (pending deadline pushed out to the newest request).
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(1000, 30000);
        assert(c.pendingDeadlineUsec() == 31000);
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

    // (f) shouldFire true only after interval elapsed (synthetic
    // timestamps).
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        assert(!c.shouldFire(29999));
        assert(c.shouldFire(30000));
        assert(c.shouldFire(30001));  // still true after the deadline
        std::cout << "[PASS] shouldFire only true once interval elapsed\n";
    }

    // (g) onRun consumes the pending slot and records the execution time, so
    // the quiet period for the NEXT leading-edge decision is measured from
    // the trailing run too (one budget shared by both execution paths).
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

    // (h) onCancel/resetPolicy clears pending state; resetPolicy also clears
    // the run history so a new composition epoch starts with an immediate
    // refresh.
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        assert(c.hasPending());
        c.onCancel();
        assert(!c.hasPending());
        // onCancel keeps the run history (only the pending execution was
        // abandoned).
        assert(c.hasRun());

        c.shouldSchedule(0, 30000);
        assert(c.hasPending());
        c.resetPolicy();
        assert(!c.hasPending());
        assert(c.pendingDeadlineUsec() == 0);
        assert(c.lastRequestUsec() == 0);
        assert(!c.hasRun());
        assert(c.lastRunUsec() == 0);
        // New composition epoch: the first refresh must not be deferred even
        // though the previous epoch ran one at the same synthetic timestamp.
        assert(c.shouldRunImmediately(0, 30000));
        std::cout << "[PASS] onCancel/resetPolicy clear pending state; "
                     "resetPolicy re-enables the leading edge\n";
    }

    // (i) a cancel after schedule prevents any later fire (models
    // reset/focus-out: no callback may execute after cancellation, even if
    // the deadline would otherwise have been reached).
    {
        CandidateRefreshCoalescer c;
        c.onRun(0);
        c.shouldSchedule(0, 30000);
        c.onCancel();
        assert(!c.shouldFire(30000));
        assert(!c.shouldFire(1000000));
        std::cout << "[PASS] cancel after schedule prevents any later fire\n";
    }

    std::cout << "\nAll candidate refresh coalescer policy tests passed.\n";
    return 0;
}

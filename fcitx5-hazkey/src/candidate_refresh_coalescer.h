#ifndef _FCITX5_HAZKEY_CANDIDATE_REFRESH_COALESCER_H_
#define _FCITX5_HAZKEY_CANDIDATE_REFRESH_COALESCER_H_

#include <cstdint>

namespace fcitx {

// Default minimum quiet period (microseconds) a display-only candidate
// refresh request must go unanswered by a newer request before it is
// actually executed. Exposed as a named constant so production call sites
// have one obvious default, while tests can pass tiny synthetic values to
// `shouldSchedule`/`shouldFire` directly (the policy itself never reads this
// constant; it is only a suggested default for callers).
inline constexpr uint64_t kCandidateRefreshCoalesceUsec = 30000;  // 30ms

// Pure, dependency-free decision policy for coalescing rapid successive
// display-only candidate-refresh requests into a single execution
// ("latest-wins" debounce with a minimum quiet interval).
//
// This class holds NO timer, NO clock, and NO fcitx/protobuf types -- it
// only tracks timestamps supplied by the caller so it is fully unit
// testable with synthetic values. The actual fcitx5 event-loop timer is
// owned and driven by HazkeyState; this class only answers "should I
// (re)arm?" and "should I fire now?" questions.
//
// Typical caller usage (see HazkeyState::scheduleCandidateRefresh /
// HazkeyState::firePendingCandidateRefresh):
//   1. On every display-only refresh trigger, call shouldSchedule(now,
//      interval). If it returns true, (re)arm/replace the real timer so it
//      fires at now + interval (latest request always wins and pushes the
//      deadline out, which is what makes rapid keystrokes coalesce into one
//      execution instead of firing once per keystroke).
//   2. When the timer callback actually runs, call shouldFire(now) first.
//      If false, do nothing (defends against a stale callback that
//      shouldn't have run -- in practice this shouldn't happen because a
//      fresh schedule() replaces the owning std::unique_ptr<EventSourceTime>
//      before the old one could fire, but the check keeps the policy
//      correct even if that invariant is ever relaxed).
//   3. If shouldFire() was true, call onFire() to consume the pending slot,
//      then execute the latest pending refresh kind.
//   4. On reset/focus-out/state-teardown-adjacent paths, call onCancel() (or
//      resetPolicy(), which is equivalent) so no stale timer, once
//      explicitly disarmed by the caller, is considered pending anymore.
class CandidateRefreshCoalescer {
   public:
    // Called every time a display-only refresh is requested. Always
    // (re)arms: the pending deadline is set to `nowUsec + minIntervalUsec`,
    // discarding any earlier deadline -- this is the "latest-wins" part of
    // the debounce. Returns true to signal the caller should (re)arm the
    // real timer to that new deadline. The return value is always true by
    // design (every request is eligible to push the deadline out); it is
    // still returned as `bool`, rather than being `void`, so the decision is
    // explicit at each call site and the semantics can change in the future
    // without touching callers.
    bool shouldSchedule(uint64_t nowUsec, uint64_t minIntervalUsec) {
        lastRequestUsec_ = nowUsec;
        pendingDeadlineUsec_ = nowUsec + minIntervalUsec;
        pending_ = true;
        return true;
    }

    // Pure predicate for the timer callback: whether the pending refresh
    // should execute right now. False both when nothing is pending (already
    // fired/cancelled/never scheduled) and when the deadline has not been
    // reached yet (guards against a stale/early callback).
    bool shouldFire(uint64_t nowUsec) const {
        return pending_ && nowUsec >= pendingDeadlineUsec_;
    }

    // Marks the pending slot as consumed after the caller has executed the
    // refresh. Idempotent.
    void onFire() { pending_ = false; }

    // Marks the pending slot as cancelled without executing anything
    // (reset/focus-out path). Idempotent. Equivalent to resetPolicy() for
    // the pending flag, kept as a separate name for call-site clarity.
    void onCancel() { pending_ = false; }

    // Clears all policy state, including bookkeeping timestamps. Use on
    // reset/focus-out so no stale timestamp influences a later
    // shouldSchedule() call in a new composition epoch.
    void resetPolicy() {
        pending_ = false;
        pendingDeadlineUsec_ = 0;
        lastRequestUsec_ = 0;
    }

    // Introspection helpers, primarily for unit tests.
    bool hasPending() const { return pending_; }
    uint64_t pendingDeadlineUsec() const { return pendingDeadlineUsec_; }
    uint64_t lastRequestUsec() const { return lastRequestUsec_; }

   private:
    bool pending_ = false;
    uint64_t pendingDeadlineUsec_ = 0;
    uint64_t lastRequestUsec_ = 0;
};

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_CANDIDATE_REFRESH_COALESCER_H_

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
// display-only candidate-refresh requests ("leading-edge execution with a
// latest-wins trailing debounce").
//
// LEADING EDGE (why it exists): a purely trailing debounce delays EVERY
// refresh by the full quiet period, which at ordinary typing speed (well
// over one interval between keystrokes) adds that delay to the visible
// feedback of every single keystroke without ever coalescing anything --
// there is nothing to merge when keystrokes are already far apart. The
// first request of a burst therefore executes immediately, exactly as the
// uncoalesced call site did, and only requests that arrive while the
// previous refresh is still "fresh" are deferred and merged.
//
// This class holds NO timer, NO clock, and NO fcitx/protobuf types -- it
// only tracks timestamps supplied by the caller so it is fully unit
// testable with synthetic values. The actual fcitx5 event-loop timer is
// owned and driven by HazkeyState; this class only answers "can I run this
// right now?", "should I (re)arm?" and "should I fire now?" questions.
//
// Typical caller usage (see HazkeyState::scheduleCandidateRefresh /
// HazkeyState::firePendingCandidateRefresh):
//   1. On every display-only refresh trigger, call
//      shouldRunImmediately(now, interval) first. If it returns true, drop
//      any armed timer, call onRun(now) and execute the refresh
//      synchronously -- no added latency.
//   2. Otherwise call shouldSchedule(now, interval). If it returns true,
//      (re)arm/replace the real timer so it fires at now + interval (latest
//      request always wins and pushes the deadline out, which is what makes
//      rapid keystrokes coalesce into one execution instead of firing once
//      per keystroke).
//   3. When the timer callback actually runs, call shouldFire(now) first.
//      If false, do nothing (defends against a stale callback that
//      shouldn't have run -- in practice this shouldn't happen because a
//      fresh schedule() replaces the owning std::unique_ptr<EventSourceTime>
//      before the old one could fire, but the check keeps the policy
//      correct even if that invariant is ever relaxed).
//   4. If shouldFire() was true, call onRun(now) to consume the pending slot
//      and record the execution, then execute the latest pending refresh
//      kind.
//   5. On reset/focus-out/state-teardown-adjacent paths, call onCancel() (or
//      resetPolicy(), which also clears the leading-edge bookkeeping) so no
//      stale timer, once explicitly disarmed by the caller, is considered
//      pending anymore.
class CandidateRefreshCoalescer {
   public:
    // Leading-edge predicate: true when the caller may execute the refresh
    // right now instead of arming a timer. That is the case when nothing is
    // already pending (a pending request means we are mid-burst and the
    // trailing timer owns the next execution) AND no refresh has run within
    // the last `minIntervalUsec` (so executing now cannot exceed the
    // configured one-refresh-per-quiet-period budget).
    bool shouldRunImmediately(uint64_t nowUsec, uint64_t minIntervalUsec) const {
        if (pending_) {
            return false;
        }
        if (!hasRun_) {
            return true;
        }
        return nowUsec - lastRunUsec_ >= minIntervalUsec;
    }

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

    // Marks the pending slot as consumed AND records that a refresh actually
    // executed at `nowUsec`. Both execution paths (the leading-edge
    // synchronous one and the trailing timer one) must call this, because
    // shouldRunImmediately() measures the next quiet period from the last
    // recorded run -- that is what keeps the "at most one refresh per quiet
    // period" budget intact across both paths.
    void onRun(uint64_t nowUsec) {
        pending_ = false;
        hasRun_ = true;
        lastRunUsec_ = nowUsec;
    }

    // Marks the pending slot as cancelled without executing anything
    // (reset/focus-out path). Idempotent. Equivalent to resetPolicy() for
    // the pending flag, kept as a separate name for call-site clarity.
    void onCancel() { pending_ = false; }

    // Clears all policy state, including both the pending bookkeeping and
    // the leading-edge run history. Use on reset/focus-out so no stale
    // timestamp influences a later shouldRunImmediately()/shouldSchedule()
    // call in a new composition epoch -- the first refresh of a fresh
    // composition must never be deferred.
    void resetPolicy() {
        pending_ = false;
        pendingDeadlineUsec_ = 0;
        lastRequestUsec_ = 0;
        hasRun_ = false;
        lastRunUsec_ = 0;
    }

    // Introspection helpers, primarily for unit tests.
    bool hasPending() const { return pending_; }
    uint64_t pendingDeadlineUsec() const { return pendingDeadlineUsec_; }
    uint64_t lastRequestUsec() const { return lastRequestUsec_; }
    bool hasRun() const { return hasRun_; }
    uint64_t lastRunUsec() const { return lastRunUsec_; }

   private:
    bool pending_ = false;
    uint64_t pendingDeadlineUsec_ = 0;
    uint64_t lastRequestUsec_ = 0;
    bool hasRun_ = false;
    uint64_t lastRunUsec_ = 0;
};

}  // namespace fcitx

#endif  // _FCITX5_HAZKEY_CANDIDATE_REFRESH_COALESCER_H_

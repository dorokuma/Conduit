// Testable, side-effect-free state machine for converting conduit_vt's
// onTouchScroll line deltas into PageUp/PageDown page counts.
//
// The "app" widget uses this through the [TouchScrollCoalescer] class
// (it owns the Timer and side effects). The state-machine logic itself is
// pure, lives in static methods, and is exercised by the unit tests in
// `touch_scroll_coalescer_test.dart`.
//
// Why this exists:
// The previous inline implementation dropped small deltas (|delta| < 4)
// and converted every large delta into ceil(|delta|/35) full pages, so
// a single finger swipe could emit 10+ PageUp sequences. The remote
// pi TUI would queue each one, latency snowballed (5s → 90s), and the
// late-arriving PageUps overwrote the user's PageDown, locking the
// viewport at the top.
//
// The new model is "accumulate + throttled flush":
//   * The widget callback only adds to a signed pending-line counter
//     (clamped to ±[pendingClamp] to keep it bounded).
//   * Every 250ms the timer asks the coalescer how many full pages are
//     pending and emits at most [flushMaxPages] of them, leaving the
//     remainder in the counter.
//   * On gesture end, the widget asks the coalescer for the end-flush
//     decision and resets state.

/// Pure, side-effect-free page-count decision for a touch scroll coalescer.
///
/// See class doc on [TouchScrollCoalescer] for the full model.
class TouchScrollCoalescer {
  const TouchScrollCoalescer();

  /// Lines per PageUp/PageDown sequence (one "page" of scrollback).
  static const int linesPerPage = 35;

  /// Maximum number of pages the periodic timer is allowed to emit per tick.
  /// Keeps the remote side from being flooded: at 250ms tick, 2 pages
  /// gives a sustained ≈ 8 pages/second cap, which matches the remote
  /// pi TUI's render rate.
  static const int flushMaxPages = 2;

  /// Pending line counter upper bound (signed). Prevents an unbounded
  /// drag (or a runaway timer) from accumulating thousands of pending
  /// lines and then blasting them in a burst at the next tick.
  static const int pendingClamp = 140;

  /// Minimum pending line count at which a gesture-end flush should emit
  /// a final page. Aligned with the original "abs < 4" drop threshold so
  /// any non-trivial scroll still produces an effect on release, but tiny
  /// jitter doesn't.
  static const int endFlushThreshold = 4;

  /// Decision returned by [periodicFlush]: positive = emit that many
  /// PageUp pages, negative = PageDown, zero = nothing to do.
  int periodicFlush(int pending) {
    if (pending == 0) return 0;
    final pages = pending ~/ linesPerPage;
    if (pages == 0) return 0;
    if (pages.abs() > flushMaxPages) {
      return pages > 0 ? flushMaxPages : -flushMaxPages;
    }
    return pages;
  }

  /// Lines to subtract from the pending counter after a periodic flush
  /// that emitted [emitted] pages. [emitted] must come from
  /// [periodicFlush] (or be 0).
  int linesConsumedByFlush(int emitted) => emitted * linesPerPage;

  /// Decision returned by [endFlush]: the final page to emit on gesture
  /// end, or 0 to drop the remainder. Always 1 page (in the dominant
  /// direction) when the remainder crosses [endFlushThreshold].
  int endFlush(int pending) {
    if (pending.abs() < endFlushThreshold) return 0;
    return pending > 0 ? 1 : -1;
  }

  /// Clamp a (signed) accumulated line delta into the safe range.
  int clampPending(int value) =>
      value.clamp(-pendingClamp, pendingClamp);
}

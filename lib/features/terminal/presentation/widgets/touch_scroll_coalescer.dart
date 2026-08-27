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
//   * Every 160ms the timer asks the coalescer how many full pages are
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
  /// Tuned to roughly half a phone-height of rows: small enough to keep
  /// the visual scroll continuous under the finger, large enough that a
  /// single page of jumps doesn't feel like a stutter.
  static const int linesPerPage = 24;

  /// Maximum number of pages the periodic timer is allowed to emit per tick.
  /// At a 160ms tick, 3 pages gives a sustained 3*24/0.16 = 450 lines/s
  /// cap, well below the flood line (the remote pi TUI only digests
  /// ~50 line-level signals/s, so 450 lines/s in page-units is far under
  /// any queuing cliff) and noticeably smoother than the previous 2-page
  /// / 8-pages-per-second limit.
  static const int flushMaxPages = 3;

  /// Pending line counter upper bound (signed). Prevents an unbounded
  /// drag (or a runaway timer) from accumulating thousands of pending
  /// lines and then blasting them in a burst at the next tick.
  /// Lowered together with the smaller [linesPerPage] and shorter
  /// tick interval: at 4× the new pages/second we don't need to
  /// buffer four full screens worth of lag.
  static const int pendingClamp = 96;

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

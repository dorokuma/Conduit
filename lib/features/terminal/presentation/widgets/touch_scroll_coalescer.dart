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

  /// Per-tick cap for line-level signals (one signal = one line, the
  /// `ctrl+alt+up/down` binding on the server side). The server digests
  /// ~50 signals/s, distilled to a 160ms window that is 8 signals
  /// (50/0.16 ≈ 8). Anything above that is left in [pending] and falls
  /// back to page-level on the next tick (or the end flush), so we
  /// never exceed the server's flood line.
  static const int flushMaxLines = 8;

  /// The line-level cross-over: any pending magnitude below this is
  /// emitted as line-level signals, at or above it the remainder is
  /// emitted as pages. Aligned with [linesPerPage] so a single tick
  /// never mixes line-level and page-level output for the same
  /// remainder: 0–23 lines go out as line signals, 24+ lines go out
  /// as pages (after subtracting whatever line signals were already
  /// emitted, the rest rounds down to whole pages).
  static const int lineLevelCrossOver = linesPerPage;

  /// Decision bundle returned by [periodicFlushLines] for a single
  /// periodic tick. The "lines" field is the count of line-level
  /// signals to emit *this tick* (each represents one line of scroll);
  /// the "pages" field is the count of whole pages to emit *this tick*,
  /// using the same positive/negative sign convention as
  /// [periodicFlush] (positive = newer content, negative = older).
  ///
  /// The split is mutually exclusive: a tick either emits line-level
  /// signals (when the pending magnitude is below [lineLevelCrossOver]
  /// after the line cap is applied) or whole pages (when the remainder
  /// after the line cap still rounds to at least one full page). This
  /// keeps the wire format predictable: the server sees either N
  /// line-up/line-down signals or N page-up/page-down sequences, never
  /// a mix in the same tick.
  FlushDecision periodicFlushLines(int pending) {
    if (pending == 0) {
      return const FlushDecision(lines: 0, pages: 0);
    }
    final abs = pending.abs();
    final sign = pending.isNegative ? -1 : 1;

    if (abs < lineLevelCrossOver) {
      // Small displacement: emit line-level signals, capped at
      // flushMaxLines per tick. The remainder stays in the pending
      // counter for the next tick.
      final lines = abs < flushMaxLines ? abs : flushMaxLines;
      return FlushDecision(lines: lines * sign, pages: 0);
    }

    // Large displacement: consume the line-level cap first (cheap,
    // smooth), then round the rest down to whole pages (capped at
    // flushMaxPages so a saturated pending can't blow the tick).
    final pageLines = abs - flushMaxLines;
    final pages = pageLines ~/ linesPerPage;
    final cappedPages = pages < flushMaxPages ? pages : flushMaxPages;
    final emittedPages = cappedPages == 0 ? 0 : cappedPages;
    return FlushDecision(
      lines: flushMaxLines * sign,
      pages: emittedPages * sign,
    );
  }

  /// Lines to subtract from the pending counter after a periodic flush
  /// that emitted a [FlushDecision] from [periodicFlushLines]. The total
  /// is the absolute sum of line-level and page-level output, signed by
  /// the original pending direction.
  int linesConsumedByFlushDecision(FlushDecision decision) {
    return decision.lines.abs() + decision.pages.abs() * linesPerPage;
  }

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

/// Decision bundle returned by [TouchScrollCoalescer.periodicFlushLines].
/// A zero in both fields means "emit nothing this tick".
///
/// `lines` is signed (positive = new content direction, negative = old
/// content direction) so the caller can pick the right escape sequence.
/// `pages` follows the same convention.
class FlushDecision {
  const FlushDecision({required this.lines, required this.pages});

  final int lines;
  final int pages;

  bool get isEmpty => lines == 0 && pages == 0;

  @override
  bool operator ==(Object other) =>
      other is FlushDecision && other.lines == lines && other.pages == pages;

  @override
  int get hashCode => Object.hash(lines, pages);

  @override
  String toString() => 'FlushDecision(lines: $lines, pages: $pages)';
}

// Unit tests for the pure page-decision logic in [TouchScrollCoalescer].
//
// The widget-level integration tests in terminal_surface_test.dart
// exercise the timer / gesture-end wiring, but they can only assert on
// the captured output of a single `tester.drag` call. These tests pin
// down the actual accumulation contract that the bug fix relies on:
//   * small deltas that the old code dropped are now accumulated and
//     produce a single page on end-flush (15 × 1 lines → 1 PageUp);
//   * a large single delta emits at most [flushMaxPages] pages per
//     periodic tick and leaves the remainder for the next tick (or the
//     end flush);
//   * the clamp prevents a runaway drag from accumulating a huge
//     backlog that would then be blasted out in one tick.

import 'package:conduit/features/terminal/presentation/widgets/touch_scroll_coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const coalescer = TouchScrollCoalescer();

  group('TouchScrollCoalescer.clampPending', () {
    test('keeps values inside the safe range', () {
      expect(coalescer.clampPending(0), 0);
      expect(coalescer.clampPending(50), 50);
      expect(coalescer.clampPending(-50), -50);
    });

    test('saturates at the positive clamp', () {
      expect(
        coalescer.clampPending(TouchScrollCoalescer.pendingClamp + 50),
        TouchScrollCoalescer.pendingClamp,
      );
    });

    test('saturates at the negative clamp', () {
      expect(
        coalescer.clampPending(-TouchScrollCoalescer.pendingClamp - 50),
        -TouchScrollCoalescer.pendingClamp,
      );
    });
  });

  group('TouchScrollCoalescer.periodicFlush', () {
    test('emits nothing when pending is zero', () {
      expect(coalescer.periodicFlush(0), 0);
    });

    test('emits nothing when fewer than one full page is pending', () {
      // one line short of a full page.
      expect(coalescer.periodicFlush(TouchScrollCoalescer.linesPerPage - 1), 0);
      expect(coalescer.periodicFlush(-(TouchScrollCoalescer.linesPerPage - 1)), 0);
    });

    test('emits exactly one page when pending equals one full page', () {
      expect(coalescer.periodicFlush(TouchScrollCoalescer.linesPerPage), 1);
      expect(coalescer.periodicFlush(-TouchScrollCoalescer.linesPerPage), -1);
    });

    test('caps a multi-page tick at flushMaxPages to avoid flooding', () {
      // Three full pages plus a sliver exceeds flushMaxPages, so the
      // periodic flush caps at the configured maximum.
      const lines = TouchScrollCoalescer.linesPerPage *
              TouchScrollCoalescer.flushMaxPages +
          1;
      expect(
        coalescer.periodicFlush(lines),
        TouchScrollCoalescer.flushMaxPages,
      );
      // Five pages worth still caps at flushMaxPages.
      expect(
        coalescer.periodicFlush(
          TouchScrollCoalescer.linesPerPage *
              (TouchScrollCoalescer.flushMaxPages + 2),
        ),
        TouchScrollCoalescer.flushMaxPages,
      );
      // Same on the negative side.
      expect(
        coalescer.periodicFlush(
          -(TouchScrollCoalescer.linesPerPage *
              (TouchScrollCoalescer.flushMaxPages + 2)),
        ),
        -TouchScrollCoalescer.flushMaxPages,
      );
    });
  });

  group('TouchScrollCoalescer.endFlush', () {
    test('emits nothing for a non-trivial-but-small remainder', () {
      // 3 lines: under the end-flush threshold.
      expect(coalescer.endFlush(3), 0);
      expect(coalescer.endFlush(-3), 0);
    });

    test('emits one page when remainder crosses the threshold', () {
      expect(coalescer.endFlush(TouchScrollCoalescer.endFlushThreshold), 1);
      expect(coalescer.endFlush(TouchScrollCoalescer.linesPerPage), 1);
      expect(coalescer.endFlush(TouchScrollCoalescer.pendingClamp), 1);
      expect(coalescer.endFlush(-TouchScrollCoalescer.endFlushThreshold), -1);
      expect(coalescer.endFlush(-TouchScrollCoalescer.pendingClamp), -1);
    });

    test('emits nothing when the counter is already zero', () {
      expect(coalescer.endFlush(0), 0);
    });
  });

  group('15 × 1-line accumulation: simulates a slow finger drag', () {
    // Reproduces the bug scenario: 15 consecutive small deltas of 1
    // line each (every single one is below the old `abs < 4` drop
    // threshold). Under the old implementation every one of them
    // was dropped, so no PageUp was ever sent. With the new logic
    // the pending counter ends the gesture at 15 — below
    // [linesPerPage] but well above [endFlushThreshold] — so the
    // periodic flush stays silent and the end-flush emits exactly
    // one PageUp.
    test('15 small +1 deltas end up as a single PageUp via end flush', () {
      // Simulates a slow finger drag that never accumulates a full
      // page: 15 consecutive +1-line deltas. Under the old
      // implementation each was dropped (|delta| < 4), so no PageUp
      // was ever sent. With the new logic the pending counter ends
      // the gesture below [linesPerPage] (so the periodic flush
      // emits nothing yet) but well above [endFlushThreshold], so the
      // end-flush emits exactly one page.
      var pending = 0;
      for (var i = 0; i < 15; i++) {
        pending = coalescer.clampPending(pending + 1);
      }
      expect(pending, 15);
      // Pending is between endFlushThreshold and linesPerPage, so the
      // periodic flush is silent but the end flush fires.
      expect(
        pending.abs() < TouchScrollCoalescer.linesPerPage,
        isTrue,
      );
      expect(coalescer.periodicFlush(pending), 0);
      expect(coalescer.endFlush(pending), 1);
    });

    test('a flood of pendingClamp lines caps at flushMaxPages per tick', () {
      // A single onTouchScroll callback that saturates the pending
      // counter: the periodic flush must cap at flushMaxPages, not emit
      // pendingClamp / linesPerAge full pages in one go.
      const pending = TouchScrollCoalescer.pendingClamp;
      final firstTick = coalescer.periodicFlush(pending);
      expect(firstTick, TouchScrollCoalescer.flushMaxPages);

      // The remainder is left for the next periodic tick or the end
      // flush. The end flush emits the final page as long as the
      // remainder crosses endFlushThreshold.
      final remaining = pending - coalescer.linesConsumedByFlush(firstTick);
      expect(coalescer.endFlush(remaining), 1);
    });

    test('a 500-line flood is bounded across multiple ticks', () {
      // The previous implementation would have sent ceil(500/35) = 15
      // PageUps in a single tick. The new model splits that across
      // periodic ticks (each capped at flushMaxPages) plus 1 end-flush.
      var pending = 500;
      final perTickEmits = <int>[];
      while (pending.abs() >=
          TouchScrollCoalescer.endFlushThreshold) {
        final emit = coalescer.periodicFlush(pending);
        if (emit == 0) break;
        perTickEmits.add(emit);
        pending -= coalescer.linesConsumedByFlush(emit);
      }
      final end = coalescer.endFlush(pending);
      if (end != 0) perTickEmits.add(end);

      // All tick-level emits are within the cap.
      for (final e in perTickEmits) {
        expect(
          e.abs(),
          lessThanOrEqualTo(TouchScrollCoalescer.flushMaxPages),
        );
      }
      // The total page count is roughly pending/24 with the new tuning;
      // the upper bound stays well under an unbounded flood.
      expect(
        perTickEmits.fold<int>(0, (acc, e) => acc + e.abs()),
        inInclusiveRange(18, 23),
      );
    });
  });
}

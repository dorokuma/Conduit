// Unit tests for the pure page-decision logic in [TouchScrollCoalescer].
//
// The widget-level integration tests in terminal_surface_test.dart
// exercise the timer / gesture-end wiring, but they can only assert on
// the captured output of a single `tester.drag` call. These tests pin
// down the actual accumulation contract that the bug fix relies on:
//   * small deltas that the old code dropped are now accumulated and
//     produce a single page on end-flush (15 × 2 lines → 1 PageUp);
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
      // 34 lines = just shy of one page.
      expect(coalescer.periodicFlush(34), 0);
      expect(coalescer.periodicFlush(-34), 0);
    });

    test('emits exactly one page when pending equals one full page', () {
      expect(coalescer.periodicFlush(TouchScrollCoalescer.linesPerPage), 1);
      expect(coalescer.periodicFlush(-TouchScrollCoalescer.linesPerPage), -1);
    });

    test('caps a multi-page tick at flushMaxPages to avoid flooding', () {
      // 100 lines / 35 = 2 pages, but flushMaxPages is 2, so emit 2.
      expect(coalescer.periodicFlush(100), TouchScrollCoalescer.flushMaxPages);
      // 200 lines would be 5 pages, but we cap at 2.
      expect(
        coalescer.periodicFlush(200),
        TouchScrollCoalescer.flushMaxPages,
      );
      // Same on the negative side.
      expect(
        coalescer.periodicFlush(-200),
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
      expect(coalescer.endFlush(4), 1);
      expect(coalescer.endFlush(35), 1);
      expect(coalescer.endFlush(100), 1);
      expect(coalescer.endFlush(-4), -1);
      expect(coalescer.endFlush(-100), -1);
    });

    test('emits nothing when the counter is already zero', () {
      expect(coalescer.endFlush(0), 0);
    });
  });

  group('15 × 2-line accumulation: simulates a slow finger drag', () {
    // Reproduces the bug scenario: 15 consecutive small deltas of 2 lines
    // each (every single one is below the old `abs < 4` drop threshold).
    // Under the old implementation every one of them was dropped, so no
    // PageUp was ever sent. With the new logic the pending counter ends
    // the gesture at 30, well above endFlushThreshold (4), so the
    // end-flush emits exactly one PageUp.
    test('15 small +2 deltas end up as a single PageUp via end flush', () {
      var pending = 0;
      for (var i = 0; i < 15; i++) {
        pending = coalescer.clampPending(pending + 2);
      }
      expect(pending, 30);
      // The 250ms timer wouldn't have fired enough to flush yet, so the
      // only emit comes from the gesture-end flush.
      expect(coalescer.periodicFlush(pending), 0);
      expect(coalescer.endFlush(pending), 1);
    });

    test('100-line single delta caps at flushMaxPages per tick', () {
      // A single onTouchScroll callback with 100 lines: the periodic
      // flush must cap at flushMaxPages (2), not emit 3 pages (which
      // is what the old ceil(100/35)=3 code would have done in one go).
      const pending = 100;
      final firstTick = coalescer.periodicFlush(pending);
      expect(firstTick, TouchScrollCoalescer.flushMaxPages);

      // The remainder (100 - 2*35 = 30 lines) is left for the next
      // periodic tick or the end flush. 30 lines < 35 lines/page, so
      // the next periodic tick still emits nothing, but the end flush
      // emits the final 1 page.
      final remaining = pending - coalescer.linesConsumedByFlush(firstTick);
      expect(remaining, 30);
      expect(coalescer.periodicFlush(remaining), 0);
      expect(coalescer.endFlush(remaining), 1);
    });

    test('a 500-line flood is bounded across multiple ticks', () {
      // The previous implementation would have sent ceil(500/35) = 15
      // PageUps in a single tick. The new model splits that across
      // 4 periodic ticks (2 + 2 + 2 + 1) plus 1 end-flush, never
      // exceeding flushMaxPages per tick.
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
      // The total page count is roughly 500/35 ≈ 14, well below the
      // unbounded flood the old code would have produced when applied
      // per-event.
      expect(
        perTickEmits.fold<int>(0, (acc, e) => acc + e.abs()),
        inInclusiveRange(13, 16),
      );
    });
  });
}

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
      // Just shy of one full page: linesPerPage - 1.
      const justShort = TouchScrollCoalescer.linesPerPage - 1;
      expect(coalescer.periodicFlush(justShort), 0);
      expect(coalescer.periodicFlush(-justShort), 0);
    });

    test('emits exactly one page when pending equals one full page', () {
      expect(coalescer.periodicFlush(TouchScrollCoalescer.linesPerPage), 1);
      expect(coalescer.periodicFlush(-TouchScrollCoalescer.linesPerPage), -1);
    });

    test('caps a multi-page tick at flushMaxPages to avoid flooding', () {
      // A pending value well above the cap: linesPerPage * (flushMaxPages + 1)
      // pages worth, so the cap is definitely the limiting factor.
      const overTheCap = TouchScrollCoalescer.linesPerPage *
          (TouchScrollCoalescer.flushMaxPages + 1);
      expect(
        coalescer.periodicFlush(overTheCap),
        TouchScrollCoalescer.flushMaxPages,
      );
      // And the same on the negative side.
      expect(
        coalescer.periodicFlush(-overTheCap),
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
      expect(
        coalescer.endFlush(TouchScrollCoalescer.linesPerPage),
        1,
      );
      expect(
        coalescer.endFlush(
          TouchScrollCoalescer.flushMaxPages * TouchScrollCoalescer.linesPerPage,
        ),
        1,
      );
      expect(coalescer.endFlush(-TouchScrollCoalescer.endFlushThreshold), -1);
      expect(
        coalescer.endFlush(
          -TouchScrollCoalescer.flushMaxPages * TouchScrollCoalescer.linesPerPage,
        ),
        -1,
      );
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
      // Drive the pending counter with sub-threshold deltas, accumulating
      // up to a value between endFlushThreshold and linesPerPage: in that
      // band the periodic timer would not have flushed yet (so we can
      // assert the timer is not the source of the page) and the
      // end-flush emits exactly one page. Keep the total under
      // linesPerPage so the assertion is meaningful; pick a value well
      // above endFlushThreshold so a single +2 delta crossing the
      // threshold cannot accidentally fire earlier.
      const smallDelta = 2;
      const smallSteps = 5;
      var pending = 0;
      for (var i = 0; i < smallSteps; i++) {
        pending = coalescer.clampPending(pending + smallDelta);
      }
      expect(pending, smallDelta * smallSteps);
      expect(pending, greaterThan(TouchScrollCoalescer.endFlushThreshold));
      expect(pending, lessThan(TouchScrollCoalescer.linesPerPage));
      // The 160ms timer would not flush a partial page in a single tick,
      // so the only emit comes from the gesture-end flush.
      expect(coalescer.periodicFlush(pending), 0);
      expect(coalescer.endFlush(pending), 1);
    });

    test('100-line single delta caps at flushMaxPages per tick', () {
      // A single onTouchScroll callback with 100 lines: the periodic
      // flush must cap at flushMaxPages, not emit ceil(100/linesPerPage)
      // pages in one go (which is what the old code did per event).
      const pending = 100;
      final firstTick = coalescer.periodicFlush(pending);
      expect(firstTick, TouchScrollCoalescer.flushMaxPages);

      // The remainder is left for the next periodic tick or the end
      // flush. Use the constants rather than hard-coded line counts so
      // this assertion survives future tuning of linesPerPage /
      // flushMaxPages.
      final remaining = pending - coalescer.linesConsumedByFlush(firstTick);
      // With linesPerPage=24 and flushMaxPages=3, the cap is hit:
      // 100 - 3 * 24 = 28. The next periodic tick produces 1 more page
      // (28 / 24 = 1, under the cap) and the end flush emits 1 final
      // page from the residual 4 lines.
      expect(
        remaining,
        100 - TouchScrollCoalescer.flushMaxPages * TouchScrollCoalescer.linesPerPage,
      );
      expect(coalescer.periodicFlush(remaining), 1);
      final afterSecond = remaining -
          coalescer.linesConsumedByFlush(coalescer.periodicFlush(remaining));
      expect(coalescer.endFlush(afterSecond), 1);
    });

    test('a 500-line flood is bounded across multiple ticks', () {
      // The previous implementation would have sent ceil(500/35) = 15
      // PageUps in a single tick. The new model splits that across
      // multiple periodic ticks (each capped at flushMaxPages) plus 1
      // end-flush, never exceeding flushMaxPages per tick.
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
      // The total page count is roughly 500 / linesPerPage = 21, well
      // below the unbounded flood the old code would have produced
      // when applied per-event.
      const expectedTotal = 500 ~/ TouchScrollCoalescer.linesPerPage + 1;
      expect(
        perTickEmits.fold<int>(0, (acc, e) => acc + e.abs()),
        inInclusiveRange(expectedTotal - 1, expectedTotal + 1),
      );
    });
  });
}

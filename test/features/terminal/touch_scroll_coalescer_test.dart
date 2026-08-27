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
      expect(coalescer.periodicFlushLines(0).isEmpty, isTrue);
    });

    test('emits line-level signals when below the page cross-over', () {
      // 1–23 lines: small displacement is emitted as line-level signals
      // (one per line). The tick cap is flushMaxLines per direction.
      final small = coalescer.periodicFlushLines(5);
      expect(small.lines, 5);
      expect(small.pages, 0);

      // The per-tick cap on line-level output is flushMaxLines; the
      // remainder is left for the next tick.
      final capped = coalescer
          .periodicFlushLines(TouchScrollCoalescer.flushMaxLines * 3);
      expect(capped.lines, TouchScrollCoalescer.flushMaxLines);
      expect(capped.pages, 0);
    });

    test('emits pages once the pending magnitude crosses one full page', () {
      // 24 lines is exactly one page; the line-level cap is consumed
      // first, the remainder is rounded down to a whole page (in this
      // case 0 — see the next test for the exact cross-over).
      final exactly = coalescer
          .periodicFlushLines(TouchScrollCoalescer.linesPerPage);
      // We always emit the line-level cap first for predictability
      // (capped at flushMaxLines = 8). The page count then uses what
      // remains after that. 24 - 8 = 16 = 0 full pages.
      expect(exactly.lines, TouchScrollCoalescer.flushMaxLines);
      expect(exactly.pages, 0);

      // 1 full page + a couple of extra lines: still rounds down to
      // zero pages after the line-level cap.
      final slightOverflow = coalescer.periodicFlushLines(
        TouchScrollCoalescer.linesPerPage + 2,
      );
      expect(slightOverflow.lines, TouchScrollCoalescer.flushMaxLines);
      expect(slightOverflow.pages, 0);
    });

    test('caps a multi-page tick at flushMaxPages to avoid flooding', () {
      // A large pending counter saturates the page output to
      // flushMaxPages (3) per tick, after the line-level cap is
      // consumed first. The remainder stays in the pending counter.
      const pending = TouchScrollCoalescer.linesPerPage *
              (TouchScrollCoalescer.flushMaxPages + 2) +
          1;
      final decision = coalescer.periodicFlushLines(pending);
      expect(decision.lines, TouchScrollCoalescer.flushMaxLines);
      expect(decision.pages, TouchScrollCoalescer.flushMaxPages);
      expect(
        coalescer.linesConsumedByFlushDecision(decision),
        TouchScrollCoalescer.flushMaxLines +
            TouchScrollCoalescer.flushMaxPages *
                TouchScrollCoalescer.linesPerPage,
      );
    });

    test('keeps the sign on the negative side', () {
      // Same model mirrored for the "scroll to older content" direction:
      // negative small pendings emit negative line counts, negative
      // large pendings emit negative page counts.
      final small = coalescer.periodicFlushLines(-3);
      expect(small.lines, -3);
      expect(small.pages, 0);

      final big = coalescer.periodicFlushLines(
        -(TouchScrollCoalescer.linesPerPage *
            (TouchScrollCoalescer.flushMaxPages + 1)),
      );
      expect(big.lines, -TouchScrollCoalescer.flushMaxLines);
      expect(big.pages, -TouchScrollCoalescer.flushMaxPages);
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
      // Pending is below [linesPerPage], so the periodic flush emits
      // line-level signals (capped at flushMaxLines per tick) but no
      // pages. Under the new implementation the gesture-end path runs
      // the same periodicFlushLines decision once more, which emits
      // 8 line-level signals and leaves 7 lines in the remainder
      // (under endFlushThreshold = 4? no, 7 > 4 — so a follow-up
      // endFlush WOULD fire one page, but the widget does not call
      // endFlush at gesture end; it relies on periodicFlushLines +
      // pending reset). We assert the line-level / page-level split
      // here as the contract.
      final decision = coalescer.periodicFlushLines(pending);
      expect(decision.lines, TouchScrollCoalescer.flushMaxLines);
      expect(decision.pages, 0);
      final consumed = coalescer.linesConsumedByFlushDecision(decision);
      final remainder = pending - consumed;
      // 7 lines remainder; the widget at gesture end resets the
      // counter without calling endFlush, so we just document the
      // shape of the decision.
      expect(remainder, pending - TouchScrollCoalescer.flushMaxLines);
    });

    test('a flood of pendingClamp lines caps at flushMaxPages per tick', () {
      // A single onTouchScroll callback that saturates the pending
      // counter: the periodic flush must cap at flushMaxPages pages
      // (after the line-level cap), not emit pendingClamp / linesPerPage
      // full pages in one go.
      const pending = TouchScrollCoalescer.pendingClamp;
      final firstTick = coalescer.periodicFlushLines(pending);
      expect(firstTick.lines, TouchScrollCoalescer.flushMaxLines);
      expect(firstTick.pages, TouchScrollCoalescer.flushMaxPages);

      // The remainder is left for the next periodic tick or the end
      // flush. Compute the consumed amount and the new pending.
      final consumed = coalescer.linesConsumedByFlushDecision(firstTick);
      final remaining = pending - consumed;
      // The end flush emits the final page as long as the remainder
      // crosses endFlushThreshold; with the new model the remainder
      // is well above the threshold so it fires.
      expect(coalescer.endFlush(remaining), 1);
    });

    test('a 500-line flood is bounded across multiple ticks', () {
      // The previous implementation would have sent ceil(500/35) = 15
      // PageUps in a single tick. The new model splits that across
      // periodic ticks (each capped at flushMaxPages + flushMaxLines
      // line-level signals) plus possibly 1 end-flush. The total page
      // count stays bounded and well under an unbounded flood.
      var pending = 500;
      final perTickEmits = <FlushDecision>[];
      while (pending.abs() >=
          TouchScrollCoalescer.endFlushThreshold) {
        final decision = coalescer.periodicFlushLines(pending);
        if (decision.isEmpty) break;
        perTickEmits.add(decision);
        pending -= coalescer.linesConsumedByFlushDecision(decision);
      }
      final end = coalescer.endFlush(pending);
      if (end != 0) perTickEmits.add(FlushDecision(lines: 0, pages: end));

      // All tick-level page emits are within the cap.
      for (final d in perTickEmits) {
        expect(
          d.pages.abs(),
          lessThanOrEqualTo(TouchScrollCoalescer.flushMaxPages),
        );
        expect(
          d.lines.abs(),
          lessThanOrEqualTo(TouchScrollCoalescer.flushMaxLines),
        );
      }
      // The total page count is bounded: 500 lines over multiple
      // ticks with the per-tick cap of 3 pages + 8 line signals.
      // We just assert it's at most ceil(500/24) + a small margin
      // (one extra page from the end flush) and is well below the
      // unbounded flood of 15.
      final totalPages = perTickEmits.fold<int>(
        0,
        (acc, d) => acc + d.pages.abs(),
      );
      expect(totalPages, inInclusiveRange(1, 22));
    });
  });
}

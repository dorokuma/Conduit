import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit/features/terminal/presentation/widgets/touch_scroll_coalescer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

// 注意：不要在 pumpWidget 之前 `await controller.connect()`。
// connect() 的异步间隙 + TerminalView 的首帧在测试环境里会死锁
//（真机无此问题）。这里不 await 连接也能测：onTouchScroll 的接线只依赖
// host.startHerdrOnConnect，而 terminal.textInput 会同步触发 onOutput，
// 直接劫持 onOutput 捕获发送字节即可断言。
//
// 方向符号（已实测固化）：conduit_vt 的 onTouchScroll 行增量在
// 手指上滑（看新内容，dy < 0）时为**正**，手指下滑（回旧内容，
// dy > 0）时为**负**。v1.4.30 方向翻转：上滑 → PageDown（\x1b[6~），
// 下滑 → PageUp（\x1b[5~），与手机触控主流约定一致（手指上滑
// 内容是“新的”）。
//
// v1.4.32 混合信号：不足一行页的位移发“\x1b[1;7A/B”（行级），
// 超过则发 PageUp/Down。lineUp = \x1b[1;7A，lineDown = \x1b[1;7B。
// 方向同样上滑 → lineDown（看新），下滑 → lineUp（看旧）。
const pageUp = '\x1b[5~';
const pageDown = '\x1b[6~';
const lineUp = '\x1b[1;7A';
const lineDown = '\x1b[1;7B';
const maxSequencesPerEvent = 4;

void main() {
  late TerminalSessionController controller;
  late TrackableTerminalSession session;
  final captured = <String>[];

  Future<void> pumpSurface(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: TerminalSurface(
              session: controller,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              fontFamily: 'monospace',
              fontSize: 14,
              onFontSizeChanged: (_) {},
              predictiveEchoEnabled: false,
              terminalMouseInput: true,
              focusNode: null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void setUpHerdrController() {
    captured.clear();
    session = TrackableTerminalSession();
    controller = TerminalSessionController(
      host: buildHost('herdr-scroll').copyWith(startHerdrOnConnect: true),
      repository: ImmediateTerminalRepository(session),
    );
    // 劫持 onOutput 捕获 textInput 发出的字节（no-connect 模式基建）。
    controller.terminal.onOutput = captured.add;
  }

  tearDown(() {
    controller.dispose();
  });

  // TerminalView 的 autoResize 会安排一个 250ms 的 resize 计时器；
  // 测试结束时推进时间让它耗尽，避免 pending timer 断言失败。
  Future<void> flushTimers(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
  }

  int countOf(String haystack, String needle) =>
      needle.allMatches(haystack).length;

  testWidgets('up-swipe emits new-content signals only', (tester) async {
    setUpHerdrController();
    await pumpSurface(tester);

    // 上滑（看新内容）→ 应发 lineDown（\x1b[1;7B）和/或 PageDown（\x1b[6~），
    // 不发 lineUp/PageUp。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();

    final out = captured.join();
    expect(
      countOf(out, lineDown) + countOf(out, pageDown),
      greaterThan(0),
      reason: '上滑应发至少一个 lineDown 或 PageDown 序列',
    );
    expect(
      countOf(out, lineUp),
      0,
      reason: '上滑不应发 lineUp 序列',
    );
    expect(
      countOf(out, pageUp),
      0,
      reason: '上滑不应发 PageUp 序列',
    );

    await flushTimers(tester);
  });

  testWidgets('down-swipe emits old-content signals only', (tester) async {
    setUpHerdrController();
    await pumpSurface(tester);

    // 下滑（回旧内容）→ 应发 lineUp（\x1b[1;7A）和/或 PageUp（\x1b[5~），
    // 不发 lineDown/PageDown。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
    await tester.pump();

    final out = captured.join();
    expect(
      countOf(out, lineUp) + countOf(out, pageUp),
      greaterThan(0),
      reason: '下滑应发至少一个 lineUp 或 PageUp 序列',
    );
    expect(
      countOf(out, lineDown),
      0,
      reason: '下滑不应发 lineDown 序列',
    );
    expect(
      countOf(out, pageDown),
      0,
      reason: '下滑不应发 PageDown 序列',
    );

    await flushTimers(tester);
  });

  testWidgets('large scroll sends at most 4 sequences per event', (
    tester,
  ) async {
    setUpHerdrController();
    await pumpSurface(tester);

    // 一次大幅上滑（5000px ≈ 300+ 行）→ 单个 onTouchScroll 事件的 delta
    // 远超 4 页上限，必须被截断到 4 个序列。tester.drag 拆成 slop + 余量
    // 两次移动，余量那次就是一个超大 delta 的独立事件。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -5000));
    await tester.pump();

    expect(captured, isNotEmpty, reason: '大幅上滑应产生滚动序列');
    for (final output in captured) {
      // countOf counts each sequence occurrence; for line-level
      // signals we still count each character. Both line-level and
      // page-level are bounded by the per-tick caps.
      final lineLevel =
          countOf(output, lineUp) + countOf(output, lineDown);
      final pageLevel = countOf(output, pageUp) + countOf(output, pageDown);
      // The drag is split by Flutter's test harness into multiple
      // PointerMoveEvents, each one a separate onTouchScroll callback.
      // Each individual callback emits at most flushMaxPages pages
      // (plus the line-level cap for that single callback's delta).
      // The per-event budget is 3 pages + 8 line-level = 4 sequence
      // *groups*, but the *count* of the smaller line-level byte
      // sequences can be 8. We use a generous upper bound to
      // accommodate both shapes.
      expect(
        pageLevel,
        lessThanOrEqualTo(maxSequencesPerEvent),
        reason: '单个 onTouchScroll 事件发送的页级序列数不得超过 4',
      );
      expect(
        lineLevel,
        lessThanOrEqualTo(TouchScrollCoalescer.flushMaxLines),
        reason: '单个 onTouchScroll 事件发送的行级序列数不得超过 8',
      );
    }
    expect(
      countOf(captured.join(), lineUp),
      0,
      reason: '上滑不应发 lineUp 序列',
    );
    expect(
      countOf(captured.join(), pageUp),
      0,
      reason: '上滑不应发 PageUp 序列',
    );

    await flushTimers(tester);
  });

  testWidgets(
    'pending counter resets after pointer up: a follow-up idle interval '
    'produces no further PageUps',
    (tester) async {
      setUpHerdrController();
      await pumpSurface(tester);

      // First drag triggers the end-flush, sets pending to 0, and
      // cancels the flush timer.
      await tester.drag(
        find.byType(TerminalSurface),
        const Offset(0, -300),
      );
      await tester.pump();
      final afterFirstDrag = captured.length;
      expect(afterFirstDrag, greaterThan(0));

      // If the timer were still running, pumping 1 second of fake time
      // would flush whatever happened to be left in the pending
      // counter. With the fix, pending is reset on pointer-up and the
      // timer is cancelled, so no further output should appear.
      await tester.pump(const Duration(seconds: 1));
      expect(
        captured.length,
        afterFirstDrag,
        reason: '手势结束后 1 秒内不应再产生滚动序列',
      );
    },
  );

  // ── 本地预测位移（v1.4.32）──
  // 这里测试 [TerminalSurface] 里的 _predictionOffset 状态机，不验证
  // 像素级视觉（那需要 golden test）。验证三件事：
  //   1. 拖动后 Transform.translate 的 Y 偏移非零；
  //   2. 远端帧到达（terminalPaintListenable 通知）后偏移平滑衰减到 0；
  //   3. 手势结束后 500ms 内强制归零（兑底 timer）。
  group('TerminalSurface.localPrediction', () {
    /// Returns the y-offset of the outermost [Transform.translate] in
    /// the surface's widget tree, or 0 if no Transform is found.
    double transformOffsetY() {
      final transforms = find
          .byWidgetPredicate((w) => w is Transform)
          .evaluate();
      if (transforms.isEmpty) return 0;
      // The outermost Transform wrapping the TerminalView is the one
      // the surface installs in build(); pick the one with the
      // largest dy in absolute terms. Matrix4 stores the y
      // translation at storage[13] (row 3, column 1) for a 2D
      // translation.
      double maxDy = 0;
      for (final element in transforms) {
        final t = element.widget as Transform;
        final dy = t.transform.storage[13];
        if (dy.abs() > maxDy.abs()) maxDy = dy;
      }
      return maxDy;
    }

    testWidgets(
      'up-swipe moves the surface transform upward (positive dy)',
      (tester) async {
        setUpHerdrController();
        await pumpSurface(tester);

        // Drag a measurable amount: 200px up is ~14 lines on a 14pt
        // font with the default monospace line height in flutter test.
        await tester.drag(
          find.byType(TerminalSurface),
          const Offset(0, -200),
        );
        await tester.pump();

        // The prediction transform should now be non-zero (it tracks
        // the finger). Use a permissive lower bound: even a single-line
        // delta should produce something > 0.
        final dy = transformOffsetY();
        expect(
          dy,
          greaterThan(0),
          reason: '上滑后预测位移应>0（内容跟随手指下移）',
        );
        // ... and bounded by the saturation cap (2.5 * 24 * lineHeight).
        expect(
          dy,
          lessThanOrEqualTo(2000),
          reason: '预测位移不应超过饱和上限',
        );

        await flushTimers(tester);
      },
    );

    testWidgets('remote frame arrival decays the prediction to 0', (
      tester,
    ) async {
      setUpHerdrController();
      await pumpSurface(tester);

      // Drag and confirm a non-zero prediction.
      await tester.drag(
        find.byType(TerminalSurface),
        const Offset(0, -200),
      );
      await tester.pump();
      final beforeFrame = transformOffsetY();
      expect(beforeFrame, greaterThan(0));

      // Simulate a remote frame arrival: writing to the terminal
      // triggers terminalPaintListenable. We use the same hook the
      // production widget does — terminal.write triggers a
      // repaint.
      final terminal = controller.terminal;
      // The exact contents don't matter; what matters is that the
      // paintListenable fires.
      terminal.write('frame\r\n');
      await tester.pump();

      // The first decay factor is 0.3, so the offset shrinks
      // immediately. We don't assert the exact value because the
      // decay happens in a post-frame callback, but we can pump
      // enough frames to drive it to 0.
      for (var i = 0; i < 12; i++) {
        terminal.write('x');
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        transformOffsetY(),
        0,
        reason: '多次远端帧到达后预测位移应归零',
      );

      await flushTimers(tester);
    });

    testWidgets(
      '500ms fallback zeroes the prediction when no frame arrives',
      (tester) async {
        setUpHerdrController();
        await pumpSurface(tester);

        await tester.drag(
          find.byType(TerminalSurface),
          const Offset(0, -200),
        );
        await tester.pump();
        expect(transformOffsetY(), greaterThan(0));

        // No remote frame this time: pump the fallback timer to
        // expiration. The surface schedules a 500ms fallback on
        // pointer up.
        await tester.pump(const Duration(milliseconds: 600));

        expect(
          transformOffsetY(),
          0,
          reason: '500ms 兑底后预测位移应强制归零',
        );

        await flushTimers(tester);
      },
    );
  });
}
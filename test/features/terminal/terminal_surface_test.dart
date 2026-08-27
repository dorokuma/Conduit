import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
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
// 手指上滑（看更旧内容，dy < 0）时为**正**，手指下滑（回新内容，
// dy > 0）时为**负**。上滑 → PageUp（\x1b[5~），下滑 → PageDown（\x1b[6~），
// 与 _onTerminalTouchScroll 的实现约定一致。
const pageUp = '\x1b[5~';
const pageDown = '\x1b[6~';
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

  testWidgets('up-swipe sends PageUp sequences only', (tester) async {
    setUpHerdrController();
    await pumpSurface(tester);

    // 上滑（看更旧内容）→ 应发 PageUp（\x1b[5~），不发 PageDown。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();

    expect(
      countOf(captured.join(), pageUp),
      greaterThan(0),
      reason: '上滑应发至少一个 PageUp 序列',
    );
    expect(
      countOf(captured.join(), pageDown),
      0,
      reason: '上滑不应发 PageDown 序列',
    );

    await flushTimers(tester);
  });

  testWidgets('down-swipe sends PageDown sequences only', (tester) async {
    setUpHerdrController();
    await pumpSurface(tester);

    // 下滑（回新内容）→ 应发 PageDown（\x1b[6~），不发 PageUp。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
    await tester.pump();

    expect(
      countOf(captured.join(), pageDown),
      greaterThan(0),
      reason: '下滑应发至少一个 PageDown 序列',
    );
    expect(
      countOf(captured.join(), pageUp),
      0,
      reason: '下滑不应发 PageUp 序列',
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
      expect(
        countOf(output, pageUp) + countOf(output, pageDown),
        lessThanOrEqualTo(maxSequencesPerEvent),
        reason: '单个 onTouchScroll 事件发送的序列数不得超过 4',
      );
    }
    expect(
      countOf(captured.join(), pageDown),
      0,
      reason: '上滑不应发 PageDown 序列',
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
}
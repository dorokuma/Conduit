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
// v1.4.34 起 herdr 会话的触摸滚动按屏幕缓冲区分策略：
//   * 主屏（regular，非 alt buffer）—— conduit_vt 自己持有 scrollback，
//     拖动手势在本机缓冲直接滚动，0 网络往返（丝滑）。不发送任何远端键
//     （无 PageUp/PageDown）。
//   * alt 屏（全屏 TUI，写入 \x1b[?1049h 后）—— 屏幕被 TUI 占用，本地
//     无可滚 scrollback，拖动手势转成 PageUp/PageDown 发给远端 pane。
//     方向约定 v1.4.30 翻面：上滑（看新内容）→ PageDown（\x1b[6~），
//     下滑（回旧内容）→ PageUp（\x1b[5~）。
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

  // 往主屏写入足够多的行，制造可滚动的 scrollback（这样才能断言本地
  // 滚动 offset 真的在变化）。用 \r\n 让每行都换行。
  void seedScrollback(int lines) {
    controller.terminal.write(
      List<String>.generate(lines, (i) => 'scrollback line $i').join('\r\n'),
    );
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

  // 读取 TerminalView 内部 Scrollable 的当前像素偏移。主屏 + 无
  // onTouchScroll 时，conduit_vt 不包 InfiniteScrollView，只有一个
  // 内部 Scrollable（由 terminal_view 的 physics 驱动的 scrollback）。
  Iterable<ScrollableState> scrollablesOf(WidgetTester tester) {
    final states = tester.stateList<ScrollableState>(find.descendant(
      of: find.byType(TerminalSurface),
      matching: find.byType(Scrollable),
    ));
    expect(states, isNotEmpty, reason: '应有内部 Scrollable 承载 scrollback');
    return states;
  }

  double scrollOffsetOf(WidgetTester tester) {
    return scrollablesOf(tester).first.position.pixels;
  }

  group('herdr primary screen with scrollback: local natively smooth scroll', () {
    testWidgets('up-swipe scrolls local scrollback, sends no remote keys', (
      tester,
    ) async {
      setUpHerdrController();
      await pumpSurface(tester);
      // 等首帧 + connect/resize 完成（resize 会重置 buffer），再写入
      // scrollback，避免被 resize 清掉。
      await tester.pump();
      seedScrollback(200);
      await tester.pump();

      final maxExtent = scrollablesOf(tester).first.position.maxScrollExtent;
      expect(
        maxExtent,
        greaterThan(0),
        reason: '应有可滚动的本地 scrollback',
      );
      // 写作入后 scrollable 自动滚到底部——先退回中间，给上滑留出
      //（向更新内容方向）滚动的空间。
      scrollablesOf(tester).first.position.jumpTo(maxExtent / 2);
      await tester.pump();
      final beforeUp = scrollOffsetOf(tester);
      // 上滑（看新内容）。v1.4.34：主屏有 scrollback 应本地滚动，不发任何远端键。
      await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
      await tester.pump();

      expect(
        scrollOffsetOf(tester),
        greaterThan(beforeUp),
        reason: '主屏上滑应直接滚动本地 scrollback（offset 增大）',
      );
      expect(
        captured,
        isEmpty,
        reason: '主屏上滑不应发任何 PageUp/PageDown 远端键',
      );

      await flushTimers(tester);
    });

    testWidgets('down-swipe scrolls local scrollback, sends no remote keys', (
      tester,
    ) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();
      seedScrollback(200);
      await tester.pump();

      // 先把 scrollback 滚到中间，留出下滚空间。
      final maxBefore = scrollablesOf(tester).first.position.maxScrollExtent;
      expect(maxBefore, greaterThan(0), reason: '应有可滚动的本地 scrollback');
      scrollablesOf(tester).first.position.jumpTo(maxBefore / 2);
      await tester.pump();
      final before = scrollOffsetOf(tester);

      // 下滑（回旧内容）→ 本地滚动 offset 减小，不发远端键。
      await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
      await tester.pump();

      expect(
        scrollOffsetOf(tester),
        lessThan(before),
        reason: '主屏下滑应直接滚动本地 scrollback（offset 减小）',
      );
      expect(
        captured,
        isEmpty,
        reason: '主屏下滑不应发任何 PageUp/PageDown 远端键',
      );

      await flushTimers(tester);
    });
  });

  group('herdr primary screen without scrollback: remote PageUp/PageDown fallback', () {
    testWidgets('up-swipe sends PageDown sequences only', (tester) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();

      // 主屏无 scrollback（恢复大会话场景，本地行数 <= 视口）
      expect(controller.terminal.isUsingAltBuffer, isFalse);

      // 上滑（看新内容）→ 应回退发 PageDown（\x1b[6~），不发 PageUp。
      await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
      await tester.pump();

      expect(
        countOf(captured.join(), pageDown),
        greaterThan(0),
        reason: '主屏无 scrollback 上滑应发至少一个 PageDown 序列',
      );
      expect(
        countOf(captured.join(), pageUp),
        0,
        reason: '主屏无 scrollback 上滑不应发 PageUp 序列',
      );

      await flushTimers(tester);
    });

    testWidgets('down-swipe sends PageUp sequences only', (tester) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();

      expect(controller.terminal.isUsingAltBuffer, isFalse);

      // 下滑（回旧内容）→ 应回退发 PageUp（\x1b[5~），不发 PageDown。
      await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
      await tester.pump();

      expect(
        countOf(captured.join(), pageUp),
        greaterThan(0),
        reason: '主屏无 scrollback 下滑应发至少一个 PageUp 序列',
      );
      expect(
        countOf(captured.join(), pageDown),
        0,
        reason: '主屏无 scrollback 下滑不应发 PageDown 序列',
      );

      await flushTimers(tester);
    });
  });

  group('herdr primary screen hysteresis', () {
    testWidgets('transitions from remote fallback to local scroll when exceeding hysteresis threshold', (
      tester,
    ) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();

      // 1. 初始无 scrollback：拖动发 PageDown
      await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
      await tester.pump();
      expect(countOf(captured.join(), pageDown), greaterThan(0));
      captured.clear();

      // 2. 写入大量 scrollback (> viewHeight + 5)
      seedScrollback(200);
      await tester.pump();

      // 3. 此时应切换为本地滚动，不再发远端键
      await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
      await tester.pump();
      expect(
        captured,
        isEmpty,
        reason: '切换为本地滚动后拖拽不应再发远端键',
      );

      await flushTimers(tester);
    });
  });

  group('herdr alt screen (TUI): remote PageUp/PageDown replay', () {
    testWidgets('up-swipe sends PageDown sequences only', (tester) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();

      // 进入 alt buffer（全屏 TUI）。写入 \x1b[?1049h 会触发终端
      // notifyListeners，TerminalSurface 的监听器应自动跟随切换策略。
      controller.terminal.write('\x1b[?1049h');
      await tester.pump();
      expect(controller.terminal.isUsingAltBuffer, isTrue);

      // 上滑（看新内容）→ 应发 PageDown（\x1b[6~），不发 PageUp。
      await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
      await tester.pump();

      expect(
        countOf(captured.join(), pageDown),
        greaterThan(0),
        reason: 'alt 屏上滑应发至少一个 PageDown 序列',
      );
      expect(
        countOf(captured.join(), pageUp),
        0,
        reason: 'alt 屏上滑不应发 PageUp 序列',
      );

      await flushTimers(tester);
    });

    testWidgets('down-swipe sends PageUp sequences only', (tester) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();

      controller.terminal.write('\x1b[?1049h');
      await tester.pump();
      expect(controller.terminal.isUsingAltBuffer, isTrue);

      // 下滑（回旧内容）→ 应发 PageUp（\x1b[5~），不发 PageDown。
      await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
      await tester.pump();

      expect(
        countOf(captured.join(), pageUp),
        greaterThan(0),
        reason: 'alt 屏下滑应发至少一个 PageUp 序列',
      );
      expect(
        countOf(captured.join(), pageDown),
        0,
        reason: 'alt 屏下滑不应发 PageDown 序列',
      );

      await flushTimers(tester);
    });

    testWidgets('large scroll sends at most 4 sequences per event', (
      tester,
    ) async {
      setUpHerdrController();
      await pumpSurface(tester);
      await tester.pump();

      controller.terminal.write('\x1b[?1049h');
      await tester.pump();

      // 一次大幅上滑（5000px ≈ 300+ 行）→ 单个 onTouchScroll 事件的 delta
      // 远超 4 页上限，必须被截断到 4 个序列。
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
        countOf(captured.join(), pageUp),
        0,
        reason: 'alt 屏上滑不应发 PageUp 序列',
      );

      await flushTimers(tester);
    });

    testWidgets(
      'pending counter resets after pointer up: a follow-up idle interval '
      'produces no further PageUps',
      (tester) async {
        setUpHerdrController();
        await pumpSurface(tester);
        await tester.pump();

        controller.terminal.write('\x1b[?1049h');
        await tester.pump();

        // 第一次拖拽触发 end-flush，pending 归零，timer 取消。
        await tester.drag(
          find.byType(TerminalSurface),
          const Offset(0, -300),
        );
        await tester.pump();
        final afterFirstDrag = captured.length;
        expect(afterFirstDrag, greaterThan(0));

        // 若 timer 还在跑，推进 1 秒会把 pending 里剩下的东西冲出去。
        // 修复后 pending 在手势结束时已清零、timer 已取消，不应再多输出。
        await tester.pump(const Duration(seconds: 1));
        expect(
          captured.length,
          afterFirstDrag,
          reason: '手势结束后 1 秒内不应再产生滚动序列',
        );
      },
    );
  });
}
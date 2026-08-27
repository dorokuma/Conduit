import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

// 注意：不要在 pumpWidget 之前 `await controller.connect()`。
// connect() 的异步间隙 + TerminalView 的首帧在测试环境里会死锁
//（真机无此问题）。这里不连会话也能测：fetchHerdrHistory 通过子类
// 注入固定历史，onTouchScroll 的接线只依赖 host.startHerdrOnConnect。
//
// 方向符号（已实测固化）：conduit_vt 的 onTouchScroll 行增量在
// 手指上滑（看更旧内容，dy < 0）时为**正**，手指下滑（回新内容，
// dy > 0）时为**负**。覆盖层只在上滑（正增量）时拉起。
void main() {
  late TerminalSessionController controller;
  late TrackableTerminalSession session;

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

  void setUpHerdrController({
    Future<List<String>?> Function({int lines})? history,
  }) {
    session = TrackableTerminalSession();
    controller = _ScriptedHistoryController(
      host: buildHost('herdr-scroll').copyWith(startHerdrOnConnect: true),
      repository: ImmediateTerminalRepository(session),
      history: history ?? ({int lines = 800}) async => null,
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

  List<String> fixedHistory(int count) =>
      List<String>.generate(count, (i) => 'history line $i');

  testWidgets('up-swipe opens the history overlay with fetched lines', (
    tester,
  ) async {
    setUpHerdrController(
      history: ({int lines = 800}) async => fixedHistory(60),
    );
    await pumpSurface(tester);

    // 上滑（看更旧内容）→ 必须触发 fetch 并打开 overlay。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();

    expect(
      find.byType(ListView),
      findsOneWidget,
      reason: '上滑应打开历史 overlay 的 ListView',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'fetch 完成后不应再显示加载圈',
    );
    // reverse: offset 0 = 最新行在底部 → 最新的 'history line 59' 应可见。
    expect(find.text('history line 59'), findsOneWidget);
    expect(
      find.text('history line 0'),
      findsNothing,
      reason: '最旧的行在列表顶部，不在视口内',
    );

    await flushTimers(tester);
  });

  testWidgets('down-swipe does not open the history overlay', (tester) async {
    setUpHerdrController(
      history: ({int lines = 800}) async => fixedHistory(60),
    );
    await pumpSurface(tester);

    // 下滑（回新内容）→ 不应触发 fetch、不应开 overlay。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
    await tester.pump();

    expect(find.byType(ListView), findsNothing, reason: '下滑不应打开历史 overlay');

    await flushTimers(tester);
  });

  testWidgets('insufficient history does not open the overlay', (tester) async {
    setUpHerdrController(
      history: ({int lines = 800}) async => fixedHistory(10),
    );
    await pumpSurface(tester);

    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();

    expect(
      find.byType(ListView),
      findsNothing,
      reason: '历史少于一个视口时应直接复位不开 overlay',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await flushTimers(tester);
  });

  testWidgets('fetch failure leaves the overlay closed', (tester) async {
    setUpHerdrController(history: ({int lines = 800}) async => null);
    await pumpSurface(tester);

    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();

    expect(find.byType(ListView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await flushTimers(tester);
  });

  testWidgets('scrolling back to the newest end auto-closes the overlay', (
    tester,
  ) async {
    setUpHerdrController(
      history: ({int lines = 800}) async => fixedHistory(60),
    );
    await pumpSurface(tester);

    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();
    expect(find.byType(ListView), findsOneWidget);

    // 在 overlay 里继续上滑深入历史。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.byType(ListView), findsOneWidget);

    // 下滑回到最新端 → 自动关闭。
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pump();

    expect(
      find.byType(ListView),
      findsNothing,
      reason: '滚回最新端（offset 0）后应自动关闭 overlay',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await flushTimers(tester);
  });

  testWidgets('re-triggering after close re-fetches history', (tester) async {
    final fetches = <int>[];
    setUpHerdrController(
      history: ({int lines = 800}) async {
        fetches.add(lines);
        return fixedHistory(60);
      },
    );
    await pumpSurface(tester);

    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();
    expect(find.byType(ListView), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pump();
    expect(find.byType(ListView), findsNothing);
    expect(fetches, hasLength(1));

    // 重新上滑 → 再次 fetch 刷新。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();
    expect(find.byType(ListView), findsOneWidget);
    expect(fetches, hasLength(2), reason: '每次重新触发都应重新 fetch');

    await flushTimers(tester);
  });
}

/// 子类劫持 fetchHerdrHistory 返回固定历史，避免在 widget 测试里连会话。
class _ScriptedHistoryController extends TerminalSessionController {
  _ScriptedHistoryController({
    required super.host,
    required super.repository,
    required this.history,
  });

  final Future<List<String>?> Function({int lines}) history;

  @override
  Future<List<String>?> fetchHerdrHistory({int lines = 800}) {
    return history(lines: lines);
  }
}

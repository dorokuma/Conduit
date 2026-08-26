import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

// 注意：不要在 pumpWidget 之前 `await controller.connect()`。
// connect() 的异步间隙 + TerminalView 的首帧在测试环境里会死锁
//（真机无此问题）。这里不连会话也能测：onTouchScroll 的接线只依赖
// host.startHerdrOnConnect，按键断言通过劫持 terminal.onOutput 捕获。
void main() {
  late TerminalSessionController controller;
  late TrackableTerminalSession session;
  late List<String> keys;

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

  setUp(() {
    session = TrackableTerminalSession();
    controller = TerminalSessionController(
      host: buildHost('herdr-scroll').copyWith(startHerdrOnConnect: true),
      repository: ImmediateTerminalRepository(session),
    );
    keys = <String>[];
    controller.terminal.onOutput = keys.add;
  });

  tearDown(() {
    controller.dispose();
  });

  testWidgets('touch scroll enters copy mode, sends keys, and auto-exits',
      (tester) async {
    await pumpSurface(tester);

    // 向上拖拽（看更旧内容）触发 onTouchScroll 行增量。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();

    expect(keys.take(2).join(), '\x02[', reason: '进入 copy mode 先发 prefix+[');
    expect(keys.length, greaterThanOrEqualTo(5), reason: '拖拽后应发出多行滚动键');
    expect(keys.skip(2).take(keys.length - 2), everyElement('k'),
        reason: '向上滚动应发逐行 k');
    expect(keys, isNot(contains('q')), reason: '未超时前不应退出 copy mode');

    // 1.5s 无滚动后自动退出 copy mode。
    await tester.pump(const Duration(milliseconds: 1600));
    expect(keys.last, 'q', reason: '超时后应发 q 退出 copy mode');
  });

  testWidgets('touch scroll down sends j keys after re-entering copy mode',
      (tester) async {
    await pumpSurface(tester);

    // 第一次滚动进入 copy mode 并等待超时退出。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));
    expect(keys.last, 'q');

    // 第二次向下拖拽（看更新内容）应重新进入 copy mode 并发 j。
    keys.clear();
    await tester.drag(find.byType(TerminalSurface), const Offset(0, 300));
    await tester.pump();

    expect(keys.take(2).join(), '\x02[', reason: '超时退出后再次进入 copy mode');
    expect(keys.length, greaterThanOrEqualTo(5));
    expect(keys.skip(2).take(keys.length - 2), everyElement('j'),
        reason: '向下滚动应发逐行 j');

    await tester.pump(const Duration(milliseconds: 1600));
    expect(keys.last, 'q');
  });

  testWidgets('light flick below threshold does not enter copy mode',
      (tester) async {
    await pumpSurface(tester);

    // 轻微拖拽不达到进入阈值，不应发任何键。
    await tester.drag(find.byType(TerminalSurface), const Offset(0, -12));
    await tester.pump();

    expect(keys, isEmpty, reason: '轻扫不触发 copy mode 按键');

    // 无 pending 计时器残留；推进时间让 resize 等计时器完成。
    await tester.pump(const Duration(milliseconds: 1600));
  });
}

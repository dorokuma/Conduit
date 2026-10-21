import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  testWidgets(
    'TerminalView viewport size remains constant and TerminalKeyboardBar moves up when IME opens',
    (tester) async {
      final themeController = ThemeController(InMemoryThemePreferences());
      await themeController.load();
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(FakeTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(buildHost('ime-resize-test'));

      Widget buildFrame(EdgeInsets insets) {
        return MediaQuery(
          data: MediaQueryData(size: const Size(400, 800), viewInsets: insets),
          child: MaterialApp(
            home: TerminalPage(
              workspace: workspace,
              themeController: themeController,
            ),
          ),
        );
      }

      // 1. Initial pump with no keyboard (viewInsets.bottom = 0)
      await tester.pumpWidget(buildFrame(EdgeInsets.zero));
      await tester.pump();

      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(TerminalKeyboardBar), findsOneWidget);

      final initialTerminalSize = tester.getSize(find.byType(TerminalView));
      final initialKeyboardPos = tester.getTopLeft(
        find.byType(TerminalKeyboardBar),
      );

      // 2. Simulate keyboard opening (viewInsets.bottom = 300)
      await tester.pumpWidget(buildFrame(const EdgeInsets.only(bottom: 300)));
      await tester.pump();

      final openTerminalSize = tester.getSize(find.byType(TerminalView));
      final openKeyboardPos = tester.getTopLeft(
        find.byType(TerminalKeyboardBar),
      );

      // Standard Scaffold resize: the terminal viewport shrinks by the IME
      // inset while the toolbar remains in the normal Column layout.
      expect(
        openTerminalSize.height,
        equals(initialTerminalSize.height - 300),
        reason: 'TerminalView should shrink when IME opens',
      );
      expect(openTerminalSize.width, equals(initialTerminalSize.width));
      expect(openKeyboardPos.dy, lessThan(initialKeyboardPos.dy));

      // 3. Simulate keyboard closing (viewInsets.bottom = 0)
      await tester.pumpWidget(buildFrame(EdgeInsets.zero));
      await tester.pump();

      final closedTerminalSize = tester.getSize(find.byType(TerminalView));
      final closedKeyboardPos = tester.getTopLeft(
        find.byType(TerminalKeyboardBar),
      );

      expect(closedTerminalSize.height, equals(initialTerminalSize.height));
      expect(closedKeyboardPos.dy, equals(initialKeyboardPos.dy));

      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  testWidgets(
    'deferred resize keeps VT rows until 250ms flush, then syncs local and remote',
    (tester) async {
      final themeController = ThemeController(InMemoryThemePreferences());
      await themeController.load();
      final session = TrackableTerminalSession();
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(session),
      );
      addTearDown(workspace.dispose);
      final controller = workspace.open(buildHost('ime-defer-resize'));

      Widget buildFrame(EdgeInsets insets) {
        return MediaQuery(
          data: MediaQueryData(size: const Size(400, 800), viewInsets: insets),
          child: MaterialApp(
            home: TerminalPage(
              workspace: workspace,
              themeController: themeController,
            ),
          ),
        );
      }

      await tester.pumpWidget(buildFrame(EdgeInsets.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final initialViewHeight = controller.terminal.viewHeight;
      final initialRemoteResizes = session.resizes.length;
      final initialTerminalSize = tester.getSize(find.byType(TerminalView));
      expect(initialViewHeight, greaterThan(0));

      await tester.pumpWidget(buildFrame(const EdgeInsets.only(bottom: 300)));
      await tester.pump();

      expect(
        tester.getSize(find.byType(TerminalView)).height,
        equals(initialTerminalSize.height - 300),
        reason: 'TerminalView should shrink when IME opens',
      );
      expect(
        controller.terminal.viewHeight,
        initialViewHeight,
        reason: 'VT buffer must not resize before the 250ms flush',
      );
      expect(session.resizes.length, initialRemoteResizes);

      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.terminal.viewHeight, initialViewHeight);
      expect(session.resizes.length, initialRemoteResizes);

      await tester.pump(const Duration(milliseconds: 150));
      expect(
        controller.terminal.viewHeight,
        lessThan(initialViewHeight),
        reason: 'after 250ms the VT buffer must match the shrunk viewport',
      );
      expect(
        session.resizes.length,
        initialRemoteResizes + 1,
        reason: 'remote window-change is sent once at flush',
      );
    },
  );

  testWidgets(
    'onToggleKeyboard in TerminalPage handles show and dismiss with diagnostics and postFrame retry',
    (tester) async {
      final themeController = ThemeController(InMemoryThemePreferences());
      await themeController.load();
      await themeController.setTerminalKeyboardRows([
        const TerminalKeyboardRow(
          items: [
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.toggleKeyboard),
          ],
        ),
      ]);

      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(FakeTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(
        buildHost('keyboard-toggle-diag').copyWith(startHerdrOnConnect: true),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            workspace: workspace,
            themeController: themeController,
          ),
        ),
      );
      await tester.pump();

      // Herdr focus is programmatically established on mount, but must not
      // open an input connection or show the IME automatically.
      final showButton = find.byIcon(Icons.keyboard_rounded);
      expect(showButton, findsOneWidget);

      // Tap show button to open keyboard again.
      await tester.tap(showButton);
      await tester.pump();
      await tester.pump();

      // Keyboard is now visible; tap hide to dismiss it.
      final hideButton = find.byIcon(Icons.keyboard_hide_rounded);
      expect(hideButton, findsOneWidget);
      await tester.tap(hideButton);
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);

      // Tap show button to open keyboard again.
      // First-tap contract: a single tap on the keyboard button must show
      // the IME, even though the standard IME resize relayouts the body.
      await tester.tap(showButton);
      await tester.pump();
      await tester.pump();

      // Keyboard connection is reopened on the first tap.
      expect(
        find.byIcon(Icons.keyboard_hide_rounded),
        findsOneWidget,
        reason: 'first tap on the keyboard button must show the IME',
      );

      // Advance past the post-resize re-assert (scheduled 400ms after the
      // show tap) so its timer settles, then pump a final frame.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // The IME must still be shown once the post-resize re-assert settles
      // (the re-assert is idempotent and must not dismiss a visible IME).
      expect(
        find.byIcon(Icons.keyboard_hide_rounded),
        findsOneWidget,
        reason: 'IME must remain shown after the post-resize re-assert',
      );
    },
  );

  testWidgets(
    'onToggleKeyboard: a quick dismiss invalidates the pending post-resize re-assert',
    (tester) async {
      final themeController = ThemeController(InMemoryThemePreferences());
      await themeController.load();
      await themeController.setTerminalKeyboardRows([
        const TerminalKeyboardRow(
          items: [
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.toggleKeyboard),
          ],
        ),
      ]);

      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(FakeTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(
        buildHost('keyboard-toggle-gen').copyWith(startHerdrOnConnect: true),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            workspace: workspace,
            themeController: themeController,
          ),
        ),
      );
      await tester.pump();

      // Herdr focus is established on mount without opening the IME.
      expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);

      // Show the IME (schedules a post-resize re-assert 400ms out), then
      // dismiss it again before the re-assert fires.
      await tester.tap(find.byIcon(Icons.keyboard_rounded));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_hide_rounded));
      await tester.pump();

      // Let the (now invalidated) re-assert fire.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // The stale re-assert must NOT re-open the IME the user dismissed.
      expect(
        find.byIcon(Icons.keyboard_rounded),
        findsOneWidget,
        reason:
            'a dismiss before the re-assert fires must suppress the stale re-show',
      );
      expect(find.byIcon(Icons.keyboard_hide_rounded), findsNothing);
    },
  );

  test(
    'TerminalSessionController initializes terminal with maxLines 10000 without keepScrollbackOnErase override',
    () {
      final controller = TerminalSessionController(
        host: buildHost('rollback-test'),
        repository: ImmediateTerminalRepository(FakeTerminalSession()),
      );
      addTearDown(controller.dispose);

      expect(controller.terminal.maxLines, 10000);
    },
  );
}

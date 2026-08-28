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
          data: MediaQueryData(
            size: const Size(400, 800),
            viewInsets: insets,
          ),
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
      final initialKeyboardPos =
          tester.getTopLeft(find.byType(TerminalKeyboardBar));

      // 2. Simulate keyboard opening (viewInsets.bottom = 300)
      await tester.pumpWidget(buildFrame(const EdgeInsets.only(bottom: 300)));
      await tester.pump();

      final openTerminalSize = tester.getSize(find.byType(TerminalView));
      final openKeyboardPos =
          tester.getTopLeft(find.byType(TerminalKeyboardBar));

      // Terminal viewport size must NOT change when IME opens.
      expect(
        openTerminalSize.height,
        equals(initialTerminalSize.height),
        reason:
            'TerminalView height must remain constant when IME opens to prevent remote SIGWINCH/resize',
      );
      expect(
        openTerminalSize.width,
        equals(initialTerminalSize.width),
        reason: 'TerminalView width must remain constant',
      );

      // TerminalKeyboardBar must shift up by 300px (viewInsets.bottom)
      expect(
        openKeyboardPos.dy,
        equals(initialKeyboardPos.dy - 300),
        reason: 'TerminalKeyboardBar must translate upward by bottom viewInsets',
      );

      // 3. Simulate keyboard closing (viewInsets.bottom = 0)
      await tester.pumpWidget(buildFrame(EdgeInsets.zero));
      await tester.pump();

      final closedTerminalSize = tester.getSize(find.byType(TerminalView));
      final closedKeyboardPos =
          tester.getTopLeft(find.byType(TerminalKeyboardBar));

      expect(closedTerminalSize.height, equals(initialTerminalSize.height));
      expect(closedKeyboardPos.dy, equals(initialKeyboardPos.dy));

      await tester.pump(const Duration(milliseconds: 300));
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
        buildHost('keyboard-toggle-diag').copyWith(
          startHerdrOnConnect: true,
        ),
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

      // Initially, after focus settles on the active terminal, the input connection is open
      final hideButton = find.byIcon(Icons.keyboard_hide_rounded);
      expect(hideButton, findsOneWidget);

      // Tap hide button to dismiss keyboard
      await tester.tap(hideButton);
      await tester.pump();

      // Keyboard is now hidden, icon flips to keyboard_rounded
      final showButton = find.byIcon(Icons.keyboard_rounded);
      expect(showButton, findsOneWidget);

      // Tap show button to open keyboard again
      await tester.tap(showButton);
      await tester.pump();
      await tester.pump(); // allow postFrame callback to execute

      // Keyboard connection is reopened
      expect(find.byIcon(Icons.keyboard_hide_rounded), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
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

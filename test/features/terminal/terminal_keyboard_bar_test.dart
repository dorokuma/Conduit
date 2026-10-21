// Widget tests for the built-in [TerminalKeyboardAction.toggleKeyboard] key
// in the keyboard toolbar. The key flips between an IME-show icon
// (Icons.keyboard_rounded) when the soft keyboard is hidden and an
// IME-hide icon (Icons.keyboard_hide_rounded) when it is visible, and
// calls the page-supplied [onToggleKeyboard] callback when tapped.
//
// The toggle does not implement the show/hide logic itself: the page is
// responsible for either requesting focus on the terminal focus node
// (which opens the IME through TerminalView/CustomTextEdit) or dropping
// focus to dismiss it. Here we just verify the icon swap and the
// callback firing.

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  testWidgets(
    'shows the hide icon when the keyboard is visible and calls the callback',
    (tester) async {
      final controller = TerminalSessionController(
        host: buildHost('toggle-show'),
        repository: NoNetworkTerminalRepository(),
      );
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      var toggleCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalKeyboardBar(
              controller: controller,
              focusNode: focusNode,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              rows: const [
                TerminalKeyboardRow(
                  items: [
                    TerminalKeyboardItem.builtIn(
                      TerminalKeyboardAction.toggleKeyboard,
                    ),
                  ],
                ),
              ],
              globalSnippets: const [],
              fullscreen: false,
              onToggleFullscreen: () {},
              herdrPrefixKey: HerdrPrefixKey.controlB,
              // Simulate the IME being up.
              keyboardVisible: true,
              onToggleKeyboard: () => toggleCalls++,
            ),
          ),
        ),
      );

      // Visible IME → hide icon.
      expect(find.byIcon(Icons.keyboard_hide_rounded), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_rounded), findsNothing);

      await tester.tap(find.byIcon(Icons.keyboard_hide_rounded));
      await tester.pump();

      expect(toggleCalls, 1, reason: 'tap should invoke onToggleKeyboard');
    },
  );

  testWidgets(
    'shows the show icon when the keyboard is hidden',
    (tester) async {
      final controller = TerminalSessionController(
        host: buildHost('toggle-hide'),
        repository: NoNetworkTerminalRepository(),
      );
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      var toggleCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalKeyboardBar(
              controller: controller,
              focusNode: focusNode,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              rows: const [
                TerminalKeyboardRow(
                  items: [
                    TerminalKeyboardItem.builtIn(
                      TerminalKeyboardAction.toggleKeyboard,
                    ),
                  ],
                ),
              ],
              globalSnippets: const [],
              fullscreen: false,
              onToggleFullscreen: () {},
              herdrPrefixKey: HerdrPrefixKey.controlB,
              onToggleKeyboard: () => toggleCalls++,
            ),
          ),
        ),
      );

      // Hidden IME → show icon.
      expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_hide_rounded), findsNothing);

      await tester.tap(find.byIcon(Icons.keyboard_rounded));
      await tester.pump();

      expect(toggleCalls, 1, reason: 'tap should invoke onToggleKeyboard');
    },
  );

  testWidgets(
    'icon updates when keyboardVisible flips between frames',
    (tester) async {
      final controller = TerminalSessionController(
        host: buildHost('toggle-flip'),
        repository: NoNetworkTerminalRepository(),
      );
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      var visible = false;
      late StateSetter externalSetState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                externalSetState = setState;
                return TerminalKeyboardBar(
                  controller: controller,
                  focusNode: focusNode,
                  palette: AppPalette.catppuccin,
                  brightness: Brightness.dark,
                  rows: const [
                    TerminalKeyboardRow(
                      items: [
                        TerminalKeyboardItem.builtIn(
                          TerminalKeyboardAction.toggleKeyboard,
                        ),
                      ],
                    ),
                  ],
                  globalSnippets: const [],
                  fullscreen: false,
                  onToggleFullscreen: () {},
                  herdrPrefixKey: HerdrPrefixKey.controlB,
                  keyboardVisible: visible,
                  onToggleKeyboard: () {},
                );
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);

      externalSetState(() => visible = true);
      await tester.pump();

      expect(find.byIcon(Icons.keyboard_hide_rounded), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_rounded), findsNothing);
    },
  );
}

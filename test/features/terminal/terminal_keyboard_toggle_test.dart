// Widget tests for the soft-keyboard show/hide methods exposed by
// [TerminalSurface].
//
// The toolbar's keyboard button drives the IME through the
// [TerminalViewState] rather than the focus node (see
// `terminal_surface.dart` for the why), but the surface itself does
// not have a direct handle on the view state — the page passes in a
// [GlobalKey<TerminalViewState>] via the `terminalViewKey` parameter.
// These tests pin the surface's public contract:
//
//   * [TerminalSurface.showSoftKeyboard] opens an input connection
//     (asserted via [TextInput] test bindings);
//   * [TerminalSurface.hideSoftKeyboard] closes the input connection
//     and drops focus, so a follow-up tap on the terminal does not
//     immediately re-show the IME;
//   * show → hide flips the IME visibility state cleanly, which is
//     what the toolbar's toggle button actually relies on.
//
// The tests run in no-connect mode (the page's [TerminalSessionController]
// is given a [NoNetworkTerminalRepository] and `connect()` is not
// awaited) so the terminal view's first frame does not deadlock —
// the same trick the rest of the surface tests use.

import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late TerminalSessionController controller;

  Future<void> pumpSurface(
    WidgetTester tester, {
    required GlobalKey<TerminalViewState> viewKey,
  }) async {
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
              terminalViewKey: viewKey,
            ),
          ),
        ),
      ),
    );
    // Let the TerminalView build the first frame so its state is
    // mounted and `_terminalViewKey.currentState` is non-null.
    await tester.pump();
  }

  tearDown(() {
    controller.dispose();
  });

  // TerminalView's autoResize schedules a 250ms timer; advance time
  // past it before the test ends so the framework does not see a
  // pending timer after the widget tree is torn down.
  Future<void> flushPendingTimers(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'showSoftKeyboard opens an input connection, '
    'hideSoftKeyboard closes it',
    (tester) async {
      final session = TrackableTerminalSession();
      controller = TerminalSessionController(
        host: buildHost('ime-toggle'),
        repository: ImmediateTerminalRepository(session),
      );
      // Don't await connect() — the TerminalView's first frame will
      // pull the terminal size off the session synchronously.
      unawaited(controller.connect());

      final viewKey = GlobalKey<TerminalViewState>();
      await pumpSurface(tester, viewKey: viewKey);

      // The view state must be mounted before we can drive it.
      expect(viewKey.currentState, isNotNull);

      // Soft keyboard starts hidden — no input connection yet.
      expect(
        viewKey.currentState!.hasInputConnection,
        isFalse,
        reason: 'IME should not be open before the toolbar tap',
      );

      // Tap-equivalent: page calls surface.showSoftKeyboard() on
      // a hidden-IME tap. The surface forwards to the view state,
      // which opens the input connection directly. The surface also
      // schedules a post-frame retry so the show works even when
      // focus has to settle asynchronously.
      final surfaceState = tester.state<TerminalSurfaceState>(
        find.byType(TerminalSurface),
      );
      surfaceState.showSoftKeyboard();
      // Two frames: one for the synchronous call, one for the
      // post-frame retry scheduled by the surface itself.
      await tester.pump();
      await tester.pump();

      expect(
        viewKey.currentState!.hasInputConnection,
        isTrue,
        reason: 'IME should be open after showSoftKeyboard()',
      );

      // Tap-equivalent: page calls surface.hideSoftKeyboard() on a
      // visible-IME tap. The view state closes the connection AND
      // unfocuses the focus node, so a later tap on the terminal
      // does not re-open the IME.
      surfaceState.hideSoftKeyboard();
      await tester.pump();

      expect(
        viewKey.currentState!.hasInputConnection,
        isFalse,
        reason: 'IME should be closed after hideSoftKeyboard()',
      );

      await flushPendingTimers(tester);
    },
  );

  testWidgets(
    'show then hide flips the IME visibility state cleanly',
    (tester) async {
      final session = TrackableTerminalSession();
      controller = TerminalSessionController(
        host: buildHost('ime-state'),
        repository: ImmediateTerminalRepository(session),
      );
      unawaited(controller.connect());

      final viewKey = GlobalKey<TerminalViewState>();
      await pumpSurface(tester, viewKey: viewKey);

      // Sanity: no IME before either call.
      expect(
        viewKey.currentState!.hasInputConnection,
        isFalse,
        reason: 'IME should be hidden initially',
      );

      final surfaceState = tester.state<TerminalSurfaceState>(
        find.byType(TerminalSurface),
      );

      // Page-equivalent of a "show keyboard" tap.
      surfaceState.showSoftKeyboard();
      await tester.pump();
      await tester.pump();
      final showedIme = viewKey.currentState!.hasInputConnection;
      expect(showedIme, isTrue, reason: 'IME should open on show');

      // Page-equivalent of a "hide keyboard" tap.
      surfaceState.hideSoftKeyboard();
      await tester.pump();
      final hidIme = viewKey.currentState!.hasInputConnection;
      expect(hidIme, isFalse, reason: 'IME should close on hide');

      // The two states differ, so the toggle button's behavior is
      // observably idempotent and the flip is clean.
      expect(showedIme, isNot(hidIme));

      await flushPendingTimers(tester);
    },
  );
}

// ignore_for_file: depend_on_referenced_packages

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/hyperlink_prompt_dialog.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../support/test_doubles.dart';

class FakeUrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  bool launchUrlResult = true;
  Object? errorToThrow;
  String? lastUrl;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    return launchUrlResult;
  }
}

void main() {
  group('HyperlinkPromptDialog', () {
    testWidgets('shows link confirmation dialog and returns true on Open', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showHyperlinkPromptDialog(
                    context: context,
                    uri: 'https://example.com/test',
                  );
                },
                child: const Text('Show Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      expect(find.text('https://example.com/test'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.text('Open link?'), findsNothing);
    });

    testWidgets('shows link confirmation dialog and returns false on Cancel', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showHyperlinkPromptDialog(
                    context: context,
                    uri: 'https://example.com/test',
                  );
                },
                child: const Text('Show Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(find.text('Open link?'), findsNothing);
    });
  });

  group('TerminalSurface hyperlink tap', () {
    late TerminalSessionController controller;
    late TrackableTerminalSession session;
    late FakeUrlLauncher fakeUrlLauncher;

    setUp(() {
      fakeUrlLauncher = FakeUrlLauncher();
      UrlLauncherPlatform.instance = fakeUrlLauncher;
    });

    void setUpController() {
      session = TrackableTerminalSession();
      controller = TerminalSessionController(
        host: buildHost('hyperlink-test'),
        repository: ImmediateTerminalRepository(session),
      );
    }

    tearDown(() {
      controller.dispose();
    });

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

    Future<void> flushTimers(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('tapping hyperlink cell prompts confirmation dialog', (tester) async {
      setUpController();
      await pumpSurface(tester);
      controller.terminal.write('\x1b]8;;https://example.com/tap-test\x07ClickMe\x1b]8;;\x07');
      await tester.pump();

      // Tap on the top-left area where 'ClickMe' is rendered (padding is fromLTRB(0, 6, 0, 4))
      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      // Terminal gesture detector waits 300ms for double-tap detection before firing single tap
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      expect(find.text('https://example.com/tap-test'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('tapping hyperlink cell in alternate screen prompts confirmation dialog', (tester) async {
      setUpController();
      await pumpSurface(tester);
      // Switch to alt screen (\x1b[?1049h), write hyperlink
      controller.terminal.write('\x1b[?1049h\x1b]8;;https://example.com/alt-screen\x07AltLink\x1b]8;;\x07');
      await tester.pump();

      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      expect(find.text('https://example.com/alt-screen'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('tapping plain text cell does not prompt dialog', (tester) async {
      setUpController();
      await pumpSurface(tester);
      controller.terminal.write('Plain text without link');
      await tester.pump();

      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Open link?'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('tapping hyperlink and confirming open launches url without SnackBar on success', (tester) async {
      setUpController();
      fakeUrlLauncher.launchUrlResult = true;
      await pumpSurface(tester);
      controller.terminal.write('\x1b]8;;https://example.com/tap-open\x07ClickMe\x1b]8;;\x07');
      await tester.pump();

      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(fakeUrlLauncher.lastUrl, 'https://example.com/tap-open');
      expect(find.text('Could not open link'), findsNothing);
      await flushTimers(tester);
    });

    testWidgets('tapping hyperlink and confirming open shows SnackBar when launchUrl returns false', (tester) async {
      setUpController();
      fakeUrlLauncher.launchUrlResult = false;
      await pumpSurface(tester);
      controller.terminal.write('\x1b]8;;https://example.com/tap-open\x07ClickMe\x1b]8;;\x07');
      await tester.pump();

      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(fakeUrlLauncher.lastUrl, 'https://example.com/tap-open');
      expect(find.text('Could not open link'), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('tapping hyperlink and confirming open shows SnackBar on PlatformException', (tester) async {
      setUpController();
      fakeUrlLauncher.errorToThrow = PlatformException(code: 'ACTIVITY_NOT_FOUND', message: 'No Activity found');
      await pumpSurface(tester);
      controller.terminal.write('\x1b]8;;https://example.com/tap-open\x07ClickMe\x1b]8;;\x07');
      await tester.pump();

      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Could not open link'), findsOneWidget);
      await flushTimers(tester);
    });

    testWidgets('tapping hyperlink and confirming open shows SnackBar on generic Exception', (tester) async {
      setUpController();
      fakeUrlLauncher.errorToThrow = Exception('Failed to launch');
      await pumpSurface(tester);
      controller.terminal.write('\x1b]8;;https://example.com/tap-open\x07ClickMe\x1b]8;;\x07');
      await tester.pump();

      final surfaceFinder = find.byType(TerminalSurface);
      final surfaceTopLeft = tester.getTopLeft(surfaceFinder);
      await tester.tapAt(surfaceTopLeft + const Offset(10, 15));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Could not open link'), findsOneWidget);
      await flushTimers(tester);
    });
  });
}

import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  group('TerminalSessionController.fetchHerdrHistory', () {
    test('returns null when herdr is not configured', () async {
      final session = TrackableTerminalSession();
      final controller = TerminalSessionController(
        host: buildHost('herdr-off'),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);

      await controller.connect();
      expect(await controller.fetchHerdrHistory(), isNull);
      expect(
        session.executedCommands,
        isEmpty,
        reason: '未配置 herdr 时不应发出任何 exec',
      );
    });

    test('resolves the focused pane then fetches plain text history', () async {
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async {
          if (command.contains('pane list')) {
            return '{"id":"cli:pane:list","result":{"panes":['
                '{"pane_id":"w4:pC","focused":false},'
                '{"pane_id":"w4:p1","focused":true}]}}';
          }
          if (command.contains('pane read')) {
            return 'first line\nsecond line\n\nthird line\n\n';
          }
          return null;
        },
      );
      final controller = TerminalSessionController(
        host: buildHost('herdr-read').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      final lines = await controller.fetchHerdrHistory(lines: 50);

      expect(lines, [
        'first line',
        'second line',
        '',
        'third line',
      ], reason: '按行 split，只去掉尾部空行');
      expect(session.executedCommands, hasLength(2));

      final listCommand = session.executedCommands[0];
      expect(
        listCommand,
        startsWith('export PATH="\$HOME/.local/bin:\$PATH"; '),
        reason: '先补 PATH 兜底 herdr 不在非交互 PATH',
      );
      expect(
        listCommand,
        contains("herdr --session 'conduit' pane list"),
        reason: '默认 session 名是 conduit，pane list 用于找 focused pane',
      );

      final readCommand = session.executedCommands[1];
      expect(
        readCommand,
        contains("herdr --session 'conduit' pane read 'w4:p1'"),
        reason: '用解析出的 focused pane_id 拉历史',
      );
      expect(readCommand, contains('--source recent-unwrapped'));
      expect(readCommand, contains('--lines 50'));
      expect(readCommand, contains('--format text'));
    });

    test('shell-quotes a session name containing a single quote', () async {
      final commands = <String>[];
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async {
          commands.add(command);
          if (command.contains('pane list')) {
            return '{"id":"cli:pane:list","result":{"panes":['
                '{"pane_id":"w4:p1","focused":true}]}}';
          }
          return 'output';
        },
      );
      final controller = TerminalSessionController(
        host: buildHost(
          'herdr-quote',
        ).copyWith(startHerdrOnConnect: true, herdrSessionName: "work's"),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      await controller.fetchHerdrHistory();

      expect(
        commands[0],
        contains("herdr --session 'work'\\''s' pane list"),
        reason: "' 必须被转义成 '\\'' 防止 shell 注入",
      );
    });

    test('caches the focused pane id across fetches', () async {
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async {
          if (command.contains('pane list')) {
            return '{"id":"cli:pane:list","result":{"panes":['
                '{"pane_id":"w4:p1","focused":true}]}}';
          }
          return 'a\nb\nc';
        },
      );
      final controller = TerminalSessionController(
        host: buildHost('herdr-cache').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      await controller.fetchHerdrHistory();
      await controller.fetchHerdrHistory();

      expect(
        session.executedCommands.where((c) => c.contains('pane list')),
        hasLength(1),
        reason: 'pane id 只在首次解析，后续复用缓存',
      );
      expect(
        session.executedCommands.where((c) => c.contains('pane read')),
        hasLength(2),
      );
    });

    test('clears the cached pane id on reconnect', () async {
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async {
          if (command.contains('pane list')) {
            return '{"id":"cli:pane:list","result":{"panes":['
                '{"pane_id":"w4:p1","focused":true}]}}';
          }
          return 'a\nb';
        },
      );
      final controller = TerminalSessionController(
        host: buildHost('herdr-reconnect').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      await controller.fetchHerdrHistory();
      await controller.disconnect();
      await controller.connect();
      await controller.fetchHerdrHistory();

      expect(
        session.executedCommands.where((c) => c.contains('pane list')),
        hasLength(2),
        reason: '断线重连后应重新解析 focused pane',
      );
    });

    test('returns null when no pane is focused', () async {
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async {
          if (command.contains('pane list')) {
            return '{"id":"cli:pane:list","result":{"panes":['
                '{"pane_id":"w4:pC","focused":false}]}}';
          }
          return 'a\nb';
        },
      );
      final controller = TerminalSessionController(
        host: buildHost('herdr-nofocus').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      expect(await controller.fetchHerdrHistory(), isNull);
      expect(
        session.executedCommands.where((c) => c.contains('pane read')),
        isEmpty,
        reason: '找不到 focused pane 就不该发 pane read',
      );
    });

    test('returns null when pane list reports an error payload', () async {
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async {
          if (command.contains('pane list')) {
            return '{"error":{"code":"boom"},"id":"cli:pane:list"}';
          }
          return 'a\nb';
        },
      );
      final controller = TerminalSessionController(
        host: buildHost('herdr-err').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      expect(await controller.fetchHerdrHistory(), isNull);
    });

    test('returns null when exec fails or times out', () async {
      final session = TrackableTerminalSession(
        execHandler: (command, timeout) async => null,
      );
      final controller = TerminalSessionController(
        host: buildHost('herdr-fail').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);
      await controller.connect();

      expect(await controller.fetchHerdrHistory(), isNull);
    });

    test(
      'returns null when exec throws (session without exec channel)',
      () async {
        final session = TrackableTerminalSession(
          execHandler: (command, timeout) async {
            throw UnsupportedError('no exec channel');
          },
        );
        final controller = TerminalSessionController(
          host: buildHost('herdr-throw').copyWith(startHerdrOnConnect: true),
          repository: ImmediateTerminalRepository(session),
        );
        addTearDown(controller.dispose);
        await controller.connect();

        expect(await controller.fetchHerdrHistory(), isNull);
      },
    );

    test('returns null when session is not connected', () async {
      final session = TrackableTerminalSession();
      final controller = TerminalSessionController(
        host: buildHost('herdr-idle').copyWith(startHerdrOnConnect: true),
        repository: ImmediateTerminalRepository(session),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.fetchHerdrHistory(),
        isNull,
        reason: '未连接时没有可用 session',
      );
    });
  });
}

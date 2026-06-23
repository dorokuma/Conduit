import 'dart:async';

import 'package:conduit/features/hosts/data/dartssh2_ssh_key_service.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/ssh_key.dart';
import 'package:conduit/features/hosts/presentation/host_form_page.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  group('SavedHost.isValid', () {
    const base = SavedHost(
      id: 'id',
      name: 'name',
      host: '192.168.1.1',
      port: 22,
      username: 'user',
      authMethod: SshAuthMethod.password,
      password: 'p',
    );

    test('rejects empty id, name, host, username', () {
      expect(base.copyWith(id: '').isValid, isFalse);
      expect(base.copyWith(name: ' ').isValid, isFalse);
      expect(base.copyWith(host: '').isValid, isFalse);
      expect(base.copyWith(username: '').isValid, isFalse);
    });

    test('rejects out-of-range ports', () {
      expect(base.copyWith(port: 0).isValid, isFalse);
      expect(base.copyWith(port: 65536).isValid, isFalse);
      expect(base.copyWith(port: 1).isValid, isTrue);
      expect(base.copyWith(port: 65535).isValid, isTrue);
    });

    test('rejects out-of-range timeouts', () {
      expect(base.copyWith(connectionTimeoutSeconds: 2).isValid, isFalse);
      expect(base.copyWith(connectionTimeoutSeconds: 121).isValid, isFalse);
      expect(base.copyWith(connectionTimeoutSeconds: 3).isValid, isTrue);
      expect(base.copyWith(connectionTimeoutSeconds: 120).isValid, isTrue);
    });

    test('requires credential for the chosen auth method', () {
      expect(base.copyWith(password: '').isValid, isFalse);
      expect(
        base
            .copyWith(authMethod: SshAuthMethod.privateKey, privateKey: '')
            .isValid,
        isFalse,
      );
      expect(
        base
            .copyWith(authMethod: SshAuthMethod.privateKey, privateKey: 'pem')
            .isValid,
        isTrue,
      );
      expect(
        base
            .copyWith(authMethod: SshAuthMethod.hardwareKey, privateKey: '')
            .isValid,
        isFalse,
      );
      expect(
        base
            .copyWith(
              authMethod: SshAuthMethod.hardwareKey,
              privateKey: 'openssh-sk-stub',
            )
            .isValid,
        isTrue,
      );
    });
  });

  group('SavedHost round-trip', () {
    test('toJson then fromJson preserves all fields', () {
      final original = SavedHost(
        id: 'id',
        name: 'My Host',
        host: 'example.com',
        port: 2222,
        username: 'root',
        authMethod: SshAuthMethod.privateKey,
        privateKey: '-----BEGIN-----',
        passphrase: 'pp',
        tags: const ['prod', 'edge'],
        connectionTimeoutSeconds: 30,
        useMosh: true,
        moshLocale: 'en_US.UTF-8',
        startTmuxOnConnect: true,
        tmuxPrefixKey: TmuxPrefixKey.controlA,
        tmuxStartDirectory: '~/projects',
        lastConnectedAt: DateTime.parse('2025-01-02T03:04:05Z'),
      );

      final decoded = SavedHost.fromJson(original.toJson());

      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.host, original.host);
      expect(decoded.port, original.port);
      expect(decoded.username, original.username);
      expect(decoded.authMethod, original.authMethod);
      expect(decoded.privateKey, original.privateKey);
      expect(decoded.passphrase, original.passphrase);
      expect(decoded.tags, original.tags);
      expect(
        decoded.connectionTimeoutSeconds,
        original.connectionTimeoutSeconds,
      );
      expect(decoded.useMosh, original.useMosh);
      expect(decoded.moshLocale, original.moshLocale);
      expect(decoded.predictiveEchoEnabled, original.predictiveEchoEnabled);
      expect(decoded.startTmuxOnConnect, original.startTmuxOnConnect);
      expect(decoded.tmuxPrefixKey, original.tmuxPrefixKey);
      expect(decoded.tmuxStartDirectory, original.tmuxStartDirectory);
      expect(decoded.lastConnectedAt, original.lastConnectedAt);
    });

    test('older saved hosts default to no tmux start with Ctrl-B', () {
      final decoded = SavedHost.fromJson(const {
        'id': 'id',
        'name': 'Legacy Host',
        'host': 'example.com',
        'port': 22,
        'username': 'root',
        'authMethod': 'password',
        'password': 'secret',
      });

      expect(decoded.startTmuxOnConnect, isFalse);
      expect(decoded.tmuxPrefixKey, TmuxPrefixKey.controlB);
      expect(decoded.tmuxStartDirectory, isEmpty);
    });

    test('preserves hardware key auth method', () {
      const original = SavedHost(
        id: 'id',
        name: 'Hardware Host',
        host: 'example.com',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.hardwareKey,
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----',
      );

      final decoded = SavedHost.fromJson(original.toJson());

      expect(decoded.authMethod, SshAuthMethod.hardwareKey);
      expect(decoded.privateKey, original.privateKey);
      expect(decoded.passphrase, isEmpty);
    });
  });

  group('HostFormPage auth validation', () {
    testWidgets('private key rejects OpenSSH hardware key stubs', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: HostFormPage()));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Host',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host or IP'),
        'example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'root',
      );
      await tester.tap(find.text('Private key').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key'),
        fakeSecurityKeyPem(),
      );
      final listPosition =
          ((find.byType(Scrollable).evaluate().first as StatefulElement).state
                  as ScrollableState)
              .position;
      final addButton = find.text('Add machine');
      for (var i = 0; i < 40 && addButton.evaluate().isEmpty; i++) {
        listPosition.jumpTo(
          (listPosition.pixels + 200).clamp(0.0, listPosition.maxScrollExtent),
        );
        await tester.pump();
      }
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      listPosition.jumpTo(0);
      await tester.pumpAndSettle();

      expect(
        find.text('This is a hardware-key stub. Choose Hardware key instead.'),
        findsOneWidget,
      );
    });

    testWidgets('shows a key summary for a recognized private key', (
      tester,
    ) async {
      final generated = const Dartssh2SshKeyService().generateEd25519(
        comment: 'me@conduit',
      );

      await tester.pumpWidget(const MaterialApp(home: HostFormPage()));
      await tester.tap(find.text('Private key').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key'),
        generated.privateKeyPem,
      );
      await tester.pump();

      expect(find.text('Ed25519'), findsOneWidget);
      expect(find.text('me@conduit'), findsOneWidget);
      expect(find.text('View public key'), findsOneWidget);
      expect(find.text(generated.details.fingerprintSha256), findsOneWidget);
    });

    testWidgets('encrypted key without a passphrase asks for one on save', (
      tester,
    ) async {
      final generated = const Dartssh2SshKeyService().generateEd25519(
        passphrase: 'locked',
      );

      await tester.pumpWidget(const MaterialApp(home: HostFormPage()));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Host',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host or IP'),
        'example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'root',
      );
      await tester.tap(find.text('Private key').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key'),
        generated.privateKeyPem,
      );
      final listPosition =
          ((find.byType(Scrollable).evaluate().first as StatefulElement).state
                  as ScrollableState)
              .position;
      final addButton = find.text('Add machine');
      for (var i = 0; i < 40 && addButton.evaluate().isEmpty; i++) {
        listPosition.jumpTo(
          (listPosition.pixels + 200).clamp(0.0, listPosition.maxScrollExtent),
        );
        await tester.pump();
      }
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      listPosition.jumpTo(0);
      await tester.pumpAndSettle();

      expect(
        find.text('Enter the key passphrase to unlock it.'),
        findsOneWidget,
      );
    });

    testWidgets('verifies an encrypted passphrase and unlocks the card', (
      tester,
    ) async {
      final generated = const Dartssh2SshKeyService().generateEd25519(
        comment: 'locked@conduit',
        passphrase: 'open me',
      );

      await tester.pumpWidget(
        const MaterialApp(home: HostFormPage(keyService: _SyncKeyService())),
      );
      await tester.tap(find.text('Private key').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key'),
        generated.privateKeyPem,
      );
      await tester.pump();
      expect(
        find.text(
          'This key is encrypted. Enter its passphrase below to unlock it.',
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Key passphrase'),
        'open me',
      );
      await tester.pump();
      expect(find.text('Checking passphrase…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Ed25519'), findsOneWidget);
      expect(find.text('locked@conduit'), findsOneWidget);
    });

    testWidgets('a stale verify result cannot overwrite a cleared passphrase', (
      tester,
    ) async {
      final service = _ControllableKeyService();
      final generated = const Dartssh2SshKeyService().generateEd25519(
        passphrase: 'secret',
      );
      const encryptedNotice =
          'This key is encrypted. Enter its passphrase below to unlock it.';

      await tester.pumpWidget(
        MaterialApp(home: HostFormPage(keyService: service)),
      );
      await tester.tap(find.text('Private key').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key'),
        generated.privateKeyPem,
      );
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Key passphrase'),
        'secret',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(service.pending, 1);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Key passphrase'),
        '',
      );
      await tester.pump();
      expect(find.text(encryptedNotice), findsOneWidget);

      service.completeLast(const SshKeyInspection.wrongPassphrase());
      await tester.pump();

      expect(find.text(encryptedNotice), findsOneWidget);
      expect(
        find.text('That passphrase did not match this key.'),
        findsNothing,
      );
    });
  });

  group('HostsController', () {
    test('upsert + load surfaces persisted hosts', () async {
      final repository = FakeHostsRepository();
      final controller = HostsController(repository);
      await controller.load();

      await controller.upsert(buildHost('a'));
      expect(controller.hosts, hasLength(1));
      expect(repository.persisted, hasLength(1));
    });

    test('markConnected uses the latest version of the host', () async {
      final repository = FakeHostsRepository();
      final controller = HostsController(repository);
      await controller.load();
      await controller.upsert(buildHost('a', username: 'old'));
      final stale = buildHost('a', username: 'old');
      await controller.upsert(buildHost('a', username: 'new'));

      await controller.markConnected(stale);

      final saved = repository.persisted.single;
      expect(saved.username, 'new');
      expect(saved.lastConnectedAt, isNotNull);
    });
  });
}

class _SyncKeyService implements SshKeyService {
  const _SyncKeyService();

  SshKeyService get _delegate => const Dartssh2SshKeyService();

  @override
  SshKeyInspection inspect(String pem, {String passphrase = ''}) =>
      _delegate.inspect(pem, passphrase: passphrase);

  @override
  Future<SshKeyInspection> verify(String pem, {String passphrase = ''}) =>
      Future.value(_delegate.inspect(pem, passphrase: passphrase));

  @override
  GeneratedSshKey generateEd25519({
    String comment = '',
    String passphrase = '',
  }) => _delegate.generateEd25519(comment: comment, passphrase: passphrase);
}

class _ControllableKeyService implements SshKeyService {
  final _delegate = const Dartssh2SshKeyService();
  final _completers = <Completer<SshKeyInspection>>[];

  int get pending => _completers.where((c) => !c.isCompleted).length;

  void completeLast(SshKeyInspection result) =>
      _completers.last.complete(result);

  @override
  SshKeyInspection inspect(String pem, {String passphrase = ''}) =>
      _delegate.inspect(pem, passphrase: passphrase);

  @override
  Future<SshKeyInspection> verify(String pem, {String passphrase = ''}) {
    final completer = Completer<SshKeyInspection>();
    _completers.add(completer);
    return completer.future;
  }

  @override
  GeneratedSshKey generateEd25519({
    String comment = '',
    String passphrase = '',
  }) => _delegate.generateEd25519(comment: comment, passphrase: passphrase);
}

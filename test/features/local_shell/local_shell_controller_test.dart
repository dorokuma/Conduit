import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/local_shell/data/local_shell_platform.dart';
import 'package:conduit/features/local_shell/domain/local_shell_state.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

class FakeLocalShellPlatform extends LocalShellPlatform {
  FakeLocalShellPlatform(this.environment);

  final FutureOr<LocalShellEnvironment?> Function() environment;
  int loadCount = 0;

  @override
  Future<LocalShellEnvironment?> load() async {
    loadCount++;
    return environment();
  }
}

void main() {
  group('LocalShellController', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('conduit_shell_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    LocalShellEnvironment environment() => LocalShellEnvironment(
      nativeLibraryDir: tempDir.path,
      filesDir: tempDir.path,
      sharedStorageFeatureEnabled: true,
      sharedStorageDir: '/storage/emulated/0',
      sharedStorageAccessGranted: true,
      supportedAbis: const ['arm64-v8a'],
    );

    MockClient offlineClient() => MockClient((request) {
      throw http.ClientException('offline', request.url);
    });

    Future<void> seedLegacyInstall(String directoryName) async {
      await File(
        p.join(
          tempDir.path,
          directoryName,
          'rootfs',
          'var',
          'lib',
          '.conduit-firstboot-done',
        ),
      ).create(recursive: true);
    }

    test('recognises a pre-redesign arch install untouched', () async {
      await seedLegacyInstall('archlinux');
      await File(
        p.join(tempDir.path, 'archlinux', '.version'),
      ).writeAsString('archlinux-aarch64-pd-v4.22.1');

      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();

      final instance = controller.instances.single;
      expect(instance.id, 'archlinux');
      expect(instance.distroId, 'archlinux');
      expect(instance.name, 'Arch Linux');
      final state = controller.stateFor('archlinux');
      expect(state.stage, LocalShellStage.ready);
      expect(state.installedVersion, 'archlinux-aarch64-pd-v4.22.1');
      expect(controller.defaultInstance?.id, 'archlinux');
    });

    test('discovers named instances from their metadata files', () async {
      await seedLegacyInstall('debian-2');
      await File(
        p.join(tempDir.path, 'debian-2', '.conduit-instance'),
      ).writeAsString(jsonEncode({'distroId': 'debian', 'name': 'Work'}));

      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();

      final instance = controller.instances.single;
      expect(instance.id, 'debian-2');
      expect(instance.distroId, 'debian');
      expect(instance.name, 'Work');
      expect(controller.stateFor('debian-2').stage, LocalShellStage.ready);
    });

    test('installNew waits for an in-flight probe', () async {
      final probe = Completer<LocalShellEnvironment?>();
      final platform = FakeLocalShellPlatform(() => probe.future);
      final controller = LocalShellController(
        platform: platform,
        httpClient: offlineClient(),
      );

      unawaited(controller.refresh());
      final install = controller.installNew('archlinux');
      await Future<void>.delayed(Duration.zero);

      probe.complete(environment());
      await install;

      expect(platform.loadCount, 1);
      final instance = controller.instances.single;
      expect(instance.id, 'archlinux');
      final state = controller.stateFor(instance.id);
      expect(state.stage, LocalShellStage.failed);
      expect(state.error?.kind, LocalShellErrorKind.network);
    });

    test(
      'installNew mints a suffixed instance next to an existing one',
      () async {
        await seedLegacyInstall('debian');

        final controller = LocalShellController(
          platform: FakeLocalShellPlatform(environment),
          httpClient: offlineClient(),
        );
        await controller.refresh();
        await controller.installNew('debian', name: 'Playground');

        expect(controller.instances, hasLength(2));
        final second = controller.instances.last;
        expect(second.id, 'debian-2');
        expect(second.distroId, 'debian');
        expect(second.name, 'Playground');
        expect(controller.stateFor('debian-2').stage, LocalShellStage.failed);
        expect(controller.stateFor('debian').stage, LocalShellStage.ready);
        expect(
          File(
            p.join(tempDir.path, 'debian-2', '.conduit-instance'),
          ).existsSync(),
          isTrue,
        );
      },
    );

    test('rename persists across rediscovery', () async {
      await seedLegacyInstall('archlinux');

      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();
      await controller.rename('archlinux', 'My Arch');
      expect(controller.instances.single.name, 'My Arch');

      final revived = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await revived.refresh();
      expect(revived.instances.single.name, 'My Arch');
      expect(revived.instances.single.distroId, 'archlinux');
    });

    test('remove deletes the environment and forgets the instance', () async {
      await seedLegacyInstall('archlinux');

      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();
      await controller.remove('archlinux');

      expect(controller.instances, isEmpty);
      expect(controller.state.stage, LocalShellStage.notInstalled);
    });

    test('defaultInstance follows the last opened instance', () async {
      await seedLegacyInstall('archlinux');
      await seedLegacyInstall('debian');

      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();
      expect(controller.defaultInstance?.id, 'archlinux');

      await controller.markOpened('debian');
      expect(controller.defaultInstance?.id, 'debian');

      final revived = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await revived.refresh();
      expect(revived.defaultInstance?.id, 'debian');
    });

    test('requireLaunch resolves instance and distro from host ids', () async {
      await seedLegacyInstall('debian-2');
      await File(
        p.join(tempDir.path, 'debian-2', '.conduit-instance'),
      ).writeAsString(jsonEncode({'distroId': 'debian', 'name': 'Work'}));

      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();

      final launch = await controller.requireLaunch(
        '${localShellHostIdFor('debian-2')}#12345',
      );
      expect(launch.distro.id, 'debian');
      expect(launch.paths.installRoot, p.join(tempDir.path, 'debian-2'));
    });

    test('localHost mints numbered ids for additional sessions', () async {
      await seedLegacyInstall('archlinux');
      final controller = LocalShellController(
        platform: FakeLocalShellPlatform(environment),
      );
      await controller.refresh();

      final instance = controller.instances.single;
      final first = controller.localHost(instance);
      expect(first.id, localShellHostIdFor('archlinux'));
      expect(first.name, 'Arch Linux');
      expect(first.isLocal, isTrue);

      final second = controller.localHost(instance, sessionNumber: 2);
      expect(second.name, 'Arch Linux (2)');
      expect(second.id, isNot(first.id));
      expect(localShellInstanceIdFromHostId(second.id), 'archlinux');
    });
  });
}

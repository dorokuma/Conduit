import 'package:conduit/features/local_shell/local_shell_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('defaultLocalShellDistros', () {
    final catalog = defaultLocalShellDistros();

    test('has unique ids and names', () {
      final ids = catalog.map((distro) => distro.id).toSet();
      final names = catalog.map((distro) => distro.name).toSet();
      expect(ids.length, catalog.length);
      expect(names.length, catalog.length);
    });

    test('keeps Arch Linux first under its shipped install directory id', () {
      expect(catalog.first.id, defaultLocalShellDistroId);
      expect(catalog.first.id, 'archlinux');
      expect(catalog.first.name, 'Arch Linux');
    });

    test('every entry points at a verified https aarch64 archive', () {
      for (final distro in catalog) {
        expect(distro.manifest.archiveUrl.scheme, 'https', reason: distro.id);
        expect(
          distro.manifest.archiveUrl.path,
          contains('aarch64'),
          reason: distro.id,
        );
        expect(
          distro.manifest.archiveUrl.path,
          endsWith('.tar.xz'),
          reason: distro.id,
        );
        expect(
          RegExp(r'^[0-9a-f]{64}$').hasMatch(distro.manifest.sha256),
          isTrue,
          reason: distro.id,
        );
        expect(
          distro.manifest.downloadSizeBytes,
          greaterThan(1024 * 1024),
          reason: distro.id,
        );
        expect(distro.manifest.version, isNotEmpty, reason: distro.id);
      }
    });

    test('every entry carries an update command and login shell', () {
      for (final distro in catalog) {
        expect(distro.updateCommand, isNotEmpty, reason: distro.id);
        expect(distro.loginCommand, isNotEmpty, reason: distro.id);
        expect(distro.loginCommand.first, startsWith('/bin/'));
      }
    });

    test('alpine logs in without bash', () {
      final alpine = catalog.singleWhere((distro) => distro.id == 'alpine');
      expect(alpine.loginCommand.first, '/bin/sh');
    });

    test('pacman distros initialise their keyring during setup', () {
      for (final id in ['archlinux', 'manjaro']) {
        final distro = catalog.singleWhere((entry) => entry.id == id);
        final script = distro.setupCommands.join('\n');
        final entropyIndex = script.indexOf('/dev/urandom');
        final initIndex = script.indexOf('pacman-key --init');
        final populateIndex = script.indexOf('pacman-key --populate');
        expect(entropyIndex, greaterThanOrEqualTo(0), reason: id);
        expect(initIndex, greaterThan(entropyIndex), reason: id);
        expect(populateIndex, greaterThan(initIndex), reason: id);
      }
    });

    test('arch pins the Arch Linux ARM mirror', () {
      final arch = catalog.first;
      expect(arch.setupCommands.join('\n'), contains('archlinuxarm.org'));
    });

    test('debian family regenerates locales non-interactively', () {
      for (final id in ['debian', 'ubuntu']) {
        final distro = catalog.singleWhere((entry) => entry.id == id);
        expect(
          distro.setupCommands.join('\n'),
          contains('DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales'),
          reason: id,
        );
      }
    });
  });
}

import 'package:conduit/features/local_shell/domain/first_boot_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const generator = FirstBootScript();
  const config = FirstBootConfig(
    distroName: 'Debian',
    updateCommand: 'apt update && apt upgrade',
    setupCommands: ['echo first-setup-step', 'echo second-setup-step'],
    doneMarkerPath: '/var/lib/.conduit-firstboot-done',
  );

  group('FirstBootScript', () {
    final script = generator.generate(config);

    test('is POSIX sh, not bash', () {
      expect(script, startsWith('#!/bin/sh\n'));
      expect(script, contains('set -eu\n'));
      expect(script, isNot(contains('pipefail')));
    });

    test('configures DNS for every nameserver', () {
      expect(script, contains('> /etc/resolv.conf'));
      expect(script, contains('nameserver 1.1.1.1'));
      expect(script, contains('nameserver 8.8.8.8'));
    });

    test('runs the distro setup commands in order', () {
      final firstIndex = script.indexOf('echo first-setup-step');
      final secondIndex = script.indexOf('echo second-setup-step');
      expect(firstIndex, greaterThanOrEqualTo(0));
      expect(secondIndex, greaterThan(firstIndex));
    });

    test('omits the setup section when a distro needs none', () {
      const bare = FirstBootConfig(
        distroName: 'Alpine Linux',
        updateCommand: 'apk update && apk upgrade',
        setupCommands: [],
        doneMarkerPath: '/var/lib/.conduit-firstboot-done',
      );
      expect(generator.generate(bare), isNot(contains('distro setup')));
    });

    test('is idempotent via a completion marker', () {
      expect(script, contains('if [ -f "/var/lib/.conduit-firstboot-done" ]'));
      expect(script, contains('touch "/var/lib/.conduit-firstboot-done"'));
    });

    test('installs a one-time welcome naming the distro and its updater', () {
      expect(script, contains('/etc/profile.d/conduit-welcome.sh'));
      expect(script, contains('Debian - running locally via Conduit.'));
      expect(script, contains('apt update && apt upgrade'));
    });
  });
}

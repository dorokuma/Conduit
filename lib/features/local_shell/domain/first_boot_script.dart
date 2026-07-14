class FirstBootConfig {
  const FirstBootConfig({
    required this.distroName,
    required this.updateCommand,
    required this.setupCommands,
    required this.doneMarkerPath,
    this.nameservers = const ['1.1.1.1', '8.8.8.8'],
  });

  final String distroName;
  final String updateCommand;
  final List<String> setupCommands;

  final String doneMarkerPath;
  final List<String> nameservers;
}

class FirstBootScript {
  const FirstBootScript();

  String generate(FirstBootConfig config) {
    final buffer = StringBuffer()
      ..writeln('#!/bin/sh')
      ..writeln('set -eu')
      ..writeln()
      ..writeln('# Idempotent: bail out if first boot already completed.')
      ..writeln('if [ -f "${config.doneMarkerPath}" ]; then')
      ..writeln('  exit 0')
      ..writeln('fi')
      ..writeln()
      ..writeln('# --- DNS resolution ---')
      ..writeln('rm -f /etc/resolv.conf');
    for (final nameserver in config.nameservers) {
      buffer.writeln('echo "nameserver $nameserver" >> /etc/resolv.conf');
    }
    buffer
      ..writeln()
      ..writeln('# --- hosts ---')
      ..writeln('cat > /etc/hosts <<EOF')
      ..writeln('127.0.0.1 localhost')
      ..writeln('::1 localhost')
      ..writeln('EOF');
    if (config.setupCommands.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('# --- distro setup ---');
      for (final command in config.setupCommands) {
        buffer.writeln(command);
      }
    }
    buffer
      ..writeln()
      ..writeln('# --- first-login welcome (shown once) ---')
      ..writeln('mkdir -p /etc/profile.d')
      ..writeln("cat > /etc/profile.d/conduit-welcome.sh <<'WELCOME'")
      ..writeln('if [ ! -f "\$HOME/.conduit-welcomed" ]; then')
      ..writeln('  echo "${config.distroName} - running locally via Conduit."')
      ..writeln(
        '  echo "Tip: run  ${config.updateCommand}  to refresh before '
        'installing packages."',
      )
      ..writeln('  echo')
      ..writeln('  touch "\$HOME/.conduit-welcomed" 2>/dev/null || true')
      ..writeln('fi')
      ..writeln('WELCOME')
      ..writeln()
      ..writeln('# --- mark complete ---')
      ..writeln('mkdir -p "\$(dirname "${config.doneMarkerPath}")"')
      ..writeln('touch "${config.doneMarkerPath}"');

    return buffer.toString();
  }
}

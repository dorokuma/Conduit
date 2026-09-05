import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/logging/app_logger.dart';
import 'package:conduit/features/local_shell/domain/proot_command.dart';

class ProotRunResult {
  const ProotRunResult({required this.exitCode, required this.stderr});

  final int exitCode;
  final String stderr;
}

// [PRIVACY RED LINE]: Do NOT log script or shell output/input contents.
Future<ProotRunResult> runProot(ProotCommand command) async {
  AppLogger.localShell('Execute proot command', metadata: {
    'executable': command.executable,
    'args_count': command.arguments.length,
  });

  final process = await Process.start(
    command.executable,
    command.arguments,
    environment: command.environment,
  );

  final stderrBuffer = StringBuffer();
  final stdoutDrain = process.stdout.drain<void>();
  final stderrDrain = process.stderr
      .transform(utf8.decoder)
      .forEach(stderrBuffer.write);

  final exitCode = await process.exitCode;
  await stdoutDrain;
  await stderrDrain;

  AppLogger.localShell('Proot command finished', metadata: {
    'exit_code': exitCode,
  });

  return ProotRunResult(exitCode: exitCode, stderr: stderrBuffer.toString());
}

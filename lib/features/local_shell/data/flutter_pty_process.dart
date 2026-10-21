import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/logging/app_logger.dart';
import 'package:conduit/features/local_shell/domain/pty_process.dart';
import 'package:flutter_pty/flutter_pty.dart';

// [PRIVACY RED LINE]: Strictly prohibit logging terminal output contents,
// keystrokes, user command lines, or environment variable values containing tokens.
class FlutterPtyProcess implements PtyProcess {
  FlutterPtyProcess(this._pty);

  factory FlutterPtyProcess.start({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    int rows = 25,
    int columns = 80,
    String? workingDirectory,
  }) {
    AppLogger.pty('Start PTY process', metadata: {
      'executable': executable,
      'args_count': arguments.length,
      'rows': rows,
      'columns': columns,
    });
    final pty = Pty.start(
      executable,
      arguments: arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      rows: rows,
      columns: columns,
    );
    return FlutterPtyProcess(pty);
  }

  final Pty _pty;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode.then((code) {
        AppLogger.pty('PTY process exited', metadata: {'exit_code': code});
        return code;
      });

  @override
  void write(Uint8List data) {
    // Red line: Write data without logging buffer content.
    _pty.write(data);
  }

  @override
  void resize(int rows, int columns) {
    AppLogger.pty('PTY resize', metadata: {'rows': rows, 'columns': columns});
    _pty.resize(rows, columns);
  }

  @override
  void kill() {
    AppLogger.pty('Kill PTY process');
    try {
      _pty.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }
}

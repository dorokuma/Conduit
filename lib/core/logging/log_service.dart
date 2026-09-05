import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/logging/log_models.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LogService {
  LogService._();

  static final LogService instance = LogService._();

  static const String appVersion = '1.4.44+69';
  static const int maxFileSizeBytes = 2 * 1024 * 1024; // 2MB
  static const int maxRotatedLogs = 7;
  static const String activeLogFileName = 'app.log';
  static const String activeSessionFileName = '.session_active';

  Directory? _logDir;
  Directory? _crashDir;
  File? _activeLogFile;
  File? _activeSessionFile;
  SessionInfo? _currentSession;
  bool _initialized = false;
  bool verboseLogging = false;

  Directory? get logDirectory => _logDir;
  Directory? get crashDirectory => _crashDir;
  SessionInfo? get currentSession => _currentSession;
  bool get isInitialized => _initialized;

  Future<void> init({Directory? overrideDir, String? customAbi}) async {
    try {
      Directory baseDir;
      if (overrideDir != null) {
        baseDir = overrideDir;
      } else {
        try {
          baseDir = await getApplicationSupportDirectory();
        } catch (_) {
          baseDir = await getApplicationDocumentsDirectory();
        }
      }

      _logDir = Directory(p.join(baseDir.path, 'logs'));
      if (!_logDir!.existsSync()) {
        _logDir!.createSync(recursive: true);
      }

      _crashDir = Directory(p.join(_logDir!.path, 'crash'));
      if (!_crashDir!.existsSync()) {
        _crashDir!.createSync(recursive: true);
      }

      _activeLogFile = File(p.join(_logDir!.path, activeLogFileName));
      _activeSessionFile = File(p.join(_logDir!.path, activeSessionFileName));

      _checkAndRotateLog();

      final sessionId = '${DateTime.now().millisecondsSinceEpoch}_${1000 + DateTime.now().microsecond % 9000}';
      _currentSession = SessionInfo(
        sessionId: sessionId,
        startTime: DateTime.now().toUtc(),
        appVersion: appVersion,
        osVersion: Platform.operatingSystemVersion,
        platform: Platform.operatingSystem,
        deviceModel: Platform.localHostname,
        abi: customAbi,
      );

      _checkPreviousSessionAbnormalExit();

      _writeActiveSessionMarker(_currentSession!);

      _initialized = true;

      log(
        LogLevel.info,
        'Session',
        '===== CONDUIT SESSION STARTED (id: ${currentSession!.sessionId}) =====',
      );
      log(
        LogLevel.info,
        'Session',
        'Environment: App: $appVersion | OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} | ABI: ${customAbi ?? 'unknown'} | Dart: ${Platform.version.split(' ').first}',
      );
    } catch (e, st) {
      debugPrint('[LogService] Initialization failed: $e\n$st');
    }
  }

  void ensureSessionMarker() {
    if (!_initialized || _currentSession == null || _activeSessionFile == null) return;
    if (!_activeSessionFile!.existsSync()) {
      _writeActiveSessionMarker(_currentSession!);
    }
  }

  void _checkAndRotateLog() {
    if (_activeLogFile != null && _activeLogFile!.existsSync()) {
      if (_activeLogFile!.lengthSync() >= maxFileSizeBytes) {
        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_');
        final rotatedFile = File(p.join(_logDir!.path, 'app_$timestamp.log'));
        try {
          _activeLogFile!.renameSync(rotatedFile.path);
          _activeLogFile = File(p.join(_logDir!.path, activeLogFileName));
        } catch (_) {}
      }
    }

    _pruneRotatedLogs();
  }

  void _pruneRotatedLogs() {
    if (_logDir == null || !_logDir!.existsSync()) return;

    try {
      final logFiles = _logDir!
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('app_') && p.basename(f.path).endsWith('.log'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

      if (logFiles.length > maxRotatedLogs) {
        for (var i = maxRotatedLogs; i < logFiles.length; i++) {
          try {
            logFiles[i].deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _checkPreviousSessionAbnormalExit() {
    if (_activeSessionFile == null || !_activeSessionFile!.existsSync()) return;

    try {
      final raw = _activeSessionFile!.readAsStringSync();
      if (raw.trim().isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final prevSession = SessionInfo.fromJson(json);

        final isVersionMismatch = prevSession.appVersion != appVersion;
        final abnormalMsg = isVersionMismatch
            ? 'NOTICE: Previous session (id: ${prevSession.sessionId}, version: ${prevSession.appVersion}, current: $appVersion) terminated without clean exit marker during app version change (likely app update/reinstall), not a confirmed crash.'
            : 'CRITICAL: Previous session (id: ${prevSession.sessionId}, started: ${prevSession.startTime.toIso8601String()}) terminated abnormally without clean exit marker. Possible native crash (SIGSEGV/SIGBUS/abort), OOM kill, or force close.';

        _writeDirectSync('=== ABNORMAL SESSION TERMINATION DETECTED ===\n$abnormalMsg\n', flush: true);

        final lastLogTimestamp = _findLastLogTimestamp();

        if (_crashDir != null) {
          final abnormalCrashFile = File(
            p.join(_crashDir!.path, 'abnormal_exit_${prevSession.sessionId}.log'),
          );
          final statusText = isVersionMismatch
              ? 'Version change detected (likely app update / reinstall / overwrite), not a confirmed crash.'
              : 'No clean exit recorded for previous session.';
          final hintText = isVersionMismatch
              ? 'App version changed from ${prevSession.appVersion} to $appVersion. Previous session was likely replaced by update.'
              : 'Native signal (SIGSEGV/SIGABRT/SIGBUS), LowMemoryKiller (OOM), or process killed by OS.';

          abnormalCrashFile.writeAsStringSync(
            '================ ABNORMAL TERMINATION REPORT ================\n'
            'Time: ${DateTime.now().toUtc().toIso8601String()}\n'
            'Status: $statusText\n'
            'Previous Session ID: ${prevSession.sessionId}\n'
            'Previous Start Time: ${prevSession.startTime.toIso8601String()}\n'
            'Last Log Timestamp: ${lastLogTimestamp ?? "none"}\n'
            'Previous App Version: ${prevSession.appVersion}\n'
            'Current App Version: $appVersion\n'
            'OS: ${prevSession.platform} ${prevSession.osVersion}\n'
            'Device: ${prevSession.deviceModel}\n'
            'ABI: ${prevSession.abi ?? "unknown"}\n'
            'Root Cause Hint: $hintText\n'
            '============================================================\n',
            flush: true,
          );
        }
      }
    } catch (_) {}
  }

  String? _findLastLogTimestamp() {
    if (_activeLogFile == null || !_activeLogFile!.existsSync()) return null;
    try {
      final lines = _activeLogFile!.readAsLinesSync();
      final tsRegex = RegExp(r'^(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{3})');
      for (var i = lines.length - 1; i >= 0; i--) {
        final line = lines[i].trim();
        final match = tsRegex.firstMatch(line);
        if (match != null) {
          return match.group(1);
        }
      }
    } catch (_) {}
    return null;
  }

  void _writeActiveSessionMarker(SessionInfo info) {
    if (_activeSessionFile == null) return;
    try {
      _activeSessionFile!.writeAsStringSync(jsonEncode(info.toJson()), flush: true);
    } catch (_) {}
  }

  void endSessionGracefully() {
    if (!_initialized) return;

    log(LogLevel.info, 'Session', '===== CONDUIT SESSION ENDED GRACEFULLY =====');

    try {
      if (_activeSessionFile != null && _activeSessionFile!.existsSync()) {
        _activeSessionFile!.deleteSync();
      }
    } catch (_) {}

    flushSync();
  }

  void log(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    // Basic mode: logs warning, error, fatal, and Session tag lifecycle events.
    // Verbose mode: additionally logs info and debug telemetry events.
    if (!verboseLogging && level.priority < LogLevel.warning.priority && tag != 'Session') {
      return;
    }

    final record = LogRecord(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );

    final formatted = record.format();

    if (kDebugMode) {
      debugPrint(formatted);
    }

    final shouldFlush = level.priority >= LogLevel.error.priority;
    _writeDirectSync(formatted, flush: shouldFlush);
  }

  void _writeDirectSync(String message, {bool flush = false}) {
    if (_activeLogFile == null) return;
    try {
      _activeLogFile!.writeAsStringSync('$message\n', mode: FileMode.append, flush: flush);
      if (_activeLogFile!.lengthSync() >= maxFileSizeBytes) {
        _checkAndRotateLog();
      }
    } catch (_) {}
  }

  void recordFlutterError(FlutterErrorDetails details) {
    final error = details.exception;
    final stack = details.stack;
    final summary = details.summary.toString();

    log(LogLevel.fatal, 'FlutterError', summary, error: error, stackTrace: stack);

    _writeCrashReport(
      type: 'Flutter Framework Error',
      summary: summary,
      error: error,
      stackTrace: stack,
      library: details.library ?? 'flutter',
      context: details.context?.toString(),
    );
  }

  void recordPlatformError(Object error, StackTrace stack) {
    log(LogLevel.fatal, 'PlatformDispatcher', 'Uncaught platform dispatcher error', error: error, stackTrace: stack);

    _writeCrashReport(
      type: 'PlatformDispatcher Uncaught Error',
      summary: 'Unhandled error in PlatformDispatcher',
      error: error,
      stackTrace: stack,
    );
  }

  void recordUnhandledError(Object error, StackTrace stack, {String context = 'runZonedGuarded'}) {
    if (!_initialized || kDebugMode) {
      debugPrint('[ZoneError] Uncaught error in $context: $error\n$stack');
    }

    log(LogLevel.fatal, 'ZoneError', 'Uncaught error in $context', error: error, stackTrace: stack);

    _writeCrashReport(
      type: 'Zone Uncaught Error ($context)',
      summary: 'Unhandled error in $context',
      error: error,
      stackTrace: stack,
    );
  }

  void recordIsolateError(Object error, StackTrace stack) {
    log(LogLevel.fatal, 'IsolateError', 'Uncaught error in Isolate', error: error, stackTrace: stack);

    _writeCrashReport(
      type: 'Isolate Uncaught Error',
      summary: 'Unhandled isolate error',
      error: error,
      stackTrace: stack,
    );
  }

  void _writeCrashReport({
    required String type,
    required String summary,
    required Object error,
    required StackTrace? stackTrace,
    String? library,
    String? context,
  }) {
    Directory? targetDir = _crashDir;
    if (targetDir == null || !targetDir.existsSync()) {
      try {
        targetDir = Directory(p.join(Directory.systemTemp.path, 'conduit_crash'));
        if (!targetDir.existsSync()) {
          targetDir.createSync(recursive: true);
        }
      } catch (_) {}
    }
    if (targetDir == null || !targetDir.existsSync()) return;

    try {
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').replaceAll('.', '_');
      final crashFile = File(p.join(targetDir.path, 'crash_dart_$timestamp.log'));

      final content = StringBuffer()
        ..writeln('================ FATAL FLUTTER/DART CRASH ================')
        ..writeln('Time: ${DateTime.now().toUtc().toIso8601String()}')
        ..writeln('Crash Type: $type')
        ..writeln('Summary: $summary')
        ..writeln('Session ID: ${_currentSession?.sessionId ?? "unknown"}')
        ..writeln('App Version: $appVersion')
        ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('Device: ${Platform.localHostname}')
        ..writeln('ABI: ${_currentSession?.abi ?? "unknown"}');

      if (library != null) content.writeln('Library: $library');
      if (context != null) content.writeln('Context: $context');

      content
        ..writeln('Error Details: $error')
        ..writeln('Stack Trace:')
        ..writeln(stackTrace?.toString() ?? 'No stack trace available.')
        ..writeln('==========================================================');

      crashFile.writeAsStringSync(content.toString(), flush: true);
    } catch (_) {}
  }

  void flushSync() {
    // Direct sync writes are already flushed for critical records
  }

  Future<void> dispose() async {
    _initialized = false;
    _logDir = null;
    _crashDir = null;
    _activeLogFile = null;
    _activeSessionFile = null;
    _currentSession = null;
  }
}

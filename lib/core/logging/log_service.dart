import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/logging/log_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LogService {
  LogService._();

  static final LogService instance = LogService._();

  static const MethodChannel _exitInfoChannel = MethodChannel('conduit/exit_info');

  /// Fallback app version constant used when runtime package info is unavailable or fails.
  static const String defaultAppVersion = SessionInfo.fallbackAppVersion;

  /// Legacy static constant alias kept for backwards compatibility / fallback reference.
  @Deprecated('Use LogService.instance.currentAppVersion or LogService.defaultAppVersion instead')
  static const String appVersion = defaultAppVersion;

  static const int maxFileSizeBytes = 2 * 1024 * 1024; // 2MB
  static const int maxRotatedLogs = 7;
  static const String activeLogFileName = 'app.log';
  static const String activeSessionFileName = '.session_active';

  String _currentAppVersion = defaultAppVersion;
  ProcessExitInfo? _lastExitInfo;
  Directory? _logDir;
  Directory? _crashDir;
  File? _activeLogFile;
  File? _activeSessionFile;
  SessionInfo? _currentSession;
  bool _initialized = false;
  bool verboseLogging = false;

  String get currentAppVersion => _currentAppVersion;
  ProcessExitInfo? get lastExitInfo => _lastExitInfo;
  Directory? get logDirectory => _logDir;
  Directory? get crashDirectory => _crashDir;
  SessionInfo? get currentSession => _currentSession;
  bool get isInitialized => _initialized;

  Future<ProcessExitInfo?> _fetchExitInfo() async {
    if (kIsWeb) return null;
    try {
      final result = await _exitInfoChannel
          .invokeMethod<Map<dynamic, dynamic>>('getLastExitInfo')
          .timeout(const Duration(milliseconds: 300));
      if (result != null) {
        return ProcessExitInfo.fromMap(result);
      }
    } catch (_) {
      // Graceful degradation when channel is unavailable or query fails.
    }
    return null;
  }

  Future<void> init({
    Directory? overrideDir,
    String? customAbi,
    @Deprecated('Pass custom PackageInfo mock instead of overrideAppVersion')
    String? overrideAppVersion,
    ProcessExitInfo? customExitInfo,
    Future<PackageInfo> Function()? packageInfoLoader,
  }) async {
    try {
      String? fallbackWarning;
      String resolvedVersion = defaultAppVersion;
      if (overrideAppVersion != null && overrideAppVersion.isNotEmpty) {
        resolvedVersion = overrideAppVersion;
      } else {
        try {
          final packageInfo = await (packageInfoLoader != null
                  ? packageInfoLoader()
                  : PackageInfo.fromPlatform())
              .timeout(
            const Duration(milliseconds: 400),
          );
          final v = packageInfo.version.trim();
          final b = packageInfo.buildNumber.trim();
          if (v.isNotEmpty) {
            resolvedVersion = b.isNotEmpty ? '$v+$b' : v;
          }
        } catch (e) {
          resolvedVersion = defaultAppVersion;
          fallbackWarning =
              'appVersion fallback to frozen constant ($defaultAppVersion); package info resolution failed ($e). Reports may show stale version.';
        }
      }
      _currentAppVersion = resolvedVersion;

      // Query OS ApplicationExitInfo (API 30+)
      ProcessExitInfo? exitInfo = customExitInfo;
      exitInfo ??= await _fetchExitInfo();
      _lastExitInfo = exitInfo;

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
        appVersion: _currentAppVersion,
        osVersion: Platform.operatingSystemVersion,
        platform: Platform.operatingSystem,
        deviceModel: Platform.localHostname,
        abi: customAbi,
      );

      _checkPreviousSessionAbnormalExit(exitInfo);

      _writeActiveSessionMarker(_currentSession!);

      _initialized = true;

      if (fallbackWarning != null) {
        log(LogLevel.warning, 'Session', fallbackWarning);
      }

      log(
        LogLevel.info,
        'Session',
        '===== CONDUIT SESSION STARTED (id: ${currentSession!.sessionId}) =====',
      );
      log(
        LogLevel.info,
        'Session',
        'Environment: App: $_currentAppVersion | OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} | ABI: ${customAbi ?? 'unknown'} | Dart: ${Platform.version.split(' ').first}',
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

  void _checkPreviousSessionAbnormalExit(ProcessExitInfo? exitInfo) {
    if (_activeSessionFile == null || !_activeSessionFile!.existsSync()) return;

    try {
      final raw = _activeSessionFile!.readAsStringSync();
      if (raw.trim().isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final prevSession = SessionInfo.fromJson(json);

        final isVersionMismatch = prevSession.appVersion != _currentAppVersion;

        String abnormalMsg;
        String statusText;
        String hintText;

        final sessionStartMs = prevSession.startTime.millisecondsSinceEpoch;
        final isTimestampStale = exitInfo != null &&
            exitInfo.timestamp != null &&
            exitInfo.timestamp! < sessionStartMs;

        if (exitInfo != null && isTimestampStale) {
          // Guard: OS exit record timestamp precedes current marked session start time (e.g. abrupt power-off/reboot).
          // Attribution fails; treat as UNKNOWN to prevent blaming an unrelated older crash on this session.
          abnormalMsg =
              'CRITICAL: Previous session (id: ${prevSession.sessionId}) terminated abnormally without clean exit marker. OS exit record timestamp (${exitInfo.timestamp}) precedes session start time ($sessionStartMs); attribution failed, treated as UNKNOWN.';
          statusText = '归因失败：OS 退出记录早于会话启动时间 (treated as UNKNOWN)';
          hintText =
              'OS exit record timestamp precedes session start time. Stale exit record from prior session/reboot discarded; treated as UNKNOWN.';
        } else if (exitInfo != null) {
          // Priority 1: Authoritative OS exit info
          switch (exitInfo.reason) {
            case ProcessExitInfo.reasonCrashNative:
              abnormalMsg =
                  'CRITICAL: Previous session (id: ${prevSession.sessionId}, pid: ${exitInfo.pid ?? "unknown"}) terminated due to CONFIRMED NATIVE CRASH (REASON_CRASH_NATIVE). Description: ${exitInfo.description ?? "none"}';
              statusText = 'Confirmed native crash (REASON_CRASH_NATIVE)';
              hintText =
                  'Authoritative OS evidence: REASON_CRASH_NATIVE (description: ${exitInfo.description ?? "none"}, status: ${exitInfo.status ?? "unknown"}).';
              break;
            case ProcessExitInfo.reasonCrash:
              abnormalMsg =
                  'CRITICAL: Previous session (id: ${prevSession.sessionId}) terminated due to Java crash (REASON_CRASH). Check crash_java_*.log for uncaught exception trace.';
              statusText = 'Confirmed Java crash (REASON_CRASH)';
              hintText = 'Authoritative OS evidence: REASON_CRASH (Java uncaught exception).';
              break;
            case ProcessExitInfo.reasonAnr:
              abnormalMsg =
                  'CRITICAL: Previous session (id: ${prevSession.sessionId}) terminated due to Application Not Responding (REASON_ANR).';
              statusText = 'Application Not Responding (REASON_ANR)';
              hintText = 'Authoritative OS evidence: REASON_ANR (main thread unresponsive / killed by OS).';
              break;
            case ProcessExitInfo.reasonMemoryLimiter:
              abnormalMsg =
                  'CRITICAL: Previous session (id: ${prevSession.sessionId}) terminated by Memory Limiter (REASON_MEMORY_LIMITER). Process exceeded system memory limit.';
              statusText = 'Killed by Memory Limiter (REASON_MEMORY_LIMITER)';
              hintText =
                  'Authoritative OS evidence: REASON_MEMORY_LIMITER (process exceeded system memory limit). Check memory usage and leaks.';
              break;
            case ProcessExitInfo.reasonLowMemory:
              final isCachedOrBackground = exitInfo.importance != null && exitInfo.importance! >= 400;
              if (isCachedOrBackground) {
                abnormalMsg =
                    'NOTICE: Previous session (id: ${prevSession.sessionId}) 后台进程被系统例行回收，非确定崩溃 (REASON_LOW_MEMORY, importance: ${exitInfo.importance}).';
                statusText = '后台进程被系统例行回收，非确定崩溃 (REASON_LOW_MEMORY)';
                hintText =
                    'Authoritative OS evidence: REASON_LOW_MEMORY (cached/background process reclaimed by OS, importance: ${exitInfo.importance}).';
              } else {
                abnormalMsg =
                    'CRITICAL: Previous session (id: ${prevSession.sessionId}) terminated by Low Memory Killer (REASON_LOW_MEMORY). Likely high memory consumption / memory leak.';
                statusText = 'Killed by Low Memory Killer (REASON_LOW_MEMORY)';
                hintText =
                    'Authoritative OS evidence: REASON_LOW_MEMORY (LMK process termination under system memory pressure, importance: ${exitInfo.importance ?? "unknown"}). Check memory usage and leaks.';
              }
              break;
            case ProcessExitInfo.reasonSignaled:
              abnormalMsg =
                  'CRITICAL: Previous session (id: ${prevSession.sessionId}) 异常终止：被 OS 信号杀死 (REASON_SIGNALED, status: ${exitInfo.status ?? "unknown"}).';
              statusText = '异常终止：被 OS 信号杀死 (REASON_SIGNALED)';
              hintText = exitInfo.status == 9
                  ? 'Authoritative OS evidence: REASON_SIGNALED (status=9 SIGKILL). Note: status=9(SIGKILL) 在部分设备上可能是系统内存管理行为而非代码缺陷。'
                  : 'Authoritative OS evidence: REASON_SIGNALED (status/signal: ${exitInfo.status ?? "unknown"}).';
              break;
            case ProcessExitInfo.reasonAnomaly:
              abnormalMsg =
                  'NOTICE: Previous session (id: ${prevSession.sessionId}) 异常退出原因不明 (REASON_ANOMALY).';
              statusText = '异常退出原因不明 (REASON_ANOMALY)';
              hintText =
                  'Authoritative OS evidence: REASON_ANOMALY (anomalous process termination, reason unknown).';
              break;
            case ProcessExitInfo.reasonUserRequested:
            case ProcessExitInfo.reasonUserStopped:
            case ProcessExitInfo.reasonExitSelf:
            case ProcessExitInfo.reasonOther:
            case ProcessExitInfo.reasonPackageUpdated:
            case ProcessExitInfo.reasonPackageStateChange:
            case ProcessExitInfo.reasonPermissionChange:
            case ProcessExitInfo.reasonExcessiveResourceUsage:
            case ProcessExitInfo.reasonDependencyDied:
            case ProcessExitInfo.reasonFreezer:
              abnormalMsg =
                  'NOTICE: Previous session (id: ${prevSession.sessionId}) terminated without clean exit marker due to non-crash event (${exitInfo.reasonName}), not a confirmed crash.';
              statusText = 'Non-crash termination (${exitInfo.reasonName})';
              hintText = 'Authoritative OS evidence: ${exitInfo.reasonName} (${_getReasonDescription(exitInfo.reason)}).';
              break;
            case ProcessExitInfo.reasonInitializationFailure:
            case ProcessExitInfo.reasonUnknown:
            default:
              abnormalMsg =
                  'NOTICE: Previous session (id: ${prevSession.sessionId}) terminated (${exitInfo.reasonName}): OS 未归类/初始化故障，无法定性。';
              statusText = 'OS 未归类/初始化故障，无法定性 (${exitInfo.reasonName})';
              hintText = 'Authoritative OS evidence: ${exitInfo.reasonName} (${_getReasonDescription(exitInfo.reason)}).';
              break;
          }
        } else {
          // Priority 2: Fallback version mismatch heuristic
          if (isVersionMismatch) {
            abnormalMsg =
                'NOTICE: Previous session (id: ${prevSession.sessionId}, version: ${prevSession.appVersion}, current: $_currentAppVersion) terminated without clean exit marker during app version change (likely app update/reinstall), not a confirmed crash.';
            statusText = 'Version change detected (likely app update / reinstall / overwrite), not a confirmed crash.';
            hintText =
                'App version changed from ${prevSession.appVersion} to $_currentAppVersion. Previous session was likely replaced by update.';
          } else {
            abnormalMsg =
                'CRITICAL: Previous session (id: ${prevSession.sessionId}, started: ${prevSession.startTime.toIso8601String()}) terminated abnormally without clean exit marker. Possible native crash (SIGSEGV/SIGBUS/abort), OOM kill, or force close.';
            statusText = 'No clean exit recorded for previous session.';
            hintText = 'Native signal (SIGSEGV/SIGABRT/SIGBUS), LowMemoryKiller (OOM), or process killed by OS.';
          }
        }

        _writeDirectSync('=== ABNORMAL SESSION TERMINATION DETECTED ===\n$abnormalMsg\n', flush: true);

        final lastLogTimestamp = _findLastLogTimestamp();

        if (_crashDir != null) {
          final abnormalCrashFile = File(
            p.join(_crashDir!.path, 'abnormal_exit_${prevSession.sessionId}.log'),
          );

          final reportBuffer = StringBuffer()
            ..writeln('================ ABNORMAL TERMINATION REPORT ================')
            ..writeln('Time: ${DateTime.now().toUtc().toIso8601String()}')
            ..writeln('Status: $statusText')
            ..writeln('Previous Session ID: ${prevSession.sessionId}')
            ..writeln('Previous Start Time: ${prevSession.startTime.toIso8601String()}')
            ..writeln('Last Log Timestamp: ${lastLogTimestamp ?? "none"}')
            ..writeln('Previous App Version: ${prevSession.appVersion}')
            ..writeln('Current App Version: $_currentAppVersion')
            ..writeln('OS: ${prevSession.platform} ${prevSession.osVersion}')
            ..writeln('Device: ${prevSession.deviceModel}')
            ..writeln('ABI: ${prevSession.abi ?? "unknown"}');

          if (exitInfo != null) {
            reportBuffer.writeln('OS Exit Reason: ${exitInfo.reasonName} (code: ${exitInfo.reason})');
            if (exitInfo.description != null) {
              reportBuffer.writeln('OS Exit Description: ${exitInfo.description}');
            }
            if (exitInfo.pid != null) {
              reportBuffer.writeln('OS Exit PID: ${exitInfo.pid}');
            }
            if (exitInfo.status != null) {
              reportBuffer.writeln('OS Exit Status: ${exitInfo.status}');
            }
            if (exitInfo.timestamp != null) {
              final exitTime =
                  DateTime.fromMillisecondsSinceEpoch(exitInfo.timestamp!, isUtc: true).toIso8601String();
              reportBuffer.writeln('OS Exit Timestamp: ${exitInfo.timestamp} ($exitTime)');
            }
            if (exitInfo.importance != null) {
              reportBuffer.writeln('OS Exit Importance: ${exitInfo.importance}');
            }
            if (exitInfo.pss != null) {
              reportBuffer.writeln('OS Exit PSS: ${exitInfo.pss} KB');
            }
            if (exitInfo.rss != null) {
              reportBuffer.writeln('OS Exit RSS: ${exitInfo.rss} KB');
            }
            if (exitInfo.tombstone != null) {
              reportBuffer.writeln('Tombstone: ${exitInfo.tombstone}');
            } else if (_isTraceEligibleReason(exitInfo.reason)) {
              reportBuffer.writeln('Tombstone: tombstone 已被系统覆盖');
            }
          }

          reportBuffer
            ..writeln('Root Cause Hint: $hintText')
            ..writeln('============================================================');

          abnormalCrashFile.writeAsStringSync(reportBuffer.toString(), flush: true);
        }
      }
    } catch (_) {}
  }

  static bool _isTraceEligibleReason(int reason) {
    return reason == ProcessExitInfo.reasonCrashNative ||
        reason == ProcessExitInfo.reasonCrash ||
        reason == ProcessExitInfo.reasonAnr ||
        reason == ProcessExitInfo.reasonSignaled;
  }

  String _getReasonDescription(int reason) {
    switch (reason) {
      case ProcessExitInfo.reasonExitSelf:
        return 'Process called System.exit() or exit()';
      case ProcessExitInfo.reasonSignaled:
        return 'Process was killed by a POSIX signal';
      case ProcessExitInfo.reasonLowMemory:
        return 'Process was killed by the system Low Memory Killer';
      case ProcessExitInfo.reasonCrash:
        return 'Process crashed due to an unhandled Java exception';
      case ProcessExitInfo.reasonCrashNative:
        return 'Process crashed due to a native signal (e.g. SIGSEGV, SIGBUS)';
      case ProcessExitInfo.reasonAnr:
        return 'Process was killed due to an Application Not Responding timeout';
      case ProcessExitInfo.reasonInitializationFailure:
        return 'Process failed during initialization';
      case ProcessExitInfo.reasonPermissionChange:
        return 'Process was killed due to permission revocation or change';
      case ProcessExitInfo.reasonExcessiveResourceUsage:
        return 'Process was killed due to excessive CPU, battery, or resource usage';
      case ProcessExitInfo.reasonUserRequested:
        return 'User requested process stop (e.g., swipe away in Recents)';
      case ProcessExitInfo.reasonUserStopped:
        return 'Process was stopped because the user or profile was stopped';
      case ProcessExitInfo.reasonDependencyDied:
        return 'Process was killed because an essential dependency died';
      case ProcessExitInfo.reasonFreezer:
        return 'Process was killed due to frozen binder transaction / app freezer';
      case ProcessExitInfo.reasonPackageStateChange:
        return 'Process was killed because package was disabled or uninstalled';
      case ProcessExitInfo.reasonPackageUpdated:
        return 'Process was killed because package was updated';
      case ProcessExitInfo.reasonMemoryLimiter:
        return 'Process was killed by the system memory limiter for exceeding memory thresholds';
      case ProcessExitInfo.reasonAnomaly:
        return 'Process was killed due to an anomaly detected by the system';
      case ProcessExitInfo.reasonOther:
      default:
        return 'System or environment termination';
    }
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
    // Basic mode: logs warning, error, fatal, and Session tag lifecycle events (info and above).
    // Verbose mode: additionally logs info and debug telemetry events.
    final isSessionLifecycle = tag == 'Session' && level.priority >= LogLevel.info.priority;
    if (!verboseLogging && level.priority < LogLevel.warning.priority && !isSessionLifecycle) {
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
        ..writeln('App Version: $_currentAppVersion')
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
    _lastExitInfo = null;
    _logDir = null;
    _crashDir = null;
    _activeLogFile = null;
    _activeSessionFile = null;
    _currentSession = null;
  }
}


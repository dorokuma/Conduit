import 'dart:io';

import 'package:archive/archive.dart';
import 'package:conduit/core/logging/app_logger.dart';
import 'package:conduit/core/logging/app_route_observer.dart';
import 'package:conduit/core/logging/log_exporter.dart';
import 'package:conduit/core/logging/log_models.dart';
import 'package:conduit/core/logging/log_service.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../support/test_doubles.dart';

void main() {
  late Directory tempTestDir;

  setUp(() async {
    tempTestDir = await Directory.systemTemp.createTemp('conduit_log_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('conduit/exit_info'),
      (call) async => null,
    );
    PackageInfo.setMockInitialValues(
      appName: '',
      packageName: '',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('conduit/exit_info'),
      null,
    );
    await LogService.instance.dispose();
    PackageInfo.setMockInitialValues(
      appName: '',
      packageName: '',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
    if (tempTestDir.existsSync()) {
      try {
        tempTestDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('LogService Tests', () {
    test('initializes and creates logs and crash directories', () async {
      await LogService.instance.init(overrideDir: tempTestDir, customAbi: 'arm64-v8a');

      final logDir = Directory(p.join(tempTestDir.path, 'logs'));
      final crashDir = Directory(p.join(tempTestDir.path, 'logs', 'crash'));
      final activeMarker = File(p.join(tempTestDir.path, 'logs', '.session_active'));

      expect(logDir.existsSync(), isTrue);
      expect(crashDir.existsSync(), isTrue);
      expect(activeMarker.existsSync(), isTrue);
      expect(LogService.instance.currentSession?.abi, equals('arm64-v8a'));
    });

    test('writes log records and formats accurately', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = true;

      LogService.instance.log(
        LogLevel.info,
        'TestTag',
        'Hello logging world',
      );

      LogService.instance.log(
        LogLevel.error,
        'ErrorTag',
        'Something failed',
        error: 'TestException',
        stackTrace: StackTrace.current,
      );

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      expect(activeLog.existsSync(), isTrue);

      final content = activeLog.readAsStringSync();
      expect(content, contains('[INFO] [TestTag] Hello logging world'));
      expect(content, contains('[ERROR] [ErrorTag] Something failed'));
      expect(content, contains('Error: TestException'));
    });

    test('detects previous unclosed session as abnormal termination', () async {
      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      // Simulate a crashed previous session by leaving .session_active behind
      activeMarker.writeAsStringSync(
        '{"sessionId":"prev_12345","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 16","platform":"android","deviceModel":"Pixel 9","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_prev_12345.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('ABNORMAL TERMINATION REPORT'));
      expect(reportText, contains('prev_12345'));
      expect(reportText, contains('Pixel 9'));
    });

    test('handles version mismatch on abnormal exit report with downgrade wording and last timestamp', () async {
      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));
      final activeLog = File(p.join(logDir.path, 'app.log'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"prev_99999","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.43+68","osVersion":"Android 16","platform":"android","deviceModel":"Pixel 9","abi":"arm64-v8a"}',
      );
      activeLog.writeAsStringSync(
        '2026-09-01 12:34:56.789 [INFO] [Session] Last known log record\n',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_prev_99999.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Version change detected (likely app update / reinstall / overwrite), not a confirmed crash.'));
      expect(reportText, contains('Last Log Timestamp: 2026-09-01 12:34:56.789'));
      expect(reportText, contains('Previous App Version: 1.4.43+68'));
      expect(reportText, contains('Current App Version: ${LogService.defaultAppVersion}'));
    });

    test('initializes with runtime appVersion from PackageInfo when available', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Conduit',
        packageName: 'com.dorokuma.conduit',
        version: '1.5.0',
        buildNumber: '70',
        buildSignature: '',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      expect(LogService.instance.currentAppVersion, equals('1.5.0+70'));
      expect(LogService.instance.currentSession?.appVersion, equals('1.5.0+70'));

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();
      expect(content, contains('Environment: App: 1.5.0+70'));
    });

    test('falls back to defaultAppVersion when PackageInfo is empty or fails', () async {
      PackageInfo.setMockInitialValues(
        appName: '',
        packageName: '',
        version: '',
        buildNumber: '',
        buildSignature: '',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      expect(LogService.instance.currentAppVersion, equals(LogService.defaultAppVersion));
      expect(LogService.instance.currentSession?.appVersion, equals(LogService.defaultAppVersion));
    });

    test('falls back to defaultAppVersion and logs warning when PackageInfo times out (>400ms)', () async {
      await LogService.instance.init(
        overrideDir: tempTestDir,
        packageInfoLoader: () async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return PackageInfo(
            appName: 'Conduit',
            packageName: 'com.gwitko.conduit',
            version: '2.0.0',
            buildNumber: '99',
          );
        },
      );
      expect(LogService.instance.currentAppVersion, equals(LogService.defaultAppVersion));

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      expect(activeLog.existsSync(), isTrue);
      final content = activeLog.readAsStringSync();
      expect(content, contains('[WARN] [Session] appVersion fallback to frozen constant'));
    });

    test('falls back to defaultAppVersion and logs warning when PackageInfo throws error', () async {
      await LogService.instance.init(
        overrideDir: tempTestDir,
        packageInfoLoader: () async {
          throw PlatformException(code: 'PKG_ERR', message: 'Simulated package info failure');
        },
      );
      expect(LogService.instance.currentAppVersion, equals(LogService.defaultAppVersion));

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      expect(activeLog.existsSync(), isTrue);
      final content = activeLog.readAsStringSync();
      expect(content, contains('[WARN] [Session] appVersion fallback to frozen constant'));
    });

    test('dispose preserves currentAppVersion instead of resetting to defaultAppVersion', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Conduit',
        packageName: 'com.dorokuma.conduit',
        version: '2.1.0',
        buildNumber: '88',
        buildSignature: '',
      );

      await LogService.instance.init(overrideDir: tempTestDir);
      expect(LogService.instance.currentAppVersion, equals('2.1.0+88'));

      await LogService.instance.dispose();
      // Should retain 2.1.0+88 rather than resetting to defaultAppVersion
      expect(LogService.instance.currentAppVersion, equals('2.1.0+88'));
    });

    test('version mismatch detects upgrade from previous session when runtime appVersion changes', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Conduit',
        packageName: 'com.dorokuma.conduit',
        version: '1.5.0',
        buildNumber: '70',
        buildSignature: '',
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"prev_upgraded","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 16","platform":"android","deviceModel":"Pixel 9","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_prev_upgraded.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Version change detected (likely app update / reinstall / overwrite), not a confirmed crash.'));
      expect(reportText, contains('Previous App Version: 1.4.44+69'));
      expect(reportText, contains('Current App Version: 1.5.0+70'));
    });

    test('graceful exit removes active session marker', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      final activeMarker = File(p.join(tempTestDir.path, 'logs', '.session_active'));
      expect(activeMarker.existsSync(), isTrue);

      LogService.instance.endSessionGracefully();
      expect(activeMarker.existsSync(), isFalse);
    });

    test('ensureSessionMarker restores active session marker if missing after detached->resumed cycle', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      final activeMarker = File(p.join(tempTestDir.path, 'logs', '.session_active'));
      expect(activeMarker.existsSync(), isTrue);

      // Simulate detached state
      LogService.instance.endSessionGracefully();
      expect(activeMarker.existsSync(), isFalse);

      // Simulate resumed state
      LogService.instance.ensureSessionMarker();
      expect(activeMarker.existsSync(), isTrue);
      final content = activeMarker.readAsStringSync();
      expect(content, contains(LogService.instance.currentSession!.sessionId));
    });

    test('records fatal unhandled errors and creates dedicated crash files', () async {
      await LogService.instance.init(overrideDir: tempTestDir);

      LogService.instance.recordUnhandledError(
        Exception('Fatal simulated failure'),
        StackTrace.current,
        context: 'testZone',
      );

      final crashDir = Directory(p.join(tempTestDir.path, 'logs', 'crash'));
      final crashFiles = crashDir.listSync().whereType<File>().toList();
      expect(crashFiles.isNotEmpty, isTrue);

      final crashContent = crashFiles.first.readAsStringSync();
      expect(crashContent, contains('FATAL FLUTTER/DART CRASH'));
      expect(crashContent, contains('Fatal simulated failure'));
      expect(crashContent, contains('testZone'));
    });

    test('recordUnhandledError falls back gracefully before initialization', () async {
      LogService.instance.recordUnhandledError(
        'PreInit Emergency Failure',
        StackTrace.current,
        context: 'preInitZone',
      );

      final emergencyDir = Directory(p.join(Directory.systemTemp.path, 'conduit_crash'));
      expect(emergencyDir.existsSync(), isTrue);
      final emergencyFiles = emergencyDir.listSync().whereType<File>().toList();
      expect(emergencyFiles.isNotEmpty, isTrue);
      final lastCrash = emergencyFiles.last.readAsStringSync();
      expect(lastCrash, contains('PreInit Emergency Failure'));
      expect(lastCrash, contains('preInitZone'));
    });
  });

  group('ApplicationExitInfo Bridge & Abnormal Exit Tests', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        null,
      );
    });

    test('confirms native crash via REASON_CRASH_NATIVE with tombstone file and memory attribution', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonCrashNative,
              'reasonName': 'REASON_CRASH_NATIVE',
              'description': 'signal 11 (SIGSEGV), code 1, fault addr 0xdeadbeef',
              'timestamp': 1788260000000,
              'pid': 12345,
              'status': 11,
              'importance': 100,
              'pss': 256000,
              'rss': 128000,
              'tombstone': 'tombstone_1788260000000.bin',
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"native_crashed_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_native_crashed_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();

      expect(reportText, contains('Status: Confirmed native crash (REASON_CRASH_NATIVE)'));
      expect(reportText, contains('OS Exit Reason: REASON_CRASH_NATIVE (code: 5)'));
      expect(reportText, contains('OS Exit Description: signal 11 (SIGSEGV), code 1, fault addr 0xdeadbeef'));
      expect(reportText, contains('OS Exit PID: 12345'));
      expect(reportText, contains('OS Exit Status: 11'));
      expect(reportText, contains('OS Exit PSS: 256000 KB'));
      expect(reportText, contains('OS Exit RSS: 128000 KB'));
      expect(reportText, contains('Tombstone: tombstone_1788260000000.bin'));
      expect(reportText, contains('Root Cause Hint: Authoritative OS evidence: REASON_CRASH_NATIVE'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      final logContent = activeLog.readAsStringSync();
      expect(logContent, contains('CONFIRMED NATIVE CRASH (REASON_CRASH_NATIVE)'));
      expect(logContent, contains('0xdeadbeef'));
    });

    test('handles tombstone null fallback gracefully when overwritten by OS ring buffer', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonCrashNative,
              'reasonName': 'REASON_CRASH_NATIVE',
              'timestamp': 1788260000000,
              'pid': 12345,
              'status': 11,
              'tombstone': null,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"overwritten_trace_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_overwritten_trace_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Tombstone: tombstone 已被系统覆盖'));
    });

    test('confirms Java crash via REASON_CRASH', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonCrash,
              'reasonName': 'REASON_CRASH',
              'timestamp': 1788260000000,
              'pid': 23456,
              'status': 1,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"java_crash_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_java_crash_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: Confirmed Java crash (REASON_CRASH)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('Java crash (REASON_CRASH)'));
    });

    test('confirms ANR via REASON_ANR', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonAnr,
              'reasonName': 'REASON_ANR',
              'timestamp': 1788260000000,
              'pid': 34567,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"anr_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_anr_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: Application Not Responding (REASON_ANR)'));
    });

    test('confirms LowMemoryKiller foreground termination via REASON_LOW_MEMORY', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonLowMemory,
              'reasonName': 'REASON_LOW_MEMORY',
              'importance': 100, // Foreground
              'timestamp': 1788260000000,
              'pid': 45678,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"lmk_fg_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_lmk_fg_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: Killed by Low Memory Killer (REASON_LOW_MEMORY)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('CRITICAL: Previous session (id: lmk_fg_session) terminated by Low Memory Killer (REASON_LOW_MEMORY)'));
    });

    test('downgrades LowMemoryKiller cached/background termination via REASON_LOW_MEMORY', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonLowMemory,
              'reasonName': 'REASON_LOW_MEMORY',
              'importance': 400, // Cached / Background
              'timestamp': 1788260000000,
              'pid': 45679,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"lmk_cached_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_lmk_cached_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: 后台进程被系统例行回收，非确定崩溃 (REASON_LOW_MEMORY)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('NOTICE: Previous session (id: lmk_cached_session) 后台进程被系统例行回收，非确定崩溃'));
    });

    test('confirms signal termination via REASON_SIGNALED with neutral wording and SIGKILL hint', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonSignaled,
              'reasonName': 'REASON_SIGNALED',
              'status': 9,
              'timestamp': 1788260000000,
              'pid': 56789,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"signal_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_signal_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: 异常终止：被 OS 信号杀死 (REASON_SIGNALED)'));
      expect(reportText, contains('status=9(SIGKILL) 在部分设备上可能是系统内存管理行为而非代码缺陷。'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('CRITICAL: Previous session (id: signal_session) 异常终止：被 OS 信号杀死 (REASON_SIGNALED, status: 9)'));
    });

    test('guards against stale exit record timestamp and treats attribution failure as UNKNOWN', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonCrashNative,
              'reasonName': 'REASON_CRASH_NATIVE',
              'timestamp': 1700000000000, // Ancient timestamp before session startTime
              'pid': 99999,
              'status': 11,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"stale_timestamp_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_stale_timestamp_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();

      expect(reportText, contains('Status: 归因失败：OS 退出记录早于会话启动时间 (treated as UNKNOWN)'));
      expect(reportText, contains('Root Cause Hint: OS exit record timestamp precedes session start time. Stale exit record from prior session/reboot discarded; treated as UNKNOWN.'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('attribution failed, treated as UNKNOWN'));
    });

    test('confirms memory limiter termination via REASON_MEMORY_LIMITER (code 17) in confirmed group', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonMemoryLimiter,
              'reasonName': 'REASON_MEMORY_LIMITER',
              'timestamp': 1788260000000,
              'pid': 55555,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"memory_limiter_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 15","platform":"android","deviceModel":"Pixel 9","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_memory_limiter_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: Killed by Memory Limiter (REASON_MEMORY_LIMITER)'));
      expect(reportText, contains('OS Exit Reason: REASON_MEMORY_LIMITER (code: 17)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('CRITICAL: Previous session (id: memory_limiter_session) terminated by Memory Limiter (REASON_MEMORY_LIMITER)'));
    });

    test('downgrades anomaly exit via REASON_ANOMALY (code 18) in downgrade group', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonAnomaly,
              'reasonName': 'REASON_ANOMALY',
              'timestamp': 1788260000000,
              'pid': 66666,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"anomaly_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 16","platform":"android","deviceModel":"Pixel 9","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_anomaly_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: 异常退出原因不明 (REASON_ANOMALY)'));
      expect(reportText, contains('OS Exit Reason: REASON_ANOMALY (code: 18)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('NOTICE: Previous session (id: anomaly_session) 异常退出原因不明 (REASON_ANOMALY)'));
    });

    test('downgrades wording for non-crash exits including REASON_USER_REQUESTED, REASON_FREEZER, and REASON_PACKAGE_UPDATED', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonFreezer,
              'reasonName': 'REASON_FREEZER',
              'timestamp': 1788260000000,
              'pid': 67890,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"freezer_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_freezer_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: Non-crash termination (REASON_FREEZER)'));
      expect(reportText, contains('OS Exit Reason: REASON_FREEZER (code: 14)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      final logContent = activeLog.readAsStringSync();
      expect(logContent, contains('NOTICE: Previous session (id: freezer_session) terminated without clean exit marker due to non-crash event (REASON_FREEZER), not a confirmed crash.'));
    });

    test('formats INITIALIZATION_FAILURE and UNKNOWN with neutral non-crash wording', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonInitializationFailure,
              'reasonName': 'REASON_INITIALIZATION_FAILURE',
              'timestamp': 1788260000000,
              'pid': 77777,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"init_fail_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_init_fail_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: OS 未归类/初始化故障，无法定性 (REASON_INITIALIZATION_FAILURE)'));

      final activeLog = File(p.join(logDir.path, 'app.log'));
      expect(activeLog.readAsStringSync(), contains('OS 未归类/初始化故障，无法定性'));
    });

    test('handles unknown numeric reason codes by falling back to neutral wording and retaining code', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': 99,
              'reasonName': 'REASON_UNKNOWN',
              'timestamp': 1788260000000,
              'pid': 88888,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"unknown_code_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_unknown_code_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: OS 未归类/初始化故障，无法定性 (REASON_UNKNOWN)'));
      expect(reportText, contains('OS Exit Reason: REASON_UNKNOWN (code: 99)'));
    });

    test('verifies ProcessExitInfo serialization roundtrip and field mappings', () {
      final exitInfo = ProcessExitInfo.fromMap({
        'reason': ProcessExitInfo.reasonMemoryLimiter,
        'reasonName': 'REASON_MEMORY_LIMITER',
        'description': 'Memory limit exceeded',
        'timestamp': 1788260000000,
        'pid': 11223,
        'status': 0,
        'importance': 100,
        'pss': 512000,
        'rss': 256000,
        'tombstone': 'tombstone_1788260000000.bin',
      });

      expect(exitInfo.reason, equals(17));
      expect(exitInfo.reasonName, equals('REASON_MEMORY_LIMITER'));
      expect(exitInfo.pss, equals(512000));
      expect(exitInfo.rss, equals(256000));
      expect(exitInfo.tombstone, equals('tombstone_1788260000000.bin'));

      final map = exitInfo.toMap();
      expect(map['reason'], equals(17));
      expect(map['reasonName'], equals('REASON_MEMORY_LIMITER'));
      expect(map['pss'], equals(512000));
      expect(map['rss'], equals(256000));
      expect(map['tombstone'], equals('tombstone_1788260000000.bin'));
    });

    test('does not report tombstone placeholder for non-trace-eligible reasons', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonUserRequested,
              'reasonName': 'REASON_USER_REQUESTED',
              'timestamp': 1788260000000,
              'pid': 33333,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"no_tombstone_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_no_tombstone_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, isNot(contains('Tombstone:')));
    });

    test('prioritizes OS evidence over version heuristic when both exist', () async {
      // Version changed from 1.4.43+68 to 1.5.0+70, but OS reports confirmed native crash
      PackageInfo.setMockInitialValues(
        appName: 'Conduit',
        packageName: 'com.dorokuma.conduit',
        version: '1.5.0',
        buildNumber: '70',
        buildSignature: '',
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          if (call.method == 'getLastExitInfo') {
            return <String, dynamic>{
              'reason': ProcessExitInfo.reasonCrashNative,
              'reasonName': 'REASON_CRASH_NATIVE',
              'description': 'signal 7 (SIGBUS), code 2',
              'timestamp': 1788260000000,
              'pid': 78901,
            };
          }
          return null;
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"prev_upgraded_crashed","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.43+68","osVersion":"Android 14","platform":"android","deviceModel":"Pixel 8","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_prev_upgraded_crashed.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();

      // OS evidence takes precedence
      expect(reportText, contains('Status: Confirmed native crash (REASON_CRASH_NATIVE)'));
      expect(reportText, contains('OS Exit Description: signal 7 (SIGBUS), code 2'));
    });

    test('gracefully degrades to marker heuristic when exit info channel throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('conduit/exit_info'),
        (MethodCall call) async {
          throw PlatformException(code: 'UNAVAILABLE', message: 'Not supported on this Android version');
        },
      );

      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final crashDir = Directory(p.join(logDir.path, 'crash'))..createSync(recursive: true);
      final activeMarker = File(p.join(logDir.path, '.session_active'));

      activeMarker.writeAsStringSync(
        '{"sessionId":"legacy_android_session","startTime":"2026-09-01T10:00:00.000Z","appVersion":"1.4.44+69","osVersion":"Android 10","platform":"android","deviceModel":"Pixel 3","abi":"arm64-v8a"}',
      );

      await LogService.instance.init(overrideDir: tempTestDir);

      final abnormalReport = File(p.join(crashDir.path, 'abnormal_exit_legacy_android_session.log'));
      expect(abnormalReport.existsSync(), isTrue);
      final reportText = abnormalReport.readAsStringSync();
      expect(reportText, contains('Status: No clean exit recorded for previous session.'));
    });
  });

  group('LogService Rotation Tests (M4)', () {
    test('rotates log when app.log >= 2MB on init and resets active app.log', () async {
      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);
      final activeLog = File(p.join(logDir.path, 'app.log'));

      // Seed app.log with >2MB of dummy data
      final largeBytes = List<int>.filled(2 * 1024 * 1024 + 1024, 65); // 2MB + 1KB of 'A'
      activeLog.writeAsBytesSync(largeBytes);
      expect(activeLog.lengthSync(), greaterThanOrEqualTo(LogService.maxFileSizeBytes));

      await LogService.instance.init(overrideDir: tempTestDir);

      // Check rotated file created
      final rotatedFiles = logDir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('app_') && p.basename(f.path).endsWith('.log'))
          .toList();

      expect(rotatedFiles.length, equals(1));
      expect(rotatedFiles.first.lengthSync(), greaterThanOrEqualTo(LogService.maxFileSizeBytes));

      // Active app.log should now be freshly created and small (< 2MB)
      expect(activeLog.existsSync(), isTrue);
      expect(activeLog.lengthSync(), lessThan(LogService.maxFileSizeBytes));
    });

    test('prunes rotated logs to retain only max 7 archives, deleting oldest', () async {
      final logDir = Directory(p.join(tempTestDir.path, 'logs'))..createSync(recursive: true);

      // Create 9 rotated log files with staged timestamps
      final baseTime = DateTime(2026, 9, 1, 12);
      final createdFiles = <File>[];
      for (var i = 1; i <= 9; i++) {
        final pad = i.toString().padLeft(2, '0');
        final file = File(p.join(logDir.path, 'app_2026-09-01T12-00-$pad.log'));
        file.writeAsStringSync('Archive log $pad');
        file.setLastModifiedSync(baseTime.add(Duration(minutes: i)));
        createdFiles.add(file);
      }

      await LogService.instance.init(overrideDir: tempTestDir);

      final remainingRotated = logDir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('app_') && p.basename(f.path).endsWith('.log'))
          .toList();

      // Only max 7 should be kept
      expect(remainingRotated.length, equals(LogService.maxRotatedLogs));

      // The two oldest (app_...-01.log and app_...-02.log) should have been pruned
      final fileNames = remainingRotated.map((f) => p.basename(f.path)).toList();
      expect(fileNames.contains('app_2026-09-01T12-00-01.log'), isFalse);
      expect(fileNames.contains('app_2026-09-01T12-00-02.log'), isFalse);
      expect(fileNames.contains('app_2026-09-01T12-00-09.log'), isTrue);
    });
  });

  group('LogExporter Tests', () {
    test('zips log files correctly and excludes .session_active', () async {
      await LogService.instance.init(overrideDir: tempTestDir);

      LogService.instance.log(LogLevel.warning, 'ExportTest', 'Sample warning message for zip test');
      LogService.instance.recordUnhandledError(
        'Test error for crash log',
        StackTrace.current,
      );

      const exporter = LogExporter();
      final files = await exporter.collectLogFiles();
      expect(files.length, greaterThanOrEqualTo(2));
      expect(files.any((f) => p.basename(f.path) == LogService.activeSessionFileName), isFalse);

      final zipBytes = await exporter.createZipArchive();
      expect(zipBytes, isNotEmpty);

      // Verify unzipping
      final decodedArchive = ZipDecoder().decodeBytes(zipBytes);
      expect(decodedArchive.files.isNotEmpty, isTrue);

      final fileNames = decodedArchive.files.map((f) => f.name).toList();
      expect(fileNames.any((n) => n.contains('app.log')), isTrue);
      expect(fileNames.any((n) => n.contains('.session_active')), isFalse);
    });

    test('calculates total size and clears logs', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.log(LogLevel.warning, 'SizeTest', '1234567890');

      const exporter = LogExporter();
      final size = await exporter.getTotalLogSize();
      expect(size, greaterThan(0));

      await exporter.clearLogs();
      // Active log and session active should remain, crash reports cleared
      final logDir = Directory(p.join(tempTestDir.path, 'logs'));
      final remainingFiles = logDir.listSync(recursive: true).whereType<File>().toList();
      expect(remainingFiles.any((f) => p.basename(f.path) == 'app.log'), isTrue);
    });
  });

  group('AppLogger & RouteObserver Tests', () {
    test('filters telemetry events but keeps warnings/errors when verboseLogging is false (Basic Mode)', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = false;

      AppLogger.d('DebugTag', 'Debug message');
      AppLogger.i('InfoTag', 'Info message');
      AppLogger.w('WarnTag', 'Warning occurred (e.g. SSH connection failure)');
      AppLogger.e('ErrorTag', 'Error occurred');
      AppLogger.pty('Start PTY process', metadata: {'rows': 24, 'columns': 80});
      AppLogger.ssh('Connect', metadata: {'host': 'example.com', 'port': 22});
      AppLogger.localShell('Execute', metadata: {'exit_code': 0});
      AppLogger.nav('Push', routeName: 'HomeScreen');

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();

      // Warning and Error MUST be written in basic mode
      expect(content, contains('[WARN] [WarnTag] Warning occurred'));
      expect(content, contains('[ERROR] [ErrorTag] Error occurred'));

      // Info/debug telemetry events should NOT be written in basic mode
      expect(content, isNot(contains('[DEBUG]')));
      expect(content, isNot(contains('Info message')));
      expect(content, isNot(contains('[PTY]')));
      expect(content, isNot(contains('[SSH]')));
      expect(content, isNot(contains('[LocalShell]')));
      expect(content, isNot(contains('[Navigation]')));

      // Session marker should still be written
      expect(content, contains('[Session] ===== CONDUIT SESSION STARTED'));
    });

    test('filters debug level under Session tag in basic mode while allowing info and above', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = false;

      AppLogger.d('Session', 'Suppressed debug session event');
      AppLogger.i('Session', 'Allowed info session event');

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();

      expect(content, isNot(contains('Suppressed debug session event')));
      expect(content, contains('Allowed info session event'));
    });

    test('logs AppLifecycle transitions under Session tag in basic mode', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = false;

      AppLogger.i('Session', 'AppLifecycle state changed to: paused');
      AppLogger.i('Session', 'AppLifecycle state changed to: resumed');
      AppLogger.i('Session', 'AppLifecycle state changed to: inactive');
      AppLogger.i('Session', 'AppLifecycle state changed to: hidden');
      AppLogger.i('Session', 'AppLifecycle state changed to: detached');

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();

      expect(content, contains('[Session] AppLifecycle state changed to: paused'));
      expect(content, contains('[Session] AppLifecycle state changed to: resumed'));
      expect(content, contains('[Session] AppLifecycle state changed to: inactive'));
      expect(content, contains('[Session] AppLifecycle state changed to: hidden'));
      expect(content, contains('[Session] AppLifecycle state changed to: detached'));
    });

    test('records telemetry events when verboseLogging is true (Verbose Mode)', () async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = true;

      AppLogger.pty('Start PTY process', metadata: {'rows': 24, 'columns': 80});
      AppLogger.ssh('Connect', metadata: {'host': 'example.com', 'port': 22});
      AppLogger.localShell('Execute', metadata: {'exit_code': 0});
      AppLogger.nav('Push', routeName: 'HomeScreen');

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();

      expect(content, contains('[PTY] Start PTY process'));
      expect(content, contains('[SSH] Connect'));
      expect(content, contains('[LocalShell] Execute'));
      expect(content, contains('[Navigation] Push (HomeScreen)'));
    });

    testWidgets('AppRouteObserver observes navigation pushes and pops', (tester) async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = true;

      final observer = AppRouteObserver();

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          initialRoute: '/',
          routes: {
            '/': (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).pushNamed('/details'),
                    child: const Text('Go to Details'),
                  ),
                ),
            '/details': (context) => const Scaffold(
                  body: Text('Details Page'),
                ),
          },
        ),
      );

      await tester.tap(find.text('Go to Details'));
      await tester.pumpAndSettle();

      expect(find.text('Details Page'), findsOneWidget);

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();
      expect(content, contains('[Navigation] Push'));
    });

    testWidgets('ConduitApp reacts to app lifecycle events and logs under Session tag', (tester) async {
      await LogService.instance.init(overrideDir: tempTestDir);
      LogService.instance.verboseLogging = false;

      final promptCoordinator = HostKeyPromptCoordinator();
      final verifier = NoopVerifier();
      final themeController = ThemeController(InMemoryThemePreferences());
      final hostsController = HostsController(EmptyHostsRepository());

      await tester.pumpWidget(
        ConduitApp(
          lockController: AppLockController(AlwaysAuthenticates()),
          themeController: themeController,
          hostsController: hostsController,
          terminalRepository: NoNetworkTerminalRepository(),
          workspaceController: TerminalWorkspaceController(
            NoNetworkTerminalRepository(),
          ),
          localShellController: LocalShellController(),
          hostKeyVerifier: verifier,
          promptCoordinator: promptCoordinator,
          sftpRepository: NoNetworkSftpRepository(),
          backupService: AppBackupService(
            hostsController: hostsController,
            themeController: themeController,
            hostKeyVerifier: verifier,
          ),
          fileExport: RecordingFileExport(),
        ),
      );

      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      final activeLog = File(p.join(tempTestDir.path, 'logs', 'app.log'));
      final content = activeLog.readAsStringSync();

      expect(content, contains('[Session] AppLifecycle state changed to: paused'));
      expect(content, contains('[Session] AppLifecycle state changed to: resumed'));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}


import 'dart:io';

import 'package:archive/archive.dart';
import 'package:conduit/core/logging/app_logger.dart';
import 'package:conduit/core/logging/app_route_observer.dart';
import 'package:conduit/core/logging/log_exporter.dart';
import 'package:conduit/core/logging/log_models.dart';
import 'package:conduit/core/logging/log_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempTestDir;

  setUp(() async {
    tempTestDir = await Directory.systemTemp.createTemp('conduit_log_test_');
    PackageInfo.setMockInitialValues(
      appName: '',
      packageName: '',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
  });

  tearDown(() async {
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
      expect(reportText, contains('Current App Version: ${LogService.appVersion}'));
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
  });
}

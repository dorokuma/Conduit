import 'dart:io';

enum LogLevel {
  debug('DEBUG', 10),
  info('INFO', 20),
  warning('WARN', 30),
  error('ERROR', 40),
  fatal('FATAL', 50);

  const LogLevel(this.label, this.priority);
  final String label;
  final int priority;
}

class LogRecord {
  LogRecord({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  String format() {
    final buffer = StringBuffer();
    final timeStr = _formatTimestamp(timestamp);
    buffer.write('$timeStr [${level.label}] [$tag] $message');
    if (error != null) {
      buffer.write(' | Error: $error');
    }
    if (stackTrace != null) {
      buffer.write('\n$stackTrace');
    }
    return buffer.toString();
  }

  static String _formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$y-$m-$d $h:$min:$s.$ms';
  }
}

class SessionInfo {
  SessionInfo({
    required this.sessionId,
    required this.startTime,
    required this.appVersion,
    required this.osVersion,
    required this.platform,
    required this.deviceModel,
    this.abi,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      sessionId: json['sessionId'] as String? ?? '',
      startTime: DateTime.tryParse(json['startTime'] as String? ?? '') ?? DateTime.now(),
      appVersion: json['appVersion'] as String? ?? '1.4.44+69',
      osVersion: json['osVersion'] as String? ?? Platform.operatingSystemVersion,
      platform: json['platform'] as String? ?? Platform.operatingSystem,
      deviceModel: json['deviceModel'] as String? ?? 'unknown',
      abi: json['abi'] as String?,
    );
  }

  final String sessionId;
  final DateTime startTime;
  final String appVersion;
  final String osVersion;
  final String platform;
  final String deviceModel;
  final String? abi;

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'startTime': startTime.toIso8601String(),
      'appVersion': appVersion,
      'osVersion': osVersion,
      'platform': platform,
      'deviceModel': deviceModel,
      if (abi != null) 'abi': abi,
    };
  }
}

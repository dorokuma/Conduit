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
  /// Fallback app version when deserializing legacy or unversioned session json.
  static const String fallbackAppVersion = '1.4.45+70';

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
      appVersion: json['appVersion'] as String? ?? fallbackAppVersion,
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

/// Authoritative exit information returned from Android OS ApplicationExitInfo (API 30+).
class ProcessExitInfo {
  const ProcessExitInfo({
    required this.reason,
    required this.reasonName,
    this.description,
    this.timestamp,
    this.pid,
    this.status,
    this.importance,
    this.pss,
    this.rss,
    this.tombstone,
  });

  factory ProcessExitInfo.fromMap(Map<dynamic, dynamic> map) {
    return ProcessExitInfo(
      reason: (map['reason'] as num?)?.toInt() ?? 0,
      reasonName: map['reasonName'] as String? ?? 'REASON_UNKNOWN',
      description: map['description'] as String?,
      timestamp: (map['timestamp'] as num?)?.toInt(),
      pid: (map['pid'] as num?)?.toInt(),
      status: (map['status'] as num?)?.toInt(),
      importance: (map['importance'] as num?)?.toInt(),
      pss: (map['pss'] as num?)?.toInt(),
      rss: (map['rss'] as num?)?.toInt(),
      tombstone: map['tombstone'] as String?,
    );
  }

  // Standard ApplicationExitInfo reason constants (API 30+)
  static const int reasonUnknown = 0;
  static const int reasonExitSelf = 1;
  static const int reasonSignaled = 2;
  static const int reasonLowMemory = 3;
  static const int reasonCrash = 4;
  static const int reasonCrashNative = 5;
  static const int reasonAnr = 6;
  static const int reasonInitializationFailure = 7;
  static const int reasonPermissionChange = 8;
  static const int reasonExcessiveResourceUsage = 9;
  static const int reasonUserRequested = 10;
  static const int reasonUserStopped = 11;
  static const int reasonDependencyDied = 12;
  static const int reasonOther = 13;
  static const int reasonFreezer = 14;
  static const int reasonPackageStateChange = 15;
  static const int reasonPackageUpdated = 16;
  static const int reasonMemoryLimiter = 17;
  static const int reasonAnomaly = 18;

  final int reason;
  final String reasonName;
  final String? description;
  final int? timestamp;
  final int? pid;
  final int? status;
  final int? importance;
  final int? pss;
  final int? rss;
  final String? tombstone;

  Map<String, dynamic> toMap() {
    return {
      'reason': reason,
      'reasonName': reasonName,
      if (description != null) 'description': description,
      if (timestamp != null) 'timestamp': timestamp,
      if (pid != null) 'pid': pid,
      if (status != null) 'status': status,
      if (importance != null) 'importance': importance,
      if (pss != null) 'pss': pss,
      if (rss != null) 'rss': rss,
      if (tombstone != null) 'tombstone': tombstone,
    };
  }
}


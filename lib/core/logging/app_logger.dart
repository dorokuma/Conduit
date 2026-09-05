import 'package:conduit/core/logging/log_models.dart';
import 'package:conduit/core/logging/log_service.dart';

/// App-wide logging facade.
///
/// ============================================================================
/// [PRIVACY RED LINE / 隐私安全红线]
/// Conduit is a secure developer terminal app. To preserve user privacy and data security:
/// - STRICTLY FORBIDDEN to log terminal output streams (stdout/stderr buffer contents).
/// - STRICTLY FORBIDDEN to log user keystrokes, input text, or command-line strings.
/// - STRICTLY FORBIDDEN to log passwords, private keys, SSH credentials, or tokens.
/// - Only lightweight lifecycle events, state transitions, error messages, and
///   non-sensitive metadata (e.g., dimensions, host names/ports, exit codes) may be logged.
/// ============================================================================
class AppLogger {
  const AppLogger._();

  static void d(String tag, String message) {
    LogService.instance.log(LogLevel.debug, tag, message);
  }

  static void i(String tag, String message) {
    LogService.instance.log(LogLevel.info, tag, message);
  }

  static void w(String tag, String message, {Object? error, StackTrace? stackTrace}) {
    LogService.instance.log(LogLevel.warning, tag, message, error: error, stackTrace: stackTrace);
  }

  static void e(String tag, String message, {Object? error, StackTrace? stackTrace}) {
    LogService.instance.log(LogLevel.error, tag, message, error: error, stackTrace: stackTrace);
  }

  static void f(String tag, String message, {Object? error, StackTrace? stackTrace}) {
    LogService.instance.log(LogLevel.fatal, tag, message, error: error, stackTrace: stackTrace);
  }

  /// PTY subsystem lifecycle events.
  /// [PRIVACY RED LINE]: Do NOT pass terminal output or shell input data here.
  static void pty(String action, {Map<String, Object?>? metadata}) {
    final metaStr = metadata != null && metadata.isNotEmpty ? ' | $metadata' : '';
    LogService.instance.log(LogLevel.info, 'PTY', '$action$metaStr');
  }

  /// SSH/Mosh terminal subsystem lifecycle events.
  /// [PRIVACY RED LINE]: Do NOT pass SSH keystrokes, passwords, or session buffer content.
  static void ssh(String action, {Map<String, Object?>? metadata}) {
    final metaStr = metadata != null && metadata.isNotEmpty ? ' | $metadata' : '';
    LogService.instance.log(LogLevel.info, 'SSH', '$action$metaStr');
  }

  /// Local shell / PRoot subsystem events.
  /// [PRIVACY RED LINE]: Do NOT pass command arguments containing secrets or raw script contents.
  static void localShell(String action, {Map<String, Object?>? metadata}) {
    final metaStr = metadata != null && metadata.isNotEmpty ? ' | $metadata' : '';
    LogService.instance.log(LogLevel.info, 'LocalShell', '$action$metaStr');
  }

  /// Page / Screen Navigation events.
  static void nav(String action, {String? routeName}) {
    final routeStr = routeName != null ? ' ($routeName)' : '';
    LogService.instance.log(LogLevel.info, 'Navigation', '$action$routeStr');
  }
}

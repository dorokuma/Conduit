/// Hands a finished local file to the platform so the user can pick where to
/// keep it.
///
/// Downloads are streamed to a temporary file first; this avoids holding the
/// whole payload in memory (previously a 50 MB download grew the Dart heap by
/// ~170 MB and the platform copied it again).
abstract class FileExport {
  /// Shows the system save dialog for [fileName] and copies [sourcePath] into
  /// the location the user picks. Returns the saved location (or null when the
  /// user cancelled).
  Future<String?> saveFromPath(String sourcePath, String fileName);
}

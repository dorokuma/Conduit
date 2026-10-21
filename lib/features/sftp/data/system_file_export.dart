import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:flutter/services.dart';

/// Uses Android's Storage Access Framework (`ACTION_CREATE_DOCUMENT`) to let
/// the user pick a destination, then copies the already-downloaded file there
/// from native code.
class SystemFileExport implements FileExport {
  const SystemFileExport();

  static const _channel = MethodChannel('conduit/file_save');

  @override
  Future<String?> saveFromPath(String sourcePath, String fileName) {
    return _channel.invokeMethod<String>('saveFromPath', {
      'sourcePath': sourcePath,
      'fileName': fileName,
    });
  }
}

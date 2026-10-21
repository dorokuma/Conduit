import 'dart:typed_data';

import 'package:conduit/features/sftp/domain/sftp_entry.dart';

abstract class SftpSession {
  Future<List<SftpEntry>> list(String path);

  Future<String> resolve(String path);

  Future<Uint8List> read(
    String path, {
    void Function(int bytesRead, int? total)? onProgress,
  });

  /// Streams [path] into a temporary local file and returns its path.
  ///
  /// Keeps memory flat for large downloads: chunks are written as they arrive
  /// instead of accumulating in a `BytesBuilder`.
  Future<String> downloadToFile(
    String path, {
    void Function(int bytesRead, int? total)? onProgress,
  });

  Future<void> write(
    String path,
    Stream<Uint8List> data,
    int length, {
    void Function(int bytesSent)? onProgress,
  });

  Future<void> makeDirectory(String path);

  Future<void> rename(String from, String to);

  Future<void> delete(SftpEntry entry);

  Future<void> close();
}

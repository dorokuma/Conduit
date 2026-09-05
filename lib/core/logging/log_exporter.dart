import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:conduit/core/logging/app_logger.dart';
import 'package:conduit/core/logging/log_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class LogExportResult {
  const LogExportResult({
    required this.success,
    required this.fileCount,
    required this.totalBytes,
    this.zipPath,
    this.message,
  });

  final bool success;
  final int fileCount;
  final int totalBytes;
  final String? zipPath;
  final String? message;
}

class LogExporter {
  const LogExporter();

  Future<List<File>> collectLogFiles() async {
    final logDir = LogService.instance.logDirectory;
    if (logDir == null || !logDir.existsSync()) {
      return const [];
    }

    final files = <File>[];
    try {
      final entities = logDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File) {
          final filename = p.basename(entity.path);
          if (!filename.endsWith('.zip') && filename != LogService.activeSessionFileName) {
            files.add(entity);
          }
        }
      }
    } catch (e) {
      AppLogger.w('LogExporter', 'Failed to collect log files: $e');
    }
    return files;
  }

  Future<int> getTotalLogSize() async {
    final files = await collectLogFiles();
    var total = 0;
    for (final f in files) {
      try {
        total += f.lengthSync();
      } catch (_) {}
    }
    return total;
  }

  Future<Uint8List> createZipArchive() async {
    LogService.instance.flushSync();

    final logDir = LogService.instance.logDirectory;
    if (logDir == null || !logDir.existsSync()) {
      throw const FileSystemException('Log directory does not exist.');
    }

    final files = await collectLogFiles();
    final archive = Archive();

    for (final file in files) {
      try {
        final relativePath = p.relative(file.path, from: logDir.path);
        final bytes = file.readAsBytesSync();
        final archiveFile = ArchiveFile(relativePath, bytes.length, bytes);
        archive.addFile(archiveFile);
      } catch (e) {
        AppLogger.w('LogExporter', 'Failed to add file ${file.path} to zip: $e');
      }
    }

    final encoder = ZipEncoder();
    final zipData = encoder.encode(archive);
    return Uint8List.fromList(zipData);
  }

  Future<LogExportResult> exportLogs() async {
    try {
      final files = await collectLogFiles();
      if (files.isEmpty) {
        return const LogExportResult(
          success: false,
          fileCount: 0,
          totalBytes: 0,
          message: 'No logs available to export.',
        );
      }

      final zipBytes = await createZipArchive();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_');
      final zipFileName = 'conduit-logs-$timestamp.zip';

      final tempDir = await getTemporaryDirectory();
      final zipFile = File(p.join(tempDir.path, zipFileName));
      await zipFile.writeAsBytes(zipBytes, flush: true);

      AppLogger.i('LogExporter', 'Created log archive: ${zipFile.path} (${zipBytes.length} bytes, ${files.length} files)');

      var shared = false;
      try {
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(zipFile.path, mimeType: 'application/zip', name: zipFileName)],
            subject: 'Conduit Diagnostic Logs',
            text: 'Conduit diagnostic log archive ($timestamp)',
          ),
        );
        shared = result.status == ShareResultStatus.success;
      } catch (shareErr) {
        AppLogger.w('LogExporter', 'SharePlus failed: $shareErr, attempting FilePicker fallback');
      }

      if (!shared) {
        final savedPath = await FilePicker.saveFile(
          fileName: zipFileName,
          bytes: zipBytes,
        );
        if (savedPath != null) {
          return LogExportResult(
            success: true,
            fileCount: files.length,
            totalBytes: zipBytes.length,
            zipPath: savedPath,
            message: 'Saved to $savedPath',
          );
        }
      }

      return LogExportResult(
        success: true,
        fileCount: files.length,
        totalBytes: zipBytes.length,
        zipPath: zipFile.path,
        message: 'Logs exported successfully.',
      );
    } catch (e, st) {
      AppLogger.e('LogExporter', 'Failed to export logs', error: e, stackTrace: st);
      return LogExportResult(
        success: false,
        fileCount: 0,
        totalBytes: 0,
        message: 'Failed to export logs: $e',
      );
    }
  }

  Future<void> clearLogs() async {
    final logDir = LogService.instance.logDirectory;
    if (logDir == null || !logDir.existsSync()) return;

    try {
      final entities = logDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name != LogService.activeLogFileName && name != LogService.activeSessionFileName) {
            try {
              entity.deleteSync();
            } catch (_) {}
          }
        }
      }
      AppLogger.i('LogExporter', 'Cleared old logs and crash reports');
    } catch (e) {
      AppLogger.w('LogExporter', 'Error clearing logs: $e');
    }
  }
}

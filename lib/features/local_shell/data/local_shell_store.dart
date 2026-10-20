import 'dart:io';
import 'dart:isolate';

import 'package:conduit/features/local_shell/domain/local_shell_paths.dart';

class LocalShellStore {
  const LocalShellStore(this.paths);

  final LocalShellPaths paths;

  Future<bool> isConfigured() => File(paths.firstBootMarkerHostPath).exists();

  Future<String?> installedVersion() async {
    final file = File(paths.versionFile);
    if (!await file.exists()) return null;
    final text = (await file.readAsString()).trim();
    return text.isEmpty ? null : text;
  }

  Future<void> writeVersion(String version) async {
    final file = File(paths.versionFile);
    await file.parent.create(recursive: true);
    await file.writeAsString(version);
  }

  Future<void> prepareDirectories() async {
    await Directory(paths.rootfsDir).create(recursive: true);
    await Directory(paths.tmpDir).create(recursive: true);
  }

  Future<void> resetRootfs() async {
    await _forceDelete(paths.rootfsDir);
    await Directory(paths.rootfsDir).create(recursive: true);
  }

  Future<void> wipe() => _forceDelete(paths.installRoot);

  Future<void> deleteDownload() async {
    final file = File(paths.downloadPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _forceDelete(String path) async {
    if (!await Directory(path).exists()) return;
    final busybox = await _ensureBusyboxLink();
    final env = {'LD_LIBRARY_PATH': paths.nativeLibraryDir};
    try {
      await Process.run(busybox, [
        'chmod',
        '-R',
        'u+rwX',
        path,
      ], environment: env);
    } catch (_) {
      // Best effort: a missing busybox should not block the delete below.
    }
    try {
      await Directory(path).delete(recursive: true);
    } catch (_) {
      try {
        await Process.run(busybox, ['rm', '-rf', path], environment: env);
      } catch (_) {
        // Callers verify whether the directory survived.
      }
    }
  }

  Future<String> _ensureBusyboxLink() async {
    await Directory(paths.installRoot).create(recursive: true);
    final link = Link(paths.busyboxLink);
    if (await FileSystemEntity.isLink(paths.busyboxLink) ||
        await link.exists()) {
      try {
        await link.delete();
      } catch (_) {}
    }
    await link.create(paths.busyboxBinary);
    return paths.busyboxLink;
  }

  Future<int> diskUsageBytes() async {
    final root = Directory(paths.installRoot);
    if (!await root.exists()) return 0;
    // Walking a rootfs means tens of thousands of stat calls; keep that off
    // the UI isolate.
    return Isolate.run(() => _diskUsageSync(root.path));
  }

  static int _diskUsageSync(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) return 0;
    var total = 0;
    final pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      try {
        for (final entity in directory.listSync(followLinks: false)) {
          if (entity is File) {
            try {
              total += entity.lengthSync();
            } catch (_) {}
          } else if (entity is Directory) {
            pending.add(entity);
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return total;
  }
}

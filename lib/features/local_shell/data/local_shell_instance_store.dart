import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/local_shell/domain/local_shell_distro.dart';
import 'package:conduit/features/local_shell/domain/local_shell_instance.dart';
import 'package:path/path.dart' as p;

class LocalShellInstanceStore {
  const LocalShellInstanceStore({required this.dataDir, required this.catalog});

  final String dataDir;
  final List<LocalShellDistro> catalog;

  static const metaFileName = '.conduit-instance';

  Future<void> writeMeta(LocalShellInstance instance) async {
    final file = File(p.join(dataDir, instance.id, metaFileName));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'distroId': instance.distroId, 'name': instance.name}),
    );
  }

  Future<List<LocalShellInstance>> discover() async {
    final root = Directory(dataDir);
    if (!await root.exists()) return const [];
    final instances = <LocalShellInstance>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final instance = await _readInstance(entity);
      if (instance != null) instances.add(instance);
    }
    instances.sort((a, b) {
      final byDistro = _catalogIndex(
        a.distroId,
      ).compareTo(_catalogIndex(b.distroId));
      if (byDistro != 0) return byDistro;
      final byLength = a.id.length.compareTo(b.id.length);
      return byLength != 0 ? byLength : a.id.compareTo(b.id);
    });
    return instances;
  }

  Future<LocalShellInstance> createInstance(
    LocalShellDistro distro, {
    String? name,
  }) async {
    var suffix = 1;
    var id = distro.id;
    while (await Directory(p.join(dataDir, id)).exists()) {
      suffix += 1;
      id = '${distro.id}-$suffix';
    }
    final trimmed = name?.trim() ?? '';
    return LocalShellInstance(
      id: id,
      distroId: distro.id,
      name: trimmed.isNotEmpty
          ? trimmed
          : suffix == 1
          ? distro.name
          : '${distro.name} $suffix',
    );
  }

  Future<LocalShellInstance?> _readInstance(Directory directory) async {
    final id = p.basename(directory.path);
    final metaFile = File(p.join(directory.path, metaFileName));
    if (await metaFile.exists()) {
      try {
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is Map<String, Object?>) {
          final distroId = (decoded['distroId'] as String?)?.trim() ?? '';
          final name = (decoded['name'] as String?)?.trim() ?? '';
          final distro = _distroById(distroId);
          if (distro != null) {
            return LocalShellInstance(
              id: id,
              distroId: distroId,
              name: name.isEmpty ? distro.name : name,
            );
          }
        }
      } catch (_) {}
      return null;
    }
    final legacyDistro = _distroById(id);
    if (legacyDistro != null &&
        await Directory(p.join(directory.path, 'rootfs')).exists()) {
      return LocalShellInstance(id: id, distroId: id, name: legacyDistro.name);
    }
    return null;
  }

  LocalShellDistro? _distroById(String distroId) {
    for (final distro in catalog) {
      if (distro.id == distroId) return distro;
    }
    return null;
  }

  int _catalogIndex(String distroId) {
    for (var i = 0; i < catalog.length; i++) {
      if (catalog[i].id == distroId) return i;
    }
    return catalog.length;
  }
}

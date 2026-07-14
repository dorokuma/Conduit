import 'package:conduit/features/local_shell/domain/local_shell_paths.dart';
import 'package:conduit/features/local_shell/domain/rootfs_manifest.dart';

class LocalShellDistro {
  const LocalShellDistro({
    required this.id,
    required this.name,
    required this.updateCommand,
    required this.manifest,
    this.loginCommand = const ['/bin/bash', '--login'],
    this.setupCommands = const [],
  });

  final String id;
  final String name;
  final String updateCommand;
  final RootfsManifest manifest;
  final List<String> loginCommand;
  final List<String> setupCommands;
}

class LocalShellLaunch {
  const LocalShellLaunch({required this.distro, required this.paths});

  final LocalShellDistro distro;
  final LocalShellPaths paths;
}

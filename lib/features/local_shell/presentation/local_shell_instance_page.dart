import 'dart:async';

import 'package:conduit/features/local_shell/domain/local_shell_instance.dart';
import 'package:conduit/features/local_shell/domain/local_shell_state.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_setup_page.dart';
import 'package:flutter/material.dart';

class LocalShellInstancePage extends StatefulWidget {
  const LocalShellInstancePage({
    required this.controller,
    required this.instanceId,
    required this.onOpenSession,
    required this.onCloseSessions,
    super.key,
  });

  final LocalShellController controller;

  final String instanceId;

  final Future<void> Function(LocalShellInstance instance) onOpenSession;

  final Future<void> Function(String instanceId) onCloseSessions;

  @override
  State<LocalShellInstancePage> createState() => _LocalShellInstancePageState();
}

class _LocalShellInstancePageState extends State<LocalShellInstancePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.controller.refresh());
    });
  }

  LocalShellInstance? get _instance =>
      widget.controller.instanceById(widget.instanceId);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final instance = _instance;
        if (instance == null) {
          return const Scaffold(body: SizedBox.shrink());
        }
        final state = widget.controller.stateFor(instance.id);
        return Scaffold(
          appBar: AppBar(
            title: Text(instance.name),
            actions: [
              IconButton(
                tooltip: 'Rename',
                onPressed: state.isBusy ? null : () => _rename(instance),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildContent(context, instance, state),
                  const SizedBox(height: 32),
                  const _CreditFooter(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    LocalShellInstance instance,
    LocalShellState state,
  ) {
    final distroName =
        widget.controller.distroById(instance.distroId)?.name ??
        instance.distroId;
    switch (state.stage) {
      case LocalShellStage.checking:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [SizedBox(height: 8), LinearProgressIndicator()],
        );
      case LocalShellStage.downloading:
      case LocalShellStage.extracting:
      case LocalShellStage.configuring:
        return _Installing(state: state, distroName: distroName);
      case LocalShellStage.failed:
        return _Failed(
          error: state.error,
          onRetry: () => unawaited(widget.controller.install(instance.id)),
          onRemove: () => _confirmRemove(instance),
        );
      case LocalShellStage.notInstalled:
        return _Incomplete(
          onResume: () => unawaited(widget.controller.install(instance.id)),
          onRemove: () => _confirmRemove(instance),
        );
      case LocalShellStage.ready:
        return _Ready(
          state: state,
          distroName: distroName,
          updateCommand: widget.controller
              .distroById(instance.distroId)
              ?.updateCommand,
          sharedStorageFeatureEnabled:
              widget.controller.sharedStorageFeatureEnabled,
          sharedStorageAccessGranted:
              widget.controller.sharedStorageAccessGranted,
          onOpen: () => unawaited(widget.onOpenSession(instance)),
          onReinstall: () => _confirmReinstall(instance),
          onRemove: () => _confirmRemove(instance),
        );
      case LocalShellStage.unsupported:
        return const SizedBox.shrink();
    }
  }

  Future<void> _rename(LocalShellInstance instance) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: instance.name),
    );
    if (name != null && name.trim().isNotEmpty) {
      await widget.controller.rename(instance.id, name);
    }
  }

  Future<void> _confirmReinstall(LocalShellInstance instance) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reinstall ${instance.name}?'),
        content: Text(
          'This wipes this environment - including any packages you '
          'installed - and downloads a fresh image. Any open '
          '${instance.name} tabs will be closed first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reinstall'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onCloseSessions(instance.id);
      await widget.controller.reinstall(instance.id);
    }
  }

  Future<void> _confirmRemove(LocalShellInstance instance) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${instance.name}?'),
        content: Text(
          'This deletes this environment and everything in it. Any open '
          '${instance.name} tabs will be closed first. Other shells are '
          'not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onCloseSessions(instance.id);
      await widget.controller.remove(instance.id);
      if (mounted) Navigator.of(context).pop();
    }
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename shell'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

class _Ready extends StatelessWidget {
  const _Ready({
    required this.state,
    required this.distroName,
    required this.updateCommand,
    required this.sharedStorageFeatureEnabled,
    required this.sharedStorageAccessGranted,
    required this.onOpen,
    required this.onReinstall,
    required this.onRemove,
  });

  final LocalShellState state;
  final String distroName;
  final String? updateCommand;
  final bool sharedStorageFeatureEnabled;
  final bool sharedStorageAccessGranted;
  final VoidCallback onOpen;
  final VoidCallback onReinstall;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storageStatus = !sharedStorageFeatureEnabled
        ? 'Full build only'
        : sharedStorageAccessGranted
        ? '/mnt/android'
        : 'Permission needed';
    final storageHint = sharedStorageFeatureEnabled
        ? 'Grant file access to mount phone storage at /mnt/android.'
        : 'Phone storage mounting is available in the full build.';
    final updateHint = updateCommand == null
        ? ''
        : 'Update packages from inside the shell with  $updateCommand . ';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          icon: Icons.check_circle_outline_rounded,
          title: '$distroName is ready',
          body: 'Open a shell, or run several sessions side by side.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.terminal_rounded),
          label: const Text('New session'),
        ),
        const SizedBox(height: 24),
        _InfoRow(label: 'Distribution', value: distroName),
        _InfoRow(label: 'Version', value: state.installedVersion ?? 'unknown'),
        _InfoRow(
          label: 'Disk usage',
          value: formatLocalShellBytes(state.diskUsageBytes),
        ),
        _InfoRow(label: 'Android files', value: storageStatus),
        const SizedBox(height: 16),
        Text(
          '$updateHint$storageHint',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onReinstall,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Reinstall'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onRemove,
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Remove'),
        ),
      ],
    );
  }
}

class _Installing extends StatelessWidget {
  const _Installing({required this.state, required this.distroName});

  final LocalShellState state;
  final String distroName;

  @override
  Widget build(BuildContext context) {
    final progress = state.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          icon: Icons.settings_suggest_outlined,
          title: 'Setting up $distroName',
          body: state.message ?? 'Working…',
        ),
        const SizedBox(height: 24),
        LinearProgressIndicator(value: progress),
        if (progress != null) ...[
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({
    required this.error,
    required this.onRetry,
    required this.onRemove,
  });

  final LocalShellError? error;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          icon: Icons.error_outline_rounded,
          title: _title(error?.kind),
          body: error?.message ?? 'Something went wrong during setup.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onRemove,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Remove'),
        ),
      ],
    );
  }

  String _title(LocalShellErrorKind? kind) {
    return switch (kind) {
      LocalShellErrorKind.network => 'Download failed',
      LocalShellErrorKind.lowDisk => 'Not enough storage',
      LocalShellErrorKind.corruptDownload => 'Download was corrupted',
      LocalShellErrorKind.extractionFailed => 'Could not unpack the image',
      LocalShellErrorKind.configureFailed => 'Configuration failed',
      LocalShellErrorKind.unsupportedDevice => 'Not available on this device',
      LocalShellErrorKind.unknown || null => 'Setup failed',
    };
  }
}

class _Incomplete extends StatelessWidget {
  const _Incomplete({required this.onResume, required this.onRemove});

  final VoidCallback onResume;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Hero(
          icon: Icons.downloading_rounded,
          title: 'Setup is incomplete',
          body:
              'This shell was added but its image never finished installing. '
              'Resume to pick up where it left off, or remove it.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onResume,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Resume install'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onRemove,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Remove'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _CreditFooter extends StatelessWidget {
  const _CreditFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: theme.colorScheme.outlineVariant),
        const SizedBox(height: 8),
        Text(
          'The local shell uses proot and root filesystem images packaged '
          'through Termux, maintained by their upstream distributions. '
          'Conduit redistributes the bundled tools under their own '
          'open-source licenses.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () =>
                showLicensePage(context: context, applicationName: 'Conduit'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            icon: const Icon(Icons.description_outlined, size: 16),
            label: const Text('Open-source licenses'),
          ),
        ),
      ],
    );
  }
}

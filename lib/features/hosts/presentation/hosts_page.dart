import 'dart:async';

import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/host_form_page.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/connection_fab.dart';
import 'package:conduit/features/hosts/presentation/widgets/host_card.dart';
import 'package:conduit/features/hosts/presentation/widgets/host_search_field.dart';
import 'package:conduit/features/hosts/presentation/widgets/hosts_hero.dart';
import 'package:conduit/features/hosts/presentation/widgets/message_state.dart';
import 'package:conduit/features/hosts/presentation/widgets/tag_filter_bar.dart';
import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/presentation/sftp_browser_page.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_dialog.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/trusted_keys_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({
    required this.hostsController,
    required this.lockController,
    required this.terminalRepository,
    required this.workspaceController,
    required this.themeController,
    required this.hostKeyVerifier,
    required this.promptCoordinator,
    required this.sftpRepository,
    required this.fileExport,
    super.key,
  });

  final HostsController hostsController;
  final AppLockController lockController;
  final SshTerminalRepository terminalRepository;
  final TerminalWorkspaceController workspaceController;
  final ThemeController themeController;
  final HostKeyVerifier hostKeyVerifier;
  final HostKeyPromptCoordinator promptCoordinator;
  final SftpRepository sftpRepository;
  final FileExport fileExport;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  final _searchController = TextEditingController();
  bool _terminalPageOpen = false;
  bool _showingHostKeyPrompt = false;
  String _query = '';
  String? _selectedTag;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.hostsController.load());
      _handlePromptChanged();
    });
    widget.promptCoordinator.addListener(_handlePromptChanged);
  }

  @override
  void dispose() {
    widget.promptCoordinator.removeListener(_handlePromptChanged);
    widget.promptCoordinator.rejectAll();
    _searchController.dispose();
    super.dispose();
  }

  void _handlePromptChanged() {
    if (_showingHostKeyPrompt || !mounted) return;
    if (widget.promptCoordinator.current == null) return;
    _showingHostKeyPrompt = true;
    Future<void>.microtask(() async {
      try {
        while (true) {
          final next = widget.promptCoordinator.current;
          if (next == null) break;
          final decision = await _requestHostKeyDecision(next);
          widget.promptCoordinator.resolve(next, decision);
        }
      } finally {
        _showingHostKeyPrompt = false;
      }
    });
  }

  Future<HostKeyDecision> _requestHostKeyDecision(
    HostKeyPromptRequest request,
  ) async {
    if (!mounted) return HostKeyDecision.reject;
    return await showHostKeyPromptDialog(context: context, request: request) ??
        HostKeyDecision.reject;
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.themeController.palette;
    return Scaffold(
      floatingActionButton: ConnectionFab(onTap: _openForm),
      body: ConduitBackdrop(
        palette: palette,
        child: SafeArea(
          bottom: shouldApplyBottomSafeArea(context),
          child: RefreshIndicator(
            color: Theme.of(context).colorScheme.primary,
            onRefresh: widget.hostsController.load,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      widget.hostsController,
                      widget.workspaceController,
                    ]),
                    builder: (context, _) {
                      return HostsHero(
                        hostCount: widget.hostsController.hosts.length,
                        activeSessionCount:
                            widget.workspaceController.sessions.length,
                        onAppearance: () => showThemeSheet(
                          context: context,
                          controller: widget.themeController,
                        ),
                        onTrustedKeys: _openTrustedKeys,
                        onLock: _lock,
                        onOpenSessions: widget.workspaceController.hasSessions
                            ? _openTerminalWorkspace
                            : null,
                      );
                    },
                  ),
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    widget.hostsController,
                    widget.workspaceController,
                  ]),
                  builder: (context, _) => _buildBody(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final controller = widget.hostsController;
    if (controller.isLoading) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (controller.errorMessage != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: MessageState(
          icon: Icons.error_outline,
          title: 'Something went wrong',
          message: controller.errorMessage!,
          actionLabel: 'Retry',
          onAction: controller.load,
        ),
      );
    }

    if (controller.hosts.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: MessageState(
          icon: Icons.dns_outlined,
          title: 'No machines yet',
          message:
              'Add a server and Conduit will keep its credentials in your '
              'device’s secure storage.',
          actionLabel: 'Add machine',
          onAction: _openForm,
        ),
      );
    }

    final filteredHosts = _filteredHosts(controller.sortedHosts);
    final tags = _tagsFor(controller.hosts);

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 120),
      sliver: SliverList(
        delegate: SliverChildListDelegate.fixed([
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: HostSearchField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  hasContent: _query.isNotEmpty || _selectedTag != null,
                  onClear: _clearFilters,
                ),
              ),
              const SizedBox(width: 8),
              _HostSortMenu(
                value: controller.sortMode,
                onChanged: widget.hostsController.setSortMode,
              ),
            ],
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            TagFilterBar(
              tags: tags,
              selectedTag: _selectedTag,
              onSelected: (tag) {
                setState(() {
                  _selectedTag = _selectedTag == tag ? null : tag;
                });
              },
            ),
          ],
          const SizedBox(height: 16),
          if (filteredHosts.isEmpty)
            MessageState(
              icon: Icons.search_off,
              title: 'No matches',
              message: 'Try a different search or clear filters.',
              actionLabel: 'Clear',
              onAction: _clearFilters,
            )
          else
            for (final host in filteredHosts) ...[
              HostCard(
                host: host,
                active: widget.workspaceController.sessions.any(
                  (session) => session.host.id == host.id,
                ),
                selectedTag: _selectedTag,
                onConnect: () => _connect(host),
                onAction: (action) => _handleHostAction(action, host),
                onTagTap: (tag) {
                  setState(() {
                    _selectedTag = _selectedTag == tag ? null : tag;
                  });
                },
              ),
              const SizedBox(height: 8),
            ],
        ]),
      ),
    );
  }

  List<SavedHost> _filteredHosts(List<SavedHost> hosts) {
    final normalizedQuery = _query.trim().toLowerCase();
    return hosts.where((host) {
      final matchesTag =
          _selectedTag == null || host.tags.contains(_selectedTag);
      final matchesQuery =
          normalizedQuery.isEmpty ||
          host.name.toLowerCase().contains(normalizedQuery) ||
          host.host.toLowerCase().contains(normalizedQuery) ||
          host.username.toLowerCase().contains(normalizedQuery) ||
          host.tags.any((tag) => tag.toLowerCase().contains(normalizedQuery));
      return matchesTag && matchesQuery;
    }).toList();
  }

  List<String> _tagsFor(List<SavedHost> hosts) {
    final tags = <String>{};
    for (final host in hosts) {
      for (final tag in host.tags) {
        final trimmed = tag.trim();
        if (trimmed.isNotEmpty) tags.add(trimmed);
      }
    }
    final list = tags.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _selectedTag = null;
    });
  }

  Future<void> _openTerminalWorkspace() async {
    if (_terminalPageOpen) return;
    _terminalPageOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(
          workspace: widget.workspaceController,
          themeController: widget.themeController,
        ),
      ),
    );
    _terminalPageOpen = false;
  }

  Future<void> _openTrustedKeys() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrustedKeysPage(
          verifier: widget.hostKeyVerifier,
          themeController: widget.themeController,
        ),
      ),
    );
  }

  Future<void> _openFiles(SavedHost host) async {
    await widget.hostsController.markConnected(host);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SftpBrowserPage(
          host: host,
          repository: widget.sftpRepository,
          fileExport: widget.fileExport,
          themeController: widget.themeController,
        ),
      ),
    );
  }

  Future<void> _connect(SavedHost host) async {
    await widget.hostsController.markConnected(host);
    widget.workspaceController.open(host);
    await _openTerminalWorkspace();
  }

  Future<void> _lock() async {
    await widget.workspaceController.closeAll();
    widget.lockController.lock();
  }

  Future<void> _openForm([SavedHost? host]) async {
    final savedHost = await Navigator.of(context).push<SavedHost>(
      MaterialPageRoute(
        builder: (_) =>
            HostFormPage(host: host, themeController: widget.themeController),
      ),
    );
    if (savedHost != null) {
      await widget.hostsController.upsert(savedHost);
    }
  }

  Future<void> _handleHostAction(HostAction action, SavedHost host) async {
    switch (action) {
      case HostAction.files:
        await _openFiles(host);
      case HostAction.edit:
        await _openForm(host);
      case HostAction.duplicate:
        await _duplicate(host);
      case HostAction.copyAddress:
        await Clipboard.setData(ClipboardData(text: host.endpoint));
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Copied ${host.endpoint}')));
      case HostAction.delete:
        await _confirmDelete(host);
    }
  }

  Future<void> _duplicate(SavedHost host) async {
    final keepSecrets = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Duplicate machine'),
        content: const Text(
          'Copy the saved password and key material into the new machine?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Without secrets'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Copy secrets'),
          ),
        ],
      ),
    );
    if (keepSecrets == null) return;
    final base = keepSecrets
        ? host
        : host.copyWith(password: '', privateKey: '', passphrase: '');
    await widget.hostsController.upsert(
      base.copyWith(
        id: const Uuid().v4(),
        name: '${host.name} Copy',
        clearLastConnectedAt: true,
      ),
    );
  }

  Future<void> _confirmDelete(SavedHost host) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete machine?'),
        content: Text('Conduit will forget “${host.name}”.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete ?? false) {
      await widget.hostsController.remove(host);
    }
  }
}

class _HostSortMenu extends StatelessWidget {
  const _HostSortMenu({required this.value, required this.onChanged});

  final HostListSortMode value;
  final ValueChanged<HostListSortMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<HostListSortMode>(
      tooltip: 'Sort machines',
      initialValue: value,
      onSelected: onChanged,
      icon: const Icon(Icons.sort_rounded),
      itemBuilder: (context) => [
        for (final mode in HostListSortMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                Icon(mode.icon, size: 18),
                const SizedBox(width: 10),
                Text(mode.label),
              ],
            ),
          ),
      ],
    );
  }
}

extension on HostListSortMode {
  String get label => switch (this) {
    HostListSortMode.lastConnected => 'Last connected',
    HostListSortMode.name => 'Name',
    HostListSortMode.added => 'Added',
  };

  IconData get icon => switch (this) {
    HostListSortMode.lastConnected => Icons.schedule_rounded,
    HostListSortMode.name => Icons.sort_by_alpha_rounded,
    HostListSortMode.added => Icons.playlist_add_check_rounded,
  };
}

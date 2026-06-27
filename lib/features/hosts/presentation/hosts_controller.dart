import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:flutter/foundation.dart';

class HostsController extends ChangeNotifier {
  HostsController(this._repository);

  final SavedHostsRepository _repository;

  List<SavedHost> _hosts = const [];
  List<SavedHost>? _sortedHostsCache;
  HostListSortMode _sortMode = HostListSortMode.lastConnected;
  bool _isLoading = true;
  String? _errorMessage;

  List<SavedHost> get hosts => _hosts;
  List<SavedHost> get sortedHosts =>
      _sortedHostsCache ??= _computeSortedHosts();
  HostListSortMode get sortMode => _sortMode;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final hosts = await _repository.loadHosts();
      _sortMode = await _repository.loadSortMode();
      _setHosts(hosts);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> setSortMode(HostListSortMode mode) async {
    if (mode == _sortMode) return;
    _sortMode = mode;
    _sortedHostsCache = null;
    notifyListeners();

    try {
      await _repository.saveSortMode(mode);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
      notifyListeners();
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  Future<void> upsert(SavedHost host) async {
    final index = _hosts.indexWhere((currentHost) => currentHost.id == host.id);
    final updatedHosts = [..._hosts];

    if (index == -1) {
      updatedHosts.add(host);
    } else {
      updatedHosts[index] = host;
    }

    await _save(updatedHosts);
  }

  Future<void> remove(SavedHost host) async {
    await _save(
      _hosts.where((currentHost) => currentHost.id != host.id).toList(),
    );
  }

  Future<void> markConnected(SavedHost host) async {
    final current = _hosts.firstWhere(
      (currentHost) => currentHost.id == host.id,
      orElse: () => host,
    );
    await upsert(current.copyWith(lastConnectedAt: DateTime.now()));
  }

  Future<void> _save(List<SavedHost> hosts) async {
    _errorMessage = null;
    notifyListeners();

    try {
      await _repository.saveHosts(hosts);
      _setHosts(hosts);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      notifyListeners();
    }
  }

  void _setHosts(List<SavedHost> hosts) {
    _hosts = hosts;
    _sortedHostsCache = null;
  }

  List<SavedHost> _computeSortedHosts() {
    final sorted = [..._hosts];
    switch (_sortMode) {
      case HostListSortMode.lastConnected:
        sorted.sort(_compareLastConnected);
      case HostListSortMode.name:
        sorted.sort(_compareName);
      case HostListSortMode.added:
        break;
    }
    return List.unmodifiable(sorted);
  }

  int _compareLastConnected(SavedHost a, SavedHost b) {
    final aDate = a.lastConnectedAt;
    final bDate = b.lastConnectedAt;
    if (aDate == null && bDate == null) {
      return _compareName(a, b);
    }
    if (aDate == null) {
      return 1;
    }
    if (bDate == null) {
      return -1;
    }
    final byDate = bDate.compareTo(aDate);
    return byDate == 0 ? _compareName(a, b) : byDate;
  }

  int _compareName(SavedHost a, SavedHost b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    final byHost = a.host.toLowerCase().compareTo(b.host.toLowerCase());
    if (byHost != 0) return byHost;
    return a.id.compareTo(b.id);
  }
}

import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureSavedHostsRepository implements SavedHostsRepository {
  const SecureSavedHostsRepository(this._storage);

  static const _hostsKey = 'conduit.saved_hosts.v1';
  static const _sortModeKey = 'conduit.host_list_sort_mode.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<SavedHost>> loadHosts() async {
    final rawHosts = await _storage.read(key: _hostsKey);
    if (rawHosts == null || rawHosts.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(rawHosts);
      if (decoded is! List) {
        throw const FormatException('Expected a list of hosts.');
      }

      return decoded
          .whereType<Map<String, Object?>>()
          .map(SavedHost.fromJson)
          .toList(growable: false);
    } catch (error) {
      throw AppFailure('Saved hosts could not be read.', error);
    }
  }

  @override
  Future<void> saveHosts(List<SavedHost> hosts) async {
    await _storage.write(
      key: _hostsKey,
      value: jsonEncode(hosts.map((host) => host.toJson()).toList()),
    );
  }

  @override
  Future<HostListSortMode> loadSortMode() async {
    final rawMode = await _storage.read(key: _sortModeKey);
    return HostListSortMode.values.firstWhere(
      (mode) => mode.name == rawMode,
      orElse: () => HostListSortMode.lastConnected,
    );
  }

  @override
  Future<void> saveSortMode(HostListSortMode mode) async {
    await _storage.write(key: _sortModeKey, value: mode.name);
  }
}

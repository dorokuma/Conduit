import 'package:conduit/features/hosts/domain/saved_host.dart';

enum HostListSortMode { lastConnected, name, added }

abstract interface class SavedHostsRepository {
  Future<List<SavedHost>> loadHosts();

  Future<void> saveHosts(List<SavedHost> hosts);

  Future<HostListSortMode> loadSortMode();

  Future<void> saveSortMode(HostListSortMode mode);
}

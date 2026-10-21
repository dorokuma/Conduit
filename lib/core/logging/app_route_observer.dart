import 'package:conduit/core/logging/app_logger.dart';
import 'package:flutter/widgets.dart';

class AppRouteObserver extends NavigatorObserver {
  String _routeName(Route<dynamic>? route) {
    if (route == null) return 'null';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    AppLogger.nav('Push', routeName: '${_routeName(previousRoute)} -> ${_routeName(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    AppLogger.nav('Pop', routeName: '${_routeName(route)} (back to ${_routeName(previousRoute)})');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    AppLogger.nav('Replace', routeName: '${_routeName(oldRoute)} -> ${_routeName(newRoute)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    AppLogger.nav('Remove', routeName: _routeName(route));
  }
}

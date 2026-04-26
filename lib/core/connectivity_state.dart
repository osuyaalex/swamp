import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

enum ConnectivityState { online, offline }

/// App-wide network reachability stream. Used by the home shell to show
/// a global offline banner so the user always knows when actions like
/// uploads or task syncing won't reach the server.
///
/// `connectivity_plus` reports whether the device has *any* network
/// adapter active. It does not guarantee internet reachability — DNS
/// can fail, captive portals can block traffic. For a stronger signal
/// we'd combine this with reachability probes; for now this is enough
/// to drive the banner.
class ConnectivityWatcher {
  ConnectivityWatcher() {
    _init();
  }

  final _connectivity = Connectivity();
  final _controller = StreamController<ConnectivityState>.broadcast();
  StreamSubscription? _sub;
  ConnectivityState _last = ConnectivityState.online;

  Stream<ConnectivityState> get stream => _controller.stream;
  ConnectivityState get current => _last;

  Future<void> _init() async {
    final initial = await _connectivity.checkConnectivity();
    _last = _stateFromResult(initial);
    if (!_controller.isClosed) _controller.add(_last);

    _sub = _connectivity.onConnectivityChanged.listen((result) {
      final next = _stateFromResult(result);
      if (next == _last) return;
      _last = next;
      if (!_controller.isClosed) _controller.add(next);
    });
  }

  ConnectivityState _stateFromResult(List<ConnectivityResult> results) {
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    return hasNetwork ? ConnectivityState.online : ConnectivityState.offline;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}

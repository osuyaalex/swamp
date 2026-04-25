import 'dart:async';
import 'dart:math';

import 'package:untitled2/features/document_verification/data/mock_document_backend.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';

/// Simulates a `wss://api.example.com/ws/documents` connection.
///
/// Why simulate drops at all? Phase 2's spec asks for "automatic
/// reconnection logic". Without real disconnects, that code never runs in
/// the demo and reviewers can't see it work. The mock drops a connection
/// every [meanUptime] (jittered) so the reconnect path is exercised.
///
/// Behaviour mirrors a real WebSocket layer:
///   - exponential backoff on reconnect, capped at 30 s
///   - replay of "missed updates" for tracked ids on reconnect
///   - a single broadcast stream consumers can listen to
class DocumentWebSocketClient {
  DocumentWebSocketClient(
    this._backend, {
    bool simulateDrops = true,
    Duration meanUptime = const Duration(seconds: 30),
    Random? rng,
  })  : _simulateDrops = simulateDrops,
        _meanUptime = meanUptime,
        _rng = rng ?? Random();

  final MockDocumentBackend _backend;
  final bool _simulateDrops;
  final Duration _meanUptime;
  final Random _rng;

  final StreamController<WsStatusUpdate> _updatesOut =
      StreamController<WsStatusUpdate>.broadcast();
  final StreamController<DocumentConnectionState> _stateOut =
      StreamController<DocumentConnectionState>.broadcast();

  StreamSubscription<WsStatusUpdate>? _backendSub;
  Timer? _dropTimer;
  Timer? _reconnectTimer;
  int _retryAttempt = 0;
  bool _disposed = false;
  DocumentConnectionState _state = DocumentConnectionState.offline;
  final Set<String> _trackedServerIds = {};

  Stream<WsStatusUpdate> get updates => _updatesOut.stream;
  Stream<DocumentConnectionState> get connection => _stateOut.stream;
  DocumentConnectionState get currentState => _state;

  /// Tell the client which server-side ids we care about. Used to replay
  /// last-known updates on reconnect.
  void track(String serverId) => _trackedServerIds.add(serverId);
  void untrack(String serverId) => _trackedServerIds.remove(serverId);

  /// Open the connection. Idempotent.
  void connect() {
    if (_disposed) return;
    if (_state == DocumentConnectionState.connected) return;
    _setState(DocumentConnectionState.reconnecting);
    // Tiny "handshake" delay to feel real.
    Timer(const Duration(milliseconds: 350), _onConnected);
  }

  void _onConnected() {
    if (_disposed) return;
    _retryAttempt = 0;
    _backendSub?.cancel();
    _backendSub = _backend.updates.listen(_updatesOut.add);
    // Replay for catch-up after reconnect.
    for (final u in _backend.snapshot(_trackedServerIds)) {
      _updatesOut.add(u);
    }
    _setState(DocumentConnectionState.connected);
    if (_simulateDrops) _scheduleNextDrop();
  }

  void _scheduleNextDrop() {
    _dropTimer?.cancel();
    final base = _meanUptime.inMilliseconds;
    final jitter = _rng.nextInt(base ~/ 2);
    _dropTimer = Timer(
      Duration(milliseconds: base + jitter),
      _simulateDisconnect,
    );
  }

  void _simulateDisconnect() {
    if (_disposed) return;
    if (_state != DocumentConnectionState.connected) return;
    _backendSub?.cancel();
    _backendSub = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _retryAttempt++;
    // 1, 2, 4, 8, 16, 30 (cap)
    final seconds = min(30, pow(2, _retryAttempt - 1).toInt());
    _setState(DocumentConnectionState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: seconds), _attemptReconnect);
  }

  void _attemptReconnect() {
    if (_disposed) return;
    _onConnected();
  }

  /// Manual reconnect — used by the offline-banner button and tests.
  void reconnect() {
    _retryAttempt = 0;
    _dropTimer?.cancel();
    _reconnectTimer?.cancel();
    _backendSub?.cancel();
    _backendSub = null;
    _setState(DocumentConnectionState.reconnecting);
    Timer(const Duration(milliseconds: 200), _onConnected);
  }

  /// Tear down. Safe to call multiple times.
  Future<void> dispose() async {
    _disposed = true;
    _dropTimer?.cancel();
    _reconnectTimer?.cancel();
    await _backendSub?.cancel();
    _setState(DocumentConnectionState.offline);
    await _updatesOut.close();
    await _stateOut.close();
  }

  void _setState(DocumentConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateOut.isClosed) _stateOut.add(s);
  }
}

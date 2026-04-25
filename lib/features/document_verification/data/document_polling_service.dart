import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:untitled2/features/document_verification/data/document_api_client.dart';
import 'package:untitled2/features/document_verification/data/mock_document_backend.dart';

/// Polls `GET /documents/{id}/status` for tracked ids while the WebSocket
/// is offline. The repository starts/stops it based on connection state —
/// it never runs concurrently with a connected WS, so we do not double-count
/// updates.
///
/// Why a separate service rather than inlining the logic in the repo?
/// Polling is a cross-cutting strategy with its own concerns (interval
/// jitter, per-id failure isolation, batched updates). Keeping it separate
/// means the repo stays thin and the polling logic stays testable.
class DocumentPollingService {
  DocumentPollingService(this._api, {Duration interval = const Duration(seconds: 4)})
      : _interval = interval;

  final DocumentApiClient _api;
  final Duration _interval;

  final Set<String> _watching = {};
  Timer? _timer;
  bool _running = false;
  bool _busy = false; // re-entry guard while a tick is in flight

  final StreamController<StatusResponse> _out =
      StreamController<StatusResponse>.broadcast();
  Stream<StatusResponse> get updates => _out.stream;

  bool get isRunning => _running;
  Set<String> get watching => Set.unmodifiable(_watching);

  void watch(String serverId) {
    _watching.add(serverId);
    if (_running) _ensureTimer();
  }

  void unwatch(String serverId) {
    _watching.remove(serverId);
    if (_watching.isEmpty) _timer?.cancel();
  }

  void start() {
    if (_running) return;
    _running = true;
    _ensureTimer();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _ensureTimer() {
    if (!_running || _watching.isEmpty) return;
    _timer ??= Timer.periodic(_interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_busy) return; // skip if previous tick is still running
    _busy = true;
    try {
      // Snapshot — avoid issues if the set mutates during the loop.
      final ids = List.of(_watching);
      for (final id in ids) {
        try {
          final resp = await _api.status(id);
          if (_out.isClosed) return;
          _out.add(resp);
        } catch (e, st) {
          // Per-id isolation: one bad doc must not stop the rest.
          if (kDebugMode) {
            debugPrint('[polling] $id failed: $e\n$st');
          }
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    stop();
    await _out.close();
  }
}

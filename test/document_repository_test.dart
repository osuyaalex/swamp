import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:untitled2/features/document_verification/data/document_api_client.dart';
import 'package:untitled2/features/document_verification/data/document_polling_service.dart';
import 'package:untitled2/features/document_verification/data/document_repository_impl.dart';
import 'package:untitled2/features/document_verification/data/document_websocket_client.dart';
import 'package:untitled2/features/document_verification/data/mock_document_backend.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';

DocumentBytes _bytes() => DocumentBytes(
      bytes: Uint8List.fromList(List.filled(2048, 0x42)),
      originalName: 'sample.png',
      mimeType: 'image/png',
      size: 2048,
      checksum: 'abc',
    );

/// Builds a repo with deterministic, fast timings and no random WS drops.
Future<({
  DocumentRepositoryImpl repo,
  MockDocumentBackend backend,
  DocumentWebSocketClient ws,
  DocumentPollingService polling,
  SharedPreferences prefs,
})> _setup({double rejectionRate = 0, SharedPreferences? prefs}) async {
  SharedPreferences.setMockInitialValues({});
  final p = prefs ?? await SharedPreferences.getInstance();
  final backend = MockDocumentBackend(
    uploadLatency: const Duration(milliseconds: 8),
    pollLatency: const Duration(milliseconds: 5),
    stageDuration: const Duration(milliseconds: 40),
    rejectionRate: rejectionRate,
  );
  final api = DocumentApiClient(backend);
  final ws = DocumentWebSocketClient(backend, simulateDrops: false);
  final polling = DocumentPollingService(
    api,
    interval: const Duration(milliseconds: 30),
  );
  final repo = DocumentRepositoryImpl(
    api: api,
    ws: ws,
    polling: polling,
    prefs: p,
  );
  return (
    repo: repo,
    backend: backend,
    ws: ws,
    polling: polling,
    prefs: p,
  );
}

Future<List<Document>> _waitFor(
  Stream<List<Document>> stream,
  bool Function(List<Document>) predicate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  return stream
      .firstWhere(predicate)
      .timeout(timeout, onTimeout: () => throw TimeoutException('predicate'));
}

void main() {
  group('DocumentRepository', () {
    test('upload immediately surfaces an optimistic uploading entry, '
        'then transitions through the verified flow', () async {
      final s = await _setup();

      // Subscribe BEFORE upload so we capture the optimistic emit.
      final firstEmit = s.repo.watch().first;

      unawaited(s.repo.upload(type: DocumentType.passport, bytes: _bytes()));

      final initial = await firstEmit;
      expect(initial.length, 1);
      expect(initial.single.status, DocumentStatus.uploading);
      expect(initial.single.serverId, isNull);

      // Wait for terminal state.
      final done = await _waitFor(
        s.repo.watch(),
        (list) => list.isNotEmpty && list.single.status == DocumentStatus.verified,
      );
      expect(done.single.serverId, isNotNull);
      expect(done.single.audit.any((a) => a.kind == AuditKind.verified), isTrue);

      await s.repo.dispose();
      await s.backend.dispose();
    });

    test('upload rolls back to queued when the API throws', () async {
      // Custom backend whose upload throws synchronously on first call.
      final backend = _ThrowingBackend();
      final api = DocumentApiClient(backend);
      final ws = DocumentWebSocketClient(backend, simulateDrops: false);
      final polling = DocumentPollingService(api);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = DocumentRepositoryImpl(
        api: api,
        ws: ws,
        polling: polling,
        prefs: prefs,
      );

      final result =
          await repo.upload(type: DocumentType.nationalId, bytes: _bytes());

      expect(result.status, DocumentStatus.queued);
      expect(result.serverId, isNull);
      expect(
        result.audit.any((a) => a.message.contains('Upload failed')),
        isTrue,
      );

      await repo.dispose();
      await backend.dispose();
    });

    test('retry on a queued doc re-uploads and reaches uploaded state',
        () async {
      final backend = _ThrowingBackend(failOnce: true);
      final api = DocumentApiClient(backend);
      final ws = DocumentWebSocketClient(backend, simulateDrops: false);
      final polling = DocumentPollingService(api);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = DocumentRepositoryImpl(
        api: api,
        ws: ws,
        polling: polling,
        prefs: prefs,
      );

      final failed =
          await repo.upload(type: DocumentType.passport, bytes: _bytes());
      expect(failed.status, DocumentStatus.queued);

      final retried = await repo.retry(failed.id);
      // Second upload succeeds.
      expect(retried.status, DocumentStatus.uploaded);
      expect(retried.serverId, isNotNull);
      expect(
        retried.audit.any((a) => a.kind == AuditKind.retried),
        isTrue,
      );

      await repo.dispose();
      await backend.dispose();
    });

    test('persistence: docs hydrate into a fresh repository instance',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final s1 = await _setup(prefs: prefs);
      await s1.repo.upload(type: DocumentType.passport, bytes: _bytes());

      // Allow the persist write to flush.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await s1.repo.dispose();
      await s1.backend.dispose();

      final s2 = await _setup(prefs: prefs);
      final hydrated = await s2.repo.loadAll();
      expect(hydrated.length, 1);
      expect(hydrated.single.type, DocumentType.passport);
      // Bytes are not persisted, so the hydrated doc has no payload.
      expect(hydrated.single.bytes, isNull);

      await s2.repo.dispose();
      await s2.backend.dispose();
    });
  });

  group('DocumentWebSocketClient', () {
    test('manual reconnect cycles state: reconnecting -> connected', () async {
      final backend = MockDocumentBackend();
      final ws = DocumentWebSocketClient(backend, simulateDrops: false);

      final states = <DocumentConnectionState>[];
      final sub = ws.connection.listen(states.add);

      ws.connect();
      // Allow the simulated handshake to complete.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(ws.currentState, DocumentConnectionState.connected);

      ws.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(ws.currentState, DocumentConnectionState.connected);

      // Should have seen at least one reconnecting and one connected emission.
      expect(states.contains(DocumentConnectionState.reconnecting), isTrue);
      expect(states.contains(DocumentConnectionState.connected), isTrue);

      await sub.cancel();
      await ws.dispose();
      await backend.dispose();
    });
  });

  group('DocumentPollingService', () {
    test('emits status responses for tracked ids while running', () async {
      final backend = MockDocumentBackend(
        uploadLatency: const Duration(milliseconds: 5),
        pollLatency: const Duration(milliseconds: 2),
        stageDuration: const Duration(milliseconds: 30),
        rejectionRate: 0,
      );
      final api = DocumentApiClient(backend);
      final polling = DocumentPollingService(
        api,
        interval: const Duration(milliseconds: 25),
      );

      final upload = await api.upload(
        type: DocumentType.utilityBill,
        bytes: _bytes(),
      );

      final responses = <StatusResponse>[];
      final sub = polling.updates.listen(responses.add);

      polling.start();
      polling.watch(upload.id);

      // Let a few ticks fire.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      polling.stop();
      polling.unwatch(upload.id);

      expect(responses.isNotEmpty, isTrue);
      expect(responses.every((r) => r.id == upload.id), isTrue);

      await sub.cancel();
      await polling.dispose();
      await backend.dispose();
    });

    test('does not double-tick when an in-flight tick is still running',
        () async {
      // Backend with a slow `status` call — slower than the polling interval.
      final backend = MockDocumentBackend(
        pollLatency: const Duration(milliseconds: 80),
        stageDuration: const Duration(milliseconds: 200),
      );
      final api = DocumentApiClient(backend);
      final polling = DocumentPollingService(
        api,
        interval: const Duration(milliseconds: 20),
      );
      final upload = await api.upload(
        type: DocumentType.passport,
        bytes: _bytes(),
      );

      final timestamps = <DateTime>[];
      final sub = polling.updates.listen((_) => timestamps.add(DateTime.now()));

      polling.start();
      polling.watch(upload.id);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      polling.stop();
      polling.unwatch(upload.id);

      // Adjacent emissions should be at least pollLatency apart, never
      // ~interval apart, because the busy guard skips overlapping ticks.
      for (var i = 1; i < timestamps.length; i++) {
        final gap = timestamps[i].difference(timestamps[i - 1]);
        expect(
          gap.inMilliseconds,
          greaterThanOrEqualTo(40),
          reason: 'consecutive updates must respect the busy guard',
        );
      }

      await sub.cancel();
      await polling.dispose();
      await backend.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Backend whose upload either always throws ([failOnce]=false) or throws
/// only on the first call ([failOnce]=true). Used to drive the rollback +
/// retry tests deterministically.
class _ThrowingBackend extends MockDocumentBackend {
  _ThrowingBackend({this.failOnce = false})
      : super(
          uploadLatency: const Duration(milliseconds: 5),
          pollLatency: const Duration(milliseconds: 2),
          stageDuration: const Duration(milliseconds: 40),
          rejectionRate: 0,
        );

  final bool failOnce;
  int _calls = 0;

  @override
  Future<UploadResponse> upload({
    required DocumentType type,
    required String originalName,
    required int size,
    required String checksum,
  }) async {
    _calls++;
    if (!failOnce || _calls == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      throw const _FakeNetworkException();
    }
    return super.upload(
      type: type,
      originalName: originalName,
      size: size,
      checksum: checksum,
    );
  }
}

class _FakeNetworkException implements Exception {
  const _FakeNetworkException();
  @override
  String toString() => 'network down';
}

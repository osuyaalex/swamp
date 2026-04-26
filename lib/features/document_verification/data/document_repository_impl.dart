import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:untitled2/core/audit_signing.dart';
import 'package:untitled2/core/device_identity.dart';
import 'package:untitled2/core/id.dart';
import 'package:untitled2/features/document_verification/data/document_api_client.dart';
import 'package:untitled2/features/document_verification/data/document_polling_service.dart';
import 'package:untitled2/features/document_verification/data/document_websocket_client.dart';
import 'package:untitled2/features/document_verification/data/mock_document_backend.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/domain/repositories/document_repository.dart';

/// Single source of truth for the document feature.
///
/// Wires together three async sources:
///   • HTTP (api)        — uploads, status fetches
///   • WebSocket (ws)    — real-time status updates while connected
///   • Polling (poll)    — fallback while ws is reconnecting/offline
///
/// Plus persistence (shared_preferences) for restart recovery and
/// optimistic-update bookkeeping (rollback on upload failure).
class DocumentRepositoryImpl implements DocumentRepository {
  DocumentRepositoryImpl({
    required DocumentApiClient api,
    required DocumentWebSocketClient ws,
    required DocumentPollingService polling,
    SharedPreferences? prefs,
    AuditSigner? signer,
    DeviceIdentity? deviceIdentity,
    String prefsKey = 'document_verification.docs.v1',
  })  : _api = api,
        _ws = ws,
        _polling = polling,
        _prefs = prefs,
        _signer = signer,
        _deviceIdentity = deviceIdentity,
        _prefsKey = prefsKey {
    _wireSubscriptions();
    _ws.connect();
  }

  final DocumentApiClient _api;
  final DocumentWebSocketClient _ws;
  final DocumentPollingService _polling;
  final SharedPreferences? _prefs;
  final AuditSigner? _signer;
  final DeviceIdentity? _deviceIdentity;
  final String _prefsKey;

  /// Audit-trail enrichment cache. Populated lazily on first use so the
  /// initial render isn't blocked on `package_info_plus`/keystore reads.
  String? _cachedDeviceId;
  String? _cachedAppVersion;

  Future<({String deviceId, String appVersion})> _identity() async {
    if (_deviceIdentity == null) {
      return (deviceId: '', appVersion: '');
    }
    _cachedDeviceId ??= await _deviceIdentity.deviceId();
    _cachedAppVersion ??= await _deviceIdentity.appVersion();
    return (deviceId: _cachedDeviceId!, appVersion: _cachedAppVersion!);
  }

  /// Build an audit entry enriched with actor / device id / app version
  /// and (if a signer is wired) HMAC + prevHash chain.
  Future<AuditEntry> _buildAudit({
    required List<AuditEntry> prevAudit,
    required AuditKind kind,
    required String message,
    String actor = 'system',
  }) async {
    final id = await _identity();
    final prevSig = prevAudit.isEmpty ? '' : prevAudit.last.signature;

    var entry = AuditEntry(
      id: IdGen.next('a'),
      kind: kind,
      message: message,
      at: DateTime.now(),
      actor: actor,
      deviceId: id.deviceId,
      appVersion: id.appVersion,
      prevHash: _signer?.prevHashOf(prevSig) ?? '',
    );

    if (_signer != null) {
      final signature = await _signer.sign(
        payload: entry.canonicalPayload(),
        prevSignature: prevSig,
      );
      entry = AuditEntry(
        id: entry.id,
        kind: entry.kind,
        message: entry.message,
        at: entry.at,
        actor: entry.actor,
        deviceId: entry.deviceId,
        appVersion: entry.appVersion,
        prevHash: entry.prevHash,
        signature: signature,
      );
    }
    return entry;
  }

  /// Public hook for the UI/controller to append an audit entry from
  /// outside the repository — e.g. biometric grant/deny events on the
  /// detail sheet. Idempotent against unknown ids.
  @override
  Future<void> appendAudit({
    required String documentId,
    required AuditKind kind,
    required String message,
    String actor = 'You',
  }) async {
    final current = _byId[documentId];
    if (current == null) return;
    final entry = await _buildAudit(
      prevAudit: current.audit,
      kind: kind,
      message: message,
      actor: actor,
    );
    _byId[documentId] = current.copyWith(audit: [...current.audit, entry]);
    _emit();
  }

  final Map<String, Document> _byId = {};
  final StreamController<List<Document>> _outDocs =
      StreamController<List<Document>>.broadcast();
  final StreamController<DocumentConnectionState> _outConn =
      StreamController<DocumentConnectionState>.broadcast();

  StreamSubscription<WsStatusUpdate>? _wsSub;
  StreamSubscription<DocumentConnectionState>? _connSub;
  StreamSubscription<StatusResponse>? _pollSub;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Future<List<Document>> loadAll() async {
    if (_byId.isEmpty) await _hydrate();
    return _snapshot();
  }

  @override
  Stream<List<Document>> watch() => _outDocs.stream;

  @override
  Stream<DocumentConnectionState> watchConnection() => _outConn.stream;

  @override
  Future<Document> upload({
    required DocumentType type,
    required DocumentBytes bytes,
  }) async {
    // 1. Optimistic insert with the first signed audit entry.
    final localId = IdGen.next('doc');
    final now = DateTime.now();
    final firstEntry = await _buildAudit(
      prevAudit: const [],
      kind: AuditKind.uploaded,
      message: '${type.label} queued for upload',
      actor: 'You',
    );
    Document doc = Document(
      id: localId,
      type: type,
      status: DocumentStatus.uploading,
      progress: 0.0,
      originalName: bytes.originalName,
      size: bytes.size,
      checksum: bytes.checksum,
      createdAt: now,
      bytes: bytes,
      audit: [firstEntry],
    );
    _byId[localId] = doc;
    _emit();

    // 2. Try the upload, roll back on failure.
    try {
      final resp = await _api.upload(type: type, bytes: bytes);
      final entry = await _buildAudit(
        prevAudit: doc.audit,
        kind: AuditKind.statusChanged,
        message: 'Uploaded to server (id ${resp.id.substring(0, 8)}…)',
      );
      doc = doc.copyWith(
        serverId: resp.id,
        status: DocumentStatus.uploaded,
        uploadedAt: resp.uploadedAt,
        audit: [...doc.audit, entry],
      );
      _byId[localId] = doc;
      _track(resp.id);
      _emit();
      return doc;
    } catch (e) {
      final entry = await _buildAudit(
        prevAudit: doc.audit,
        kind: AuditKind.statusChanged,
        message: 'Upload failed: $e — tap retry',
      );
      doc = doc.copyWith(
        status: DocumentStatus.queued,
        audit: [...doc.audit, entry],
      );
      _byId[localId] = doc;
      _emit();
      return doc;
    }
  }

  @override
  Future<Document> retry(String documentId) async {
    final current = _byId[documentId];
    if (current == null) {
      throw StateError('Unknown document: $documentId');
    }
    if (current.bytes == null) {
      throw StateError(
        'Cannot retry $documentId — file bytes were not retained '
        '(this can happen after a cold start; ask the user to re-pick).',
      );
    }
    if (current.serverId != null) _untrack(current.serverId!);

    final retryEntry = await _buildAudit(
      prevAudit: current.audit,
      kind: AuditKind.retried,
      message: 'Retry triggered',
      actor: 'You',
    );
    final retried = current.copyWith(
      status: DocumentStatus.uploading,
      progress: 0,
      stage: null,
      issues: const [],
      clearRejection: true,
      audit: [...current.audit, retryEntry],
    );
    _byId[documentId] = retried;
    _emit();

    try {
      final resp = await _api.upload(type: current.type, bytes: current.bytes!);
      final entry = await _buildAudit(
        prevAudit: retried.audit,
        kind: AuditKind.statusChanged,
        message: 'Re-uploaded — awaiting verification',
      );
      final next = retried.copyWith(
        serverId: resp.id,
        status: DocumentStatus.uploaded,
        uploadedAt: resp.uploadedAt,
        audit: [...retried.audit, entry],
      );
      _byId[documentId] = next;
      _track(resp.id);
      _emit();
      return next;
    } catch (e) {
      final entry = await _buildAudit(
        prevAudit: retried.audit,
        kind: AuditKind.statusChanged,
        message: 'Retry failed: $e',
      );
      final failed = retried.copyWith(
        status: DocumentStatus.queued,
        audit: [...retried.audit, entry],
      );
      _byId[documentId] = failed;
      _emit();
      return failed;
    }
  }

  @override
  Future<void> delete(String documentId) async {
    final doc = _byId.remove(documentId);
    if (doc?.serverId != null) _untrack(doc!.serverId!);
    _emit();
  }

  @override
  Future<void> updateEnrichment({
    required String documentId,
    Uint8List? thumbnailBytes,
    OcrResult? ocrResult,
  }) async {
    final current = _byId[documentId];
    if (current == null) return;
    final next = current.copyWith(
      thumbnailBytes: thumbnailBytes,
      ocrResult: ocrResult,
    );
    _byId[documentId] = next;
    _emit();
  }

  @override
  Future<void> reconnect() async {
    _ws.reconnect();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _wsSub?.cancel();
    await _connSub?.cancel();
    await _pollSub?.cancel();
    await _ws.dispose();
    await _polling.dispose();
    await _outDocs.close();
    await _outConn.close();
  }

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------

  void _wireSubscriptions() {
    _wsSub = _ws.updates.listen(_applyWsUpdate);
    _connSub = _ws.connection.listen(_onConnectionChanged);
    _pollSub = _polling.updates.listen(_applyPollUpdate);
  }

  void _onConnectionChanged(DocumentConnectionState state) {
    if (!_outConn.isClosed) _outConn.add(state);
    if (state == DocumentConnectionState.connected) {
      _polling.stop();
    } else {
      // Offline or reconnecting — fall back to polling to keep UI live.
      _polling.start();
      // Re-track any pending docs in case `track` was never called.
      for (final d in _byId.values) {
        if (d.serverId != null && _shouldTrack(d.status)) {
          _polling.watch(d.serverId!);
        }
      }
    }
  }

  void _track(String serverId) {
    _ws.track(serverId);
    _polling.watch(serverId);
  }

  void _untrack(String serverId) {
    _ws.untrack(serverId);
    _polling.unwatch(serverId);
  }

  bool _shouldTrack(DocumentStatus s) =>
      s == DocumentStatus.uploaded || s == DocumentStatus.processing;

  void _applyWsUpdate(WsStatusUpdate u) => _applyStatusUpdate(
        serverId: u.documentId,
        wireStatus: u.status,
        progress: u.progress,
        stage: u.stage,
        confidence: u.confidence,
        issues: u.issues,
      );

  void _applyPollUpdate(StatusResponse r) => _applyStatusUpdate(
        serverId: r.id,
        wireStatus: r.status,
        progress: r.progress,
        verifiedAt: r.verifiedAt,
        rejectionReason: r.rejectionReason,
        expiresAt: r.expiresAt,
      );

  /// Single update path used by both WS and polling — keeps the logic for
  /// status transitions (and audit-trail entries) in one place so the two
  /// sources can never disagree on what "moving to VERIFIED" means.
  Future<void> _applyStatusUpdate({
    required String serverId,
    required String wireStatus,
    required double progress,
    String? stage,
    double? confidence,
    List<String>? issues,
    DateTime? verifiedAt,
    String? rejectionReason,
    DateTime? expiresAt,
  }) async {
    final localId = _byId.entries
        .firstWhere(
          (e) => e.value.serverId == serverId,
          orElse: () => MapEntry('', _placeholder()),
        )
        .key;
    if (localId.isEmpty) return; // unknown — drop
    final current = _byId[localId]!;
    final newStatus = DocumentStatusX.fromWire(wireStatus);
    final crossed = current.status != newStatus;

    final audit = <AuditEntry>[...current.audit];
    if (crossed) {
      final entry = await _buildAudit(
        prevAudit: current.audit,
        kind: switch (newStatus) {
          DocumentStatus.verified => AuditKind.verified,
          DocumentStatus.rejected => AuditKind.rejected,
          _ => AuditKind.statusChanged,
        },
        message: switch (newStatus) {
          DocumentStatus.verified =>
            'Verified${confidence == null ? '' : ' (${(confidence * 100).round()}%)'}',
          DocumentStatus.rejected =>
            'Rejected${rejectionReason == null ? '' : ': $rejectionReason'}',
          DocumentStatus.processing =>
            'Processing started${stage == null ? '' : ' — $stage'}',
          _ => newStatus.label,
        },
      );
      audit.add(entry);
    }

    final next = current.copyWith(
      status: newStatus,
      progress: progress.clamp(0, 1),
      stage: stage,
      confidence: confidence,
      issues: issues ?? current.issues,
      verifiedAt: verifiedAt ?? current.verifiedAt,
      expiresAt: expiresAt ?? current.expiresAt,
      rejectionReason: rejectionReason,
      audit: audit,
    );
    _byId[localId] = next;

    if (next.status.isTerminal) {
      _untrack(serverId);
    }
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> _hydrate() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final json in list) {
        final doc = Document.fromJson(json);
        // After a cold start, anything that was mid-upload returns to
        // queued so the user is prompted to retry — bytes are not
        // persisted (they belong to a previous picker session).
        final repaired = doc.status == DocumentStatus.uploading
            ? doc.copyWith(status: DocumentStatus.queued, clearBytes: true)
            : doc;
        _byId[repaired.id] = repaired;
        if (repaired.serverId != null && _shouldTrack(repaired.status)) {
          _track(repaired.serverId!);
        }
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[document_repo] hydrate failed: $e\n$st');
      }
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final list = _byId.values.map((d) => d.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _emit() {
    if (_outDocs.isClosed) return;
    _outDocs.add(_snapshot());
    // Persistence is fire-and-forget. Failures get logged in debug mode.
    unawaited(_persist());
  }

  List<Document> _snapshot() {
    final all = _byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(all);
  }

  /// Cheap stand-in used by `firstWhere` when the doc is not in our map.
  static Document _placeholder() => Document(
        id: '',
        type: DocumentType.passport,
        status: DocumentStatus.queued,
        progress: 0,
        originalName: '',
        size: 0,
        checksum: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        audit: const [],
      );
}

import 'dart:typed_data';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';

abstract class DocumentRepository {
  /// Snapshot of every known document on first read; in practice the UI
  /// listens to [watch] and treats this as just the cold-start hydrate.
  Future<List<Document>> loadAll();

  /// Stream of the full document list. Emits on every change so the UI
  /// can render with a single source of truth instead of patching deltas.
  Stream<List<Document>> watch();

  /// Connection-quality stream. Drives the "Reconnecting…" banner.
  Stream<DocumentConnectionState> watchConnection();

  /// Optimistic upload: returns immediately with a local Document in
  /// `uploading` state; the impl drives status transitions through the
  /// returned stream. If the upload fails the document is rolled back to
  /// `queued` with an audit entry explaining why.
  Future<Document> upload({
    required DocumentType type,
    required DocumentBytes bytes,
  });

  /// Re-upload a document that previously failed or was rejected.
  Future<Document> retry(String documentId);

  /// Forget a document locally. The server-side record is untouched
  /// (the spec doesn't define delete) but for the UI it disappears.
  Future<void> delete(String documentId);

  /// Force a connection cycle — useful for tests and the manual reconnect
  /// button on the offline banner.
  Future<void> reconnect();

  /// Append a compliance-grade audit entry from outside the repository
  /// (e.g. biometric grant/deny events on the document detail sheet).
  /// Signed and chained the same way as repo-internal entries.
  Future<void> appendAudit({
    required String documentId,
    required AuditKind kind,
    required String message,
    String actor = 'You',
  });

  /// Attach an isolate-produced thumbnail and/or OCR result to a document
  /// after the optimistic upload has already returned. Either argument
  /// may be `null` to skip that enrichment.
  Future<void> updateEnrichment({
    required String documentId,
    Uint8List? thumbnailBytes,
    OcrResult? ocrResult,
  });

  /// Release timers, websocket, etc. Called when the app shuts down.
  Future<void> dispose();
}

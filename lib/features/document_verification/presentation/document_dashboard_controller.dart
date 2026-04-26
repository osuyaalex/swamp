import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:untitled2/core/biometrics.dart';
import 'package:untitled2/core/image_processor.dart';
import 'package:untitled2/features/document_verification/data/document_source.dart';
import 'package:untitled2/features/document_verification/data/ocr_service.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/domain/repositories/document_repository.dart';

class DocumentDashboardController extends ChangeNotifier {
  DocumentDashboardController({
    required DocumentRepository repository,
    required DocumentSource source,
    required Biometrics biometrics,
    required OcrService ocrService,
  })  : _repo = repository,
        _source = source,
        _biometrics = biometrics,
        _ocrService = ocrService {
    _bootstrap();
  }

  final DocumentRepository _repo;
  final DocumentSource _source;
  final Biometrics _biometrics;
  final OcrService _ocrService;

  /// Repository handle exposed for screens that need to append audit
  /// entries from outside the controller's own operations (e.g. the
  /// detail sheet's biometric grant/deny events).
  DocumentRepository get repository => _repo;

  Biometrics get biometrics => _biometrics;

  bool _loading = true;
  bool get loading => _loading;

  List<Document> _documents = const [];
  List<Document> get documents => _documents;

  DocumentConnectionState _connection = DocumentConnectionState.reconnecting;
  DocumentConnectionState get connection => _connection;

  String? _lastError;
  String? get lastError => _lastError;

  StreamSubscription<List<Document>>? _docsSub;
  StreamSubscription<DocumentConnectionState>? _connSub;

  Future<void> _bootstrap() async {
    _documents = await _repo.loadAll();
    _docsSub = _repo.watch().listen((next) {
      _documents = next;
      notifyListeners();
    });
    _connSub = _repo.watchConnection().listen((next) {
      _connection = next;
      notifyListeners();
    });
    // Recover any camera-intent result lost to an Android process kill.
    // No-op on iOS / web.
    unawaited(_recoverLostCameraData());
    _loading = false;
    notifyListeners();
  }

  Future<void> _recoverLostCameraData() async {
    try {
      final bytes = await _source.retrieveLostData();
      if (bytes == null) return;
      // We don't know which type the user had picked, since the
      // pickAndUpload future died with the process. Default to passport
      // — the user can re-upload as a different type if they meant
      // something else. Worst case: a redundant upload they can delete.
      final doc = await _repo.upload(type: DocumentType.passport, bytes: bytes);
      _enrichWithThumbnail(doc.id, bytes);
      _enrichWithOcr(doc.id, bytes);
    } catch (_) {
      // Lost-data recovery is best-effort — never raise to the user.
    }
  }

  // ----- UI-facing operations ------------------------------------------------

  /// Pick from the given [kind] and immediately upload as [type]. Errors
  /// from the picker (size/mime/cancelled) are surfaced via [lastError]
  /// without throwing; the dashboard reads it and shows a SnackBar.
  ///
  /// After upload returns, kicks off OCR + thumbnail generation in the
  /// background. Both run in isolates so the dashboard stays responsive
  /// even on a low-end device. Results are merged into the document
  /// asynchronously — the UI reactively picks them up via the doc list
  /// stream.
  Future<void> pickAndUpload({
    required DocumentType type,
    required DocumentSourceKind kind,
  }) async {
    _lastError = null;
    notifyListeners();
    try {
      final bytes = await _source.pick(kind);
      if (bytes == null) return; // user cancelled — silent
      final doc = await _repo.upload(type: type, bytes: bytes);
      // Fire-and-forget — these enrich the doc but shouldn't block the
      // upload return. They each run in their own isolate.
      _enrichWithThumbnail(doc.id, bytes);
      _enrichWithOcr(doc.id, bytes);
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  /// Capture pre-built bytes (e.g. from the custom camera) and upload
  /// them directly, bypassing the normal picker. Same enrichment as
  /// [pickAndUpload].
  Future<Document?> uploadBytes({
    required DocumentType type,
    required DocumentBytes bytes,
  }) async {
    _lastError = null;
    notifyListeners();
    try {
      final doc = await _repo.upload(type: type, bytes: bytes);
      _enrichWithThumbnail(doc.id, bytes);
      _enrichWithOcr(doc.id, bytes);
      return doc;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> _enrichWithThumbnail(
    String documentId,
    DocumentBytes bytes,
  ) async {
    final thumb = await ImageProcessor.thumbnail(bytes.bytes);
    if (thumb == null) return;
    await _repo.updateEnrichment(
      documentId: documentId,
      thumbnailBytes: thumb,
    );
  }

  Future<void> _enrichWithOcr(
    String documentId,
    DocumentBytes bytes,
  ) async {
    final result = await _ocrService.process(
      bytes: bytes.bytes,
      mimeType: bytes.mimeType,
    );
    if (result == null) return;
    await _repo.updateEnrichment(
      documentId: documentId,
      ocrResult: result,
    );
    // Surface key OCR fields in the audit trail.
    final fieldsLine = result.fields.entries
        .take(3)
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
    await _repo.appendAudit(
      documentId: documentId,
      kind: AuditKind.statusChanged,
      message: fieldsLine.isEmpty
          ? 'OCR ran (${result.blocks.length} blocks recognised)'
          : 'OCR extracted — $fieldsLine',
      actor: 'system',
    );
  }

  Future<void> retry(String documentId) async {
    _lastError = null;
    notifyListeners();
    try {
      await _repo.retry(documentId);
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> delete(String documentId) async {
    await _repo.delete(documentId);
  }

  Future<void> reconnect() async {
    await _repo.reconnect();
  }

  /// Gate sensitive document views behind a biometric prompt. Returns
  /// true if the user passed the prompt (or no biometric is available
  /// on the device — we fall back to allowing access rather than
  /// soft-locking the user out of their own data).
  ///
  /// Either outcome is recorded on the document's audit trail so a
  /// compliance auditor can see who accessed what, and from which
  /// device, when.
  Future<bool> authenticateForView({
    required String documentId,
    required String reason,
  }) async {
    final available = await _biometrics.isAvailable();
    if (!available) {
      await _repo.appendAudit(
        documentId: documentId,
        kind: AuditKind.accessGranted,
        message: 'Access granted (no biometric available on device)',
      );
      return true;
    }
    final ok = await _biometrics.authenticate(reason: reason);
    await _repo.appendAudit(
      documentId: documentId,
      kind: ok ? AuditKind.accessGranted : AuditKind.accessDenied,
      message: ok
          ? 'Access granted via biometric'
          : 'Biometric prompt failed or cancelled',
    );
    return ok;
  }

  /// UI helper: counts of docs in each terminal state, used by the dashboard
  /// summary header.
  ({int verified, int rejected, int pending}) get summary {
    var v = 0, r = 0, p = 0;
    for (final d in _documents) {
      switch (d.status) {
        case DocumentStatus.verified:
          v++;
        case DocumentStatus.rejected:
          r++;
        case DocumentStatus.queued:
        case DocumentStatus.uploading:
        case DocumentStatus.uploaded:
        case DocumentStatus.processing:
          p++;
      }
    }
    return (verified: v, rejected: r, pending: p);
  }

  @override
  void dispose() {
    _docsSub?.cancel();
    _connSub?.cancel();
    _repo.dispose();
    super.dispose();
  }
}

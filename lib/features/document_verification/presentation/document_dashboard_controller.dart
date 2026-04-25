import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:untitled2/features/document_verification/data/document_source.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/domain/repositories/document_repository.dart';

class DocumentDashboardController extends ChangeNotifier {
  DocumentDashboardController({
    required DocumentRepository repository,
    required DocumentSource source,
  })  : _repo = repository,
        _source = source {
    _bootstrap();
  }

  final DocumentRepository _repo;
  final DocumentSource _source;

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
    _loading = false;
    notifyListeners();
  }

  // ----- UI-facing operations ------------------------------------------------

  /// Pick from the given [kind] and immediately upload as [type]. Errors
  /// from the picker (size/mime/cancelled) are surfaced via [lastError]
  /// without throwing; the dashboard reads it and shows a SnackBar.
  Future<void> pickAndUpload({
    required DocumentType type,
    required DocumentSourceKind kind,
  }) async {
    _lastError = null;
    notifyListeners();
    try {
      final bytes = await _source.pick(kind);
      if (bytes == null) return; // user cancelled — silent
      await _repo.upload(type: type, bytes: bytes);
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
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

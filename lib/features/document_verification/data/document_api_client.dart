import 'package:untitled2/features/document_verification/data/mock_document_backend.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';

/// HTTP-shaped facade over the mock backend. Modelled on the spec's
/// REST endpoints so swapping in a real `package:http` client later is
/// just a matter of replacing the body of these two methods.
class DocumentApiClient {
  DocumentApiClient(this._backend);

  final MockDocumentBackend _backend;

  /// `POST /api/v1/documents/upload`
  Future<UploadResponse> upload({
    required DocumentType type,
    required DocumentBytes bytes,
  }) {
    return _backend.upload(
      type: type,
      originalName: bytes.originalName,
      size: bytes.size,
      checksum: bytes.checksum,
    );
  }

  /// `GET /api/v1/documents/{id}/status`
  Future<StatusResponse> status(String serverId) {
    return _backend.status(serverId);
  }
}

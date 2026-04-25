import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';

/// Where the user picked a document from.
enum DocumentSourceKind { camera, gallery, file }

/// Strategy interface — abstracted so unit tests can plug in a fake source
/// without touching `image_picker` / `file_picker`.
abstract class DocumentSource {
  Future<DocumentBytes?> pick(DocumentSourceKind kind);
}

/// Real implementation backed by `image_picker` and `file_picker`. Performs
/// inline quality validation (size + mime) before returning bytes.
class PlatformDocumentSource implements DocumentSource {
  PlatformDocumentSource({
    ImagePicker? imagePicker,
    int maxBytes = 10 * 1024 * 1024, // 10 MB
  })  : _imagePicker = imagePicker ?? ImagePicker(),
        _maxBytes = maxBytes;

  final ImagePicker _imagePicker;
  final int _maxBytes;

  static const _allowedMimes = {
    'image/jpeg',
    'image/jpg',
    'image/png',
    'application/pdf',
  };

  @override
  Future<DocumentBytes?> pick(DocumentSourceKind kind) async {
    return switch (kind) {
      DocumentSourceKind.camera => _pickImage(ImageSource.camera),
      DocumentSourceKind.gallery => _pickImage(ImageSource.gallery),
      DocumentSourceKind.file => _pickFile(),
    };
  }

  Future<DocumentBytes?> _pickImage(ImageSource source) async {
    final x = await _imagePicker.pickImage(
      source: source,
      // Light compression — caps the longest edge at ~2400px and quality
      // at 85, keeping uploads under a few MB without re-encoding to a
      // visibly degraded image.
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 85,
    );
    if (x == null) return null;
    final bytes = await x.readAsBytes();
    return _validateAndWrap(bytes, x.name, _mimeFromName(x.name));
  }

  Future<DocumentBytes?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      throw const _PickerException('File contained no data.');
    }
    return _validateAndWrap(bytes, file.name, _mimeFromName(file.name));
  }

  DocumentBytes _validateAndWrap(Uint8List bytes, String name, String mime) {
    if (!_allowedMimes.contains(mime)) {
      throw _PickerException(
        'Unsupported file type ($mime). Use JPG, PNG, or PDF.',
      );
    }
    if (bytes.length > _maxBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw _PickerException(
        'File is $mb MB — limit is ${(_maxBytes / (1024 * 1024)).round()} MB.',
      );
    }
    if (bytes.length < 1024) {
      throw const _PickerException(
        'File looks empty or corrupt (under 1 KB).',
      );
    }
    return DocumentBytes(
      bytes: bytes,
      originalName: name,
      mimeType: mime,
      size: bytes.length,
      checksum: _quickChecksum(bytes),
    );
  }

  static String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  /// Tiny non-cryptographic checksum so the API metadata field is non-empty
  /// without pulling in `package:crypto`. The mock backend does not verify
  /// it; production would substitute SHA-256 here.
  static String _quickChecksum(Uint8List bytes) {
    var h = 0xcbf29ce484222325; // FNV-1a 64-bit offset basis
    for (final b in bytes) {
      h = (h ^ b) & 0xFFFFFFFFFFFFFFFF;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }
}

/// Surfaced as a regular Exception so the controller can render its
/// message in a SnackBar without sniffing types.
class _PickerException implements Exception {
  const _PickerException(this.message);
  final String message;

  @override
  String toString() => message;
}

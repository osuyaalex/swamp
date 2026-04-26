import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'package:untitled2/core/image_processor.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';

/// Where the user picked a document from.
enum DocumentSourceKind { camera, gallery, file }

/// Strategy interface — abstracted so unit tests can plug in a fake source
/// without touching `image_picker` / `file_picker`.
abstract class DocumentSource {
  Future<DocumentBytes?> pick(DocumentSourceKind kind);

  /// On Android, camera intents can be killed by the OS under memory
  /// pressure. The plugin caches the picked file and exposes it via
  /// `retrieveLostData`; call this on app resume to recover anything
  /// that didn't make it back through the original future.
  Future<DocumentBytes?> retrieveLostData();
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

  @override
  Future<DocumentBytes?> retrieveLostData() async {
    final lost = await _imagePicker.retrieveLostData();
    if (lost.isEmpty || lost.file == null) return null;
    final file = lost.file!;
    final bytes = await file.readAsBytes();
    return _validateAndWrap(bytes, file.name, _mimeFromName(file.name));
  }

  /// Validate then wrap. Checksum runs in an isolate so we don't block
  /// the UI for ~50ms on a 10 MB file before the upload card appears.
  Future<DocumentBytes> _validateAndWrap(
      Uint8List bytes, String name, String mime) async {
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
    final checksum = await ImageProcessor.checksum(bytes);
    return DocumentBytes(
      bytes: bytes,
      originalName: name,
      mimeType: mime,
      size: bytes.length,
      checksum: checksum,
    );
  }

  static String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
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

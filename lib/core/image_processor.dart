import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:image/image.dart' as img;

/// Heavy image work that would otherwise stall the UI thread.
///
/// All entry points here run inside `Isolate.run`, so a 10 MB photo can
/// be decoded, resized, and re-encoded without dropping frames during a
/// drag, an upload, or a navigation animation.
///
/// Why isolates here specifically:
///
///   - `decodeImage` on a multi-megapixel JPEG is dozens of milliseconds.
///   - `copyResize` for thumbnails is similar.
///   - FNV-1a checksum over 10 MB is ~50ms.
///
/// Together, doing these on the UI isolate during an upload would be a
/// frame-budget catastrophe. Splitting them out means the existing
/// optimistic-upload UX (card appears instantly, progress bar animates
/// smoothly) holds even on entry-level Android devices.
class ImageProcessor {
  ImageProcessor._();

  /// Decode [bytes] in an isolate, resize so the longest edge is at most
  /// [maxEdge] px, return JPEG-encoded thumbnail bytes. Returns `null` if
  /// the bytes don't decode as a recognised image format (e.g. PDF).
  static Future<Uint8List?> thumbnail(
    Uint8List bytes, {
    int maxEdge = 320,
    int quality = 80,
  }) {
    return Isolate.run(() => _thumbnailSync(bytes, maxEdge, quality));
  }

  /// Compute an FNV-1a 64-bit checksum over [bytes] in an isolate.
  /// Returns 16-character lowercase hex.
  static Future<String> checksum(Uint8List bytes) {
    return Isolate.run(() => _checksumSync(bytes));
  }

  /// Decoded image dimensions, computed off-thread. Returns `null` if
  /// the bytes don't decode as a recognised image format.
  static Future<Size?> imageSize(Uint8List bytes) {
    return Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return Size(decoded.width.toDouble(), decoded.height.toDouble());
    });
  }

  // -------------------------------------------------------------------------
  // Workers — these execute in the spawned isolate. They must not reach
  // for anything from the calling isolate's heap; arguments are copied
  // when sent.
  // -------------------------------------------------------------------------

  static Uint8List? _thumbnailSync(
    Uint8List bytes,
    int maxEdge,
    int quality,
  ) {
    final src = img.decodeImage(bytes);
    if (src == null) return null;
    final longest = src.width > src.height ? src.width : src.height;
    final image = longest <= maxEdge
        ? src
        : img.copyResize(
            src,
            width: src.width >= src.height ? maxEdge : null,
            height: src.height > src.width ? maxEdge : null,
            interpolation: img.Interpolation.average,
          );
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  static String _checksumSync(Uint8List bytes) {
    var h = 0xcbf29ce484222325; // FNV-1a 64-bit offset basis
    for (final b in bytes) {
      h = (h ^ b) & 0xFFFFFFFFFFFFFFFF;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }
}

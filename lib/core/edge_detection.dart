import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart document edge detector designed for live-preview frames.
///
/// The algorithm is intentionally simple so it runs at ~6 fps on a
/// mid-range Android phone inside an isolate without dropping camera
/// frames:
///
///   1. Downsample the luma plane to ~160×90 — we don't need detail,
///      we need dominant edges, and downsampling is a 100× speedup.
///   2. Compute a Sobel-ish horizontal + vertical gradient at each
///      pixel.
///   3. Sum |horizontal gradient| per column → "verticality strength"
///      profile. Sum |vertical gradient| per row → "horizontality"
///      profile.
///   4. Pick the two strongest peaks in each profile that are far
///      enough apart — those are the document's left/right and
///      top/bottom edges.
///   5. Return the bounding rectangle in **input-image** coordinates
///      together with a confidence score (0..1) based on how strong
///      the picked peaks are relative to the average.
///
/// We do NOT attempt to find a four-corner quadrilateral. The
/// rectangle is a reasonable approximation for documents held roughly
/// orthogonal to the camera, which is what the scanner UI guides the
/// user to do anyway. A perspective-corrected scan would warrant a
/// full Hough-line + corner fit, which is out of scope here.
class EdgeDetectionResult {
  const EdgeDetectionResult({
    required this.rectInImage,
    required this.confidence,
  });

  /// Rectangle of detected document edges in input-image coordinates.
  /// Caller scales to preview space.
  final ({int left, int top, int right, int bottom}) rectInImage;

  /// 0 = no detection, 1 = very confident.
  final double confidence;
}

class EdgeDetector {
  EdgeDetector._();

  /// Run a single detection pass. Sized for the frame copy to be sent
  /// across an isolate boundary cheaply (a couple of hundred KB).
  static Future<EdgeDetectionResult> detect({
    required Uint8List luma,
    required int srcWidth,
    required int srcHeight,
    required int rowStride,
    int targetWidth = 160,
  }) {
    return Isolate.run(() => _detectSync(
          luma: luma,
          srcWidth: srcWidth,
          srcHeight: srcHeight,
          rowStride: rowStride,
          targetWidth: targetWidth,
        ));
  }

  static EdgeDetectionResult _detectSync({
    required Uint8List luma,
    required int srcWidth,
    required int srcHeight,
    required int rowStride,
    required int targetWidth,
  }) {
    if (srcWidth <= 0 || srcHeight <= 0) {
      return EdgeDetectionResult(
        rectInImage: (left: 0, top: 0, right: srcWidth, bottom: srcHeight),
        confidence: 0,
      );
    }
    final scale = srcWidth / targetWidth;
    final tw = targetWidth;
    final th = (srcHeight / scale).round();

    // 1. Downsample (nearest-neighbour from luma plane).
    final small = Uint8List(tw * th);
    for (var y = 0; y < th; y++) {
      final srcY = (y * scale).round().clamp(0, srcHeight - 1);
      for (var x = 0; x < tw; x++) {
        final srcX = (x * scale).round().clamp(0, srcWidth - 1);
        small[y * tw + x] = luma[srcY * rowStride + srcX];
      }
    }

    // 2. Sobel gradients.
    final gx = Uint16List(tw * th);
    final gy = Uint16List(tw * th);
    for (var y = 1; y < th - 1; y++) {
      for (var x = 1; x < tw - 1; x++) {
        final a = small[(y - 1) * tw + (x - 1)];
        final b = small[(y - 1) * tw + x];
        final c = small[(y - 1) * tw + (x + 1)];
        final d = small[y * tw + (x - 1)];
        final f = small[y * tw + (x + 1)];
        final g = small[(y + 1) * tw + (x - 1)];
        final h = small[(y + 1) * tw + x];
        final i = small[(y + 1) * tw + (x + 1)];
        final sx = (-a - 2 * d - g + c + 2 * f + i).abs();
        final sy = (-a - 2 * b - c + g + 2 * h + i).abs();
        gx[y * tw + x] = sx;
        gy[y * tw + x] = sy;
      }
    }

    // 3. Sum gradients into row + column profiles.
    final colProfile = Uint32List(tw);
    final rowProfile = Uint32List(th);
    for (var y = 0; y < th; y++) {
      for (var x = 0; x < tw; x++) {
        colProfile[x] += gx[y * tw + x];
        rowProfile[y] += gy[y * tw + x];
      }
    }

    // 4. Pick two strong, well-separated peaks per profile.
    final hLeft = _pickPair(
      profile: colProfile,
      minSeparation: (tw * 0.3).round(),
    );
    final vTop = _pickPair(
      profile: rowProfile,
      minSeparation: (th * 0.3).round(),
    );

    if (hLeft == null || vTop == null) {
      return EdgeDetectionResult(
        rectInImage: (left: 0, top: 0, right: srcWidth, bottom: srcHeight),
        confidence: 0,
      );
    }

    // 5. Confidence: peak strength relative to baseline.
    final colAvg = _avg(colProfile);
    final rowAvg = _avg(rowProfile);
    final colPeak = math.max(hLeft.first, hLeft.second).toDouble();
    final rowPeak = math.max(vTop.first, vTop.second).toDouble();
    final confidence = ((colPeak / (colAvg * 3)) + (rowPeak / (rowAvg * 3)))
        .clamp(0.0, 2.0) / 2.0;

    final left = (hLeft.indexA * scale).round();
    final right = (hLeft.indexB * scale).round();
    final top = (vTop.indexA * scale).round();
    final bottom = (vTop.indexB * scale).round();

    return EdgeDetectionResult(
      rectInImage: (
        left: math.min(left, right),
        top: math.min(top, bottom),
        right: math.max(left, right),
        bottom: math.max(top, bottom),
      ),
      confidence: confidence,
    );
  }

  static double _avg(List<int> profile) {
    var s = 0;
    for (final v in profile) {
      s += v;
    }
    return profile.isEmpty ? 0 : s / profile.length;
  }

  /// Two strongest peaks in [profile] that are at least [minSeparation]
  /// apart. Returns indices and magnitudes, or null if no good pair.
  static _Pair? _pickPair({
    required List<int> profile,
    required int minSeparation,
  }) {
    if (profile.length < 4) return null;
    var bestA = 0, bestAVal = 0;
    for (var i = 0; i < profile.length; i++) {
      if (profile[i] > bestAVal) {
        bestAVal = profile[i];
        bestA = i;
      }
    }
    var bestB = -1, bestBVal = 0;
    for (var i = 0; i < profile.length; i++) {
      if ((i - bestA).abs() < minSeparation) continue;
      if (profile[i] > bestBVal) {
        bestBVal = profile[i];
        bestB = i;
      }
    }
    if (bestB < 0) return null;
    return _Pair(
      indexA: bestA,
      indexB: bestB,
      first: bestAVal,
      second: bestBVal,
    );
  }
}

class _Pair {
  _Pair({
    required this.indexA,
    required this.indexB,
    required this.first,
    required this.second,
  });
  final int indexA;
  final int indexB;
  final int first;
  final int second;
}

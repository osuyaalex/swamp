import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

import 'package:untitled2/core/image_processor.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';

/// Optical character recognition for uploaded documents.
///
/// Runs Google ML Kit's on-device text recogniser (no cloud, no per-call
/// fees, works offline). The Flutter plugin schedules its own native
/// thread for the actual ML inference, so we don't need to wrap *that*
/// in an isolate. What we DO put in an isolate is the post-processing —
/// regex-based field extraction that walks every recognised line — so
/// long documents don't stall the UI when their results come back.
///
/// Why on-device ML Kit specifically:
///
///   - **Privacy & compliance.** KYC images shouldn't leave the device
///     for a cloud OCR pass. Cloud Vision, AWS Textract, Azure Cognitive
///     Services all require shipping the image off-device.
///   - **Cost.** ML Kit Text Recognition is free regardless of volume.
///   - **Latency.** No round-trip to a server during the upload flow.
///
/// Trade-off: ML Kit is Latin-script-first. For Arabic or Devanagari
/// documents we'd swap in a different recogniser per locale; the
/// `OcrService` interface keeps that swap local to this file.
abstract class OcrService {
  Future<OcrResult?> process({
    required Uint8List bytes,
    required String mimeType,
  });

  Future<void> dispose();
}

/// Production implementation backed by ML Kit Text Recognition.
class MLKitOcrService implements OcrService {
  MLKitOcrService() : _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;

  @override
  Future<OcrResult?> process({
    required Uint8List bytes,
    required String mimeType,
  }) async {
    // PDFs aren't accepted by the ML Kit text recogniser — it expects a
    // raster image. We could rasterise PDFs first, but for the assessment
    // scope we skip OCR for them entirely.
    if (mimeType == 'application/pdf') return null;
    if (kIsWeb) return null; // ML Kit isn't supported on web
    if (!Platform.isAndroid && !Platform.isIOS) return null;

    // ML Kit's `InputImage.fromBytes` requires the image format and
    // dimensions, which is fragile across phone cameras. The reliable
    // path is to write to a tmp file and use `InputImage.fromFilePath` —
    // that defers the decoding to ML Kit which handles every JPEG/PNG
    // permutation.
    final tmpDir = await path_provider.getTemporaryDirectory();
    final ext = mimeType == 'image/png' ? 'png' : 'jpg';
    final tmpFile = File(
      '${tmpDir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.$ext',
    );
    await tmpFile.writeAsBytes(bytes);

    try {
      final input = InputImage.fromFilePath(tmpFile.path);
      final recognized = await _recognizer.processImage(input);

      // ML Kit returns its own DTOs. Convert to our domain types so the
      // rest of the app doesn't depend on the plugin.
      // ML Kit's `boundingBox` is `dart:ui.Rect` already — pass through.
      final blocks = <OcrTextBlock>[];
      for (final block in recognized.blocks) {
        blocks.add(OcrTextBlock(
          text: block.text,
          boundingBox: block.boundingBox,
          lines: [
            for (final line in block.lines)
              OcrTextLine(
                text: line.text,
                boundingBox: line.boundingBox,
              ),
          ],
        ));
      }

      // Image size is needed by the render-object overlay so it can map
      // pixel-space bounding boxes onto rendered space. Compute off-thread.
      final size = await ImageProcessor.imageSize(bytes);

      // Field extraction (Surname/Given/DOB/etc) runs in an isolate so
      // even a 200-line document doesn't stall the UI on regex work.
      final fields = await Isolate.run(
        () => OcrFieldExtractor.extract(recognized.text),
      );

      return OcrResult(
        fullText: recognized.text,
        blocks: blocks,
        imageSize: size ?? const ui.Size(0, 0),
        processedAt: DateTime.now(),
        fields: fields,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[ocr] processing failed: $e\n$st');
      }
      return null;
    } finally {
      // Tmp files don't auto-clean on Android until the OS is short on
      // space. Best-effort cleanup keeps the cache directory tidy.
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() => _recognizer.close();
}

/// Stateless heuristic field extractor. Pure Dart — runs anywhere,
/// including inside an isolate. KYC documents follow predictable
/// patterns; this matches the most common ones.
class OcrFieldExtractor {
  static Map<String, String> extract(String fullText) {
    final fields = <String, String>{};

    // Most ID-like documents have label-prefixed lines. The labels vary
    // by country but a small set covers EU/US/MRZ-style passports.
    final patterns = <String, RegExp>{
      'surname': RegExp(
        r'(?:surname|family\s+name|nom)[:\s]+([A-Z][A-Z\-\s]{1,40})',
        caseSensitive: false,
      ),
      'givenNames': RegExp(
        r'(?:given\s+names?|first\s+names?|prenoms?)[:\s]+([A-Z][A-Z\-\s]{1,40})',
        caseSensitive: false,
      ),
      'dateOfBirth': RegExp(
        r'(?:date\s+of\s+birth|d\.?o\.?b\.?|n[ée]\(?e?\)?\s+le)[:\s]+'
        r'(\d{1,2}[\s./-][A-Za-z0-9]{1,9}[\s./-]\d{2,4})',
        caseSensitive: false,
      ),
      'documentNumber': RegExp(
        r'(?:document\s+no|passport\s+no|n[°o]?)[\.:\s]+([A-Z0-9]{5,12})',
        caseSensitive: false,
      ),
      'expiry': RegExp(
        r'(?:date\s+of\s+expir(?:y|ation)|exp(?:iry)?(?:\s+date)?)[:\s]+'
        r'(\d{1,2}[\s./-][A-Za-z0-9]{1,9}[\s./-]\d{2,4})',
        caseSensitive: false,
      ),
    };

    for (final entry in patterns.entries) {
      final match = entry.value.firstMatch(fullText);
      if (match != null && match.group(1) != null) {
        fields[entry.key] = match.group(1)!.trim();
      }
    }
    return fields;
  }
}

/// Test fake — returns a canned result, useful in unit tests so we don't
/// need to spin up ML Kit.
class FakeOcrService implements OcrService {
  FakeOcrService(this._canned);
  final OcrResult? _canned;

  @override
  Future<OcrResult?> process({
    required Uint8List bytes,
    required String mimeType,
  }) async =>
      _canned;

  @override
  Future<void> dispose() async {}
}

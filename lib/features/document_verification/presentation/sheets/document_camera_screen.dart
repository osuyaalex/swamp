import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/core/edge_detection.dart';
import 'package:untitled2/core/image_processor.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_controller.dart';

/// Custom camera screen with real-time document edge detection.
///
/// Replaces the stock image-picker camera path for users who want a
/// scanner-style experience with on-device feedback. The camera preview
/// fills the screen; image-stream frames are sampled at ~6 fps and a
/// pure-Dart edge detector (running in an isolate) finds the document's
/// bounding rectangle. Animated corner brackets track the detected
/// rectangle in real time, and a confidence pill at the top tells the
/// user whether to hold steadier or move closer.
///
/// On capture, the full-resolution still is read into memory, the
/// checksum is computed off-thread, and the result is handed to the
/// controller's `uploadBytes` so the rest of the upload pipeline
/// (optimistic insert → API → WS status updates → audit trail) runs
/// unchanged.
class DocumentCameraScreen extends StatefulWidget {
  const DocumentCameraScreen({super.key, required this.documentType});

  final DocumentType documentType;

  /// Returns the captured `Document` (post-upload) or null if the user
  /// backed out without capturing. The dashboard controller is captured
  /// from the calling context and re-provided into the route — same
  /// trick as the modal sheets, since the new route is pushed under
  /// the root Navigator and doesn't inherit the dashboard's provider.
  static Future<Document?> open(
    BuildContext context, {
    required DocumentType documentType,
  }) {
    final controller = context.read<DocumentDashboardController>();
    return Navigator.of(context).push<Document>(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider<DocumentDashboardController>.value(
          value: controller,
          child: DocumentCameraScreen(documentType: documentType),
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<DocumentCameraScreen> createState() => _DocumentCameraScreenState();
}

class _DocumentCameraScreenState extends State<DocumentCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _camera;
  bool _processing = false;
  bool _capturing = false;
  int _frameCounter = 0;
  static const _frameSkip = 4; // process 1 in every 4 frames (~6 fps @ 30 fps cam)

  // Latest detection — drives the overlay paint.
  EdgeDetectionResult _latest = const EdgeDetectionResult(
    rectInImage: (left: 0, top: 0, right: 0, bottom: 0),
    confidence: 0,
  );
  Size? _lastFrameSize; // image-coordinate space of `_latest.rectInImage`

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupCamera();
  }

  Future<void> _setupCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('no_cameras', 'No cameras on this device');
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      await controller.startImageStream(_onFrame);
      setState(() {});
    } catch (e) {
      if (kDebugMode) debugPrint('[camera] setup failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed) {
      _setupCamera();
    }
  }

  void _onFrame(CameraImage img) {
    if (!mounted || _processing) return;
    _frameCounter++;
    if (_frameCounter % _frameSkip != 0) return;
    _processing = true;
    _processFrame(img).whenComplete(() => _processing = false);
  }

  Future<void> _processFrame(CameraImage img) async {
    if (img.planes.isEmpty) return;

    // For YUV420 the Y plane is grayscale luma; for BGRA8888 we use
    // the green channel as a luma proxy (cheap and good enough for
    // edge detection).
    final plane = img.planes[0];
    final luma = Uint8List.fromList(plane.bytes); // copy for isolate
    final rowStride = plane.bytesPerRow;
    final w = img.width;
    final h = img.height;

    final result = await EdgeDetector.detect(
      luma: luma,
      srcWidth: w,
      srcHeight: h,
      rowStride: rowStride,
    );

    if (!mounted) return;
    setState(() {
      _latest = result;
      _lastFrameSize = Size(w.toDouble(), h.toDouble());
    });
  }

  Future<void> _capture() async {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) return;
    if (_capturing) return;
    setState(() => _capturing = true);

    try {
      // The image stream must be stopped before takePicture works on
      // some Android devices.
      await controller.stopImageStream();
      final shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      final mimeType = shot.path.toLowerCase().endsWith('.png')
          ? 'image/png'
          : 'image/jpeg';
      final checksum = await ImageProcessor.checksum(bytes);
      final docBytes = DocumentBytes(
        bytes: bytes,
        originalName: 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg',
        mimeType: mimeType,
        size: bytes.length,
        checksum: checksum,
      );

      if (!mounted) return;
      final dashboard = context.read<DocumentDashboardController>();
      final result = await dashboard.uploadBytes(
        type: widget.documentType,
        bytes: docBytes,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (kDebugMode) debugPrint('[camera] capture failed: $e');
      if (mounted) {
        setState(() => _capturing = false);
        // Best-effort restart of stream so the user can retry.
        try {
          await controller.startImageStream(_onFrame);
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller == null || !controller.value.isInitialized)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              )
            else ...[
              Positioned.fill(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: CameraPreview(controller),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _DocumentScannerOverlay(
                    detection: _latest,
                    frameSize: _lastFrameSize,
                  ),
                ),
              ),
              // Top status pill
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: _ConfidencePill(
                    confidence: _latest.confidence,
                  ),
                ),
              ),
              // Close button
              Positioned(
                top: 8,
                left: 4,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              // Capture button
              Positioned(
                bottom: 36,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _capturing ? null : _capture,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _capturing
                            ? theme.colorScheme.primary
                            : Colors.white,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.7),
                          width: 4,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: _capturing
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 3,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
              // Bottom hint
              Positioned(
                bottom: 110,
                left: 24,
                right: 24,
                child: Center(
                  child: Text(
                    _latest.confidence > 0.55
                        ? 'Hold steady — capture when ready'
                        : 'Align the document inside the frame',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      shadows: [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConfidencePill extends StatelessWidget {
  const _ConfidencePill({required this.confidence});

  final double confidence;

  @override
  Widget build(BuildContext context) {
    final c = confidence > 0.55
        ? const Color(0xFF4CAF50)
        : confidence > 0.25
            ? const Color(0xFFFFA000)
            : Colors.white;
    final label = confidence > 0.55
        ? 'Document detected'
        : confidence > 0.25
            ? 'Looking…'
            : 'No document detected';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _DocumentScannerOverlay extends CustomPainter {
  _DocumentScannerOverlay({required this.detection, required this.frameSize});

  final EdgeDetectionResult detection;
  final Size? frameSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameSize == null || detection.confidence < 0.05) {
      _drawIdleBrackets(canvas, size);
      return;
    }
    // Map detection rect from frame coordinates to canvas coordinates.
    final fs = frameSize!;
    final scaleX = size.width / fs.width;
    final scaleY = size.height / fs.height;
    final rect = Rect.fromLTRB(
      detection.rectInImage.left * scaleX,
      detection.rectInImage.top * scaleY,
      detection.rectInImage.right * scaleX,
      detection.rectInImage.bottom * scaleY,
    );

    final color = detection.confidence > 0.55
        ? const Color(0xFF4CAF50)
        : const Color(0xFFFFA000);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    _drawCornerBrackets(canvas, rect, paint);
  }

  void _drawIdleBrackets(Canvas canvas, Size size) {
    final inset = 36.0;
    final rect = Rect.fromLTWH(
      inset,
      inset + 60,
      size.width - inset * 2,
      size.height - inset * 2 - 180,
    );
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    _drawCornerBrackets(canvas, rect, paint);
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, Paint paint) {
    const armLen = 28.0;
    // Top-left
    canvas.drawLine(
        rect.topLeft, rect.topLeft + const Offset(armLen, 0), paint);
    canvas.drawLine(
        rect.topLeft, rect.topLeft + const Offset(0, armLen), paint);
    // Top-right
    canvas.drawLine(
        rect.topRight, rect.topRight + const Offset(-armLen, 0), paint);
    canvas.drawLine(
        rect.topRight, rect.topRight + const Offset(0, armLen), paint);
    // Bottom-left
    canvas.drawLine(rect.bottomLeft,
        rect.bottomLeft + const Offset(armLen, 0), paint);
    canvas.drawLine(rect.bottomLeft,
        rect.bottomLeft + const Offset(0, -armLen), paint);
    // Bottom-right
    canvas.drawLine(rect.bottomRight,
        rect.bottomRight + const Offset(-armLen, 0), paint);
    canvas.drawLine(rect.bottomRight,
        rect.bottomRight + const Offset(0, -armLen), paint);
  }

  @override
  bool shouldRepaint(covariant _DocumentScannerOverlay old) =>
      old.detection.confidence != detection.confidence ||
      old.detection.rectInImage != detection.rectInImage ||
      old.frameSize != frameSize;
}

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';

// =====================================================================
// DocumentPreview — a custom render object for the verified-document
// preview screen.
//
// Why a render object instead of widgets + CustomPainter?
//
// The preview has three jobs that don't compose cleanly out of stock
// widgets:
//
//   1. **Aspect-correct fit** of an arbitrary-sized decoded image into
//      a constrained box, keeping a single source of truth for the
//      drawn image rect that hit-testing can reuse.
//
//   2. **OCR overlay rendering** — every recognised text block from
//      ML Kit gets a semi-transparent box drawn over it. We need the
//      drawn rectangle's coordinates available for hit-testing too.
//
//   3. **Block-aware hit-testing** — a tap on a recognised text block
//      should report which block was tapped. `GestureDetector` with
//      a child `CustomPaint` would lose the block boundaries because
//      gesture detectors hit-test the box, not the painted region.
//
// All three want to share one coordinate system and one source of
// truth for the drawn rect. That's a render object's job. Pan/zoom is
// handled internally via `ScaleGestureRecognizer`, so the widget tree
// above this stays a single line.
// =====================================================================

/// Public widget. Renders an image + OCR overlays with built-in
/// pinch-zoom and pan, and reports taps on individual recognised text
/// blocks.
class DocumentPreview extends StatefulWidget {
  const DocumentPreview({
    super.key,
    required this.imageBytes,
    this.ocrResult,
    this.onBlockTap,
    this.highlightedBlockText,
  });

  /// JPEG/PNG bytes for the document image. Decoded once on first build.
  final Uint8List imageBytes;

  /// Optional OCR data. When present, recognised text blocks are drawn
  /// as semi-transparent overlays.
  final OcrResult? ocrResult;

  /// Fired when the user taps on a recognised block. Useful for "tap to
  /// copy" or "tap to highlight" interactions.
  final void Function(OcrTextBlock block)? onBlockTap;

  /// If non-null, the matching block is rendered with a stronger fill
  /// to emphasise it (e.g. while it's been copied or selected).
  final String? highlightedBlockText;

  @override
  State<DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<DocumentPreview> {
  ui.Image? _decoded;
  Object? _decodeError;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant DocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageBytes != widget.imageBytes) {
      _decoded?.dispose();
      _decoded = null;
      _decode();
    }
  }

  @override
  void dispose() {
    _decoded?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _decoded = frame.image);
    } catch (e) {
      if (mounted) setState(() => _decodeError = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_decodeError != null) {
      return Center(
        child: Text(
          'Could not decode image: $_decodeError',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final decoded = _decoded;
    if (decoded == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _DocumentPreviewLeaf(
      image: decoded,
      blocks: widget.ocrResult?.blocks ?? const [],
      imageSize: Size(
        decoded.width.toDouble(),
        decoded.height.toDouble(),
      ),
      onBlockTap: widget.onBlockTap,
      highlightedBlockText: widget.highlightedBlockText,
    );
  }
}

// ---------------------------------------------------------------------
// Leaf render-object widget — the bridge between the framework and the
// hand-rolled RenderBox below.
// ---------------------------------------------------------------------

class _DocumentPreviewLeaf extends LeafRenderObjectWidget {
  const _DocumentPreviewLeaf({
    required this.image,
    required this.blocks,
    required this.imageSize,
    required this.onBlockTap,
    required this.highlightedBlockText,
  });

  final ui.Image image;
  final List<OcrTextBlock> blocks;
  final Size imageSize;
  final void Function(OcrTextBlock block)? onBlockTap;
  final String? highlightedBlockText;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderDocumentPreview(
      image: image,
      blocks: blocks,
      imageSize: imageSize,
      onBlockTap: onBlockTap,
      highlightedBlockText: highlightedBlockText,
      overlayColor: Theme.of(context).colorScheme.primary,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDocumentPreview renderObject,
  ) {
    renderObject
      ..image = image
      ..blocks = blocks
      ..imageSize = imageSize
      ..onBlockTap = onBlockTap
      ..highlightedBlockText = highlightedBlockText
      ..overlayColor = Theme.of(context).colorScheme.primary;
  }
}

// ---------------------------------------------------------------------
// The render object proper.
//
// Owns:
//   - the decoded image and OCR data
//   - the pan offset and zoom scale (gesture-driven local state)
//   - the recognisers (`ScaleGestureRecognizer` for pinch-zoom + pan,
//     `TapGestureRecognizer` for block-aware taps)
//
// Performs:
//   - layout (snap to constraints, no children)
//   - paint (image scaled into a contain-fit rect, then OCR overlays)
//   - hit-testing (always claims the tap, then dispatches via the
//     recognisers that this object owns)
// ---------------------------------------------------------------------

class _RenderDocumentPreview extends RenderBox {
  _RenderDocumentPreview({
    required ui.Image image,
    required List<OcrTextBlock> blocks,
    required Size imageSize,
    required void Function(OcrTextBlock block)? onBlockTap,
    required String? highlightedBlockText,
    required Color overlayColor,
  })  : _image = image,
        _blocks = blocks,
        _imageSize = imageSize,
        _onBlockTap = onBlockTap,
        _highlightedBlockText = highlightedBlockText,
        _overlayColor = overlayColor {
    _scaleRecognizer = ScaleGestureRecognizer(debugOwner: this)
      ..onStart = _onScaleStart
      ..onUpdate = _onScaleUpdate;
    _tapRecognizer = TapGestureRecognizer(debugOwner: this)
      ..onTapUp = _onTapUp;
  }

  ui.Image _image;
  ui.Image get image => _image;
  set image(ui.Image v) {
    if (identical(_image, v)) return;
    _image = v;
    markNeedsPaint();
  }

  List<OcrTextBlock> _blocks;
  List<OcrTextBlock> get blocks => _blocks;
  set blocks(List<OcrTextBlock> v) {
    if (listEquals(_blocks, v)) return;
    _blocks = v;
    markNeedsPaint();
  }

  Size _imageSize;
  Size get imageSize => _imageSize;
  set imageSize(Size v) {
    if (_imageSize == v) return;
    _imageSize = v;
    markNeedsPaint();
  }

  void Function(OcrTextBlock block)? _onBlockTap;
  set onBlockTap(void Function(OcrTextBlock block)? v) => _onBlockTap = v;

  String? _highlightedBlockText;
  set highlightedBlockText(String? v) {
    if (_highlightedBlockText == v) return;
    _highlightedBlockText = v;
    markNeedsPaint();
  }

  Color _overlayColor;
  set overlayColor(Color v) {
    if (_overlayColor == v) return;
    _overlayColor = v;
    markNeedsPaint();
  }

  // Gesture state ----------------------------------------------------------
  late final ScaleGestureRecognizer _scaleRecognizer;
  late final TapGestureRecognizer _tapRecognizer;
  Offset _pan = Offset.zero;
  double _zoom = 1.0;
  Offset _panAtScaleStart = Offset.zero;
  double _zoomAtScaleStart = 1.0;
  Offset _focalAtScaleStart = Offset.zero;

  void _onScaleStart(ScaleStartDetails details) {
    _panAtScaleStart = _pan;
    _zoomAtScaleStart = _zoom;
    _focalAtScaleStart = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final newZoom = (_zoomAtScaleStart * details.scale).clamp(1.0, 4.0);
    // Pan: keep the focal point under the user's finger while zooming.
    final translation = details.localFocalPoint - _focalAtScaleStart;
    _zoom = newZoom;
    _pan = _panAtScaleStart + translation;
    _clampPan();
    markNeedsPaint();
  }

  void _onTapUp(TapUpDetails details) {
    final cb = _onBlockTap;
    if (cb == null) return;
    final block = _blockAt(details.localPosition);
    if (block != null) cb(block);
  }

  // Layout -----------------------------------------------------------------

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _scaleRecognizer.addPointer(event);
      _tapRecognizer.addPointer(event);
    }
  }

  // Paint ------------------------------------------------------------------

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.clipRect(Offset.zero & size);

    // Compute the fit-rect — image scaled to fit `size` preserving
    // aspect ratio. This is the base rect; pan/zoom transform is applied
    // on top.
    final fit = _fitRect(_imageSize, size);
    final transformed = _applyPanZoom(fit);

    // Draw image.
    canvas.drawImageRect(
      _image,
      Rect.fromLTWH(0, 0, _imageSize.width, _imageSize.height),
      transformed,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Draw OCR block overlays.
    if (_blocks.isNotEmpty) {
      final base = _overlayColor;
      final fill = Paint()
        ..color = base.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill;
      final stroke = Paint()
        ..color = base.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      final highlightFill = Paint()
        ..color = base.withValues(alpha: 0.45)
        ..style = PaintingStyle.fill;

      for (final block in _blocks) {
        final rect = _imageRectToCanvasRect(block.boundingBox, transformed);
        final isHighlighted = _highlightedBlockText != null &&
            block.text.contains(_highlightedBlockText!);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          isHighlighted ? highlightFill : fill,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          stroke,
        );
      }
    }
    canvas.restore();
  }

  // Geometry helpers -------------------------------------------------------

  /// Largest rect of [imageSize]'s aspect ratio that fits inside [box],
  /// centred.
  Rect _fitRect(Size imageSize, Size box) {
    if (imageSize.width <= 0 || imageSize.height <= 0) {
      return Offset.zero & box;
    }
    final imgAspect = imageSize.width / imageSize.height;
    final boxAspect = box.width / box.height;
    double w, h;
    if (imgAspect > boxAspect) {
      w = box.width;
      h = w / imgAspect;
    } else {
      h = box.height;
      w = h * imgAspect;
    }
    return Rect.fromLTWH(
      (box.width - w) / 2,
      (box.height - h) / 2,
      w,
      h,
    );
  }

  /// Apply the current zoom + pan to the base fit rect. Returns the
  /// rect the image is actually painted into.
  Rect _applyPanZoom(Rect base) {
    final zoomedW = base.width * _zoom;
    final zoomedH = base.height * _zoom;
    return Rect.fromLTWH(
      base.left - (zoomedW - base.width) / 2 + _pan.dx,
      base.top - (zoomedH - base.height) / 2 + _pan.dy,
      zoomedW,
      zoomedH,
    );
  }

  /// Map a bounding box from image-pixel coordinates into the
  /// transformed canvas rect.
  Rect _imageRectToCanvasRect(Rect imgRect, Rect canvasRect) {
    if (_imageSize.width == 0 || _imageSize.height == 0) return canvasRect;
    final sx = canvasRect.width / _imageSize.width;
    final sy = canvasRect.height / _imageSize.height;
    return Rect.fromLTRB(
      canvasRect.left + imgRect.left * sx,
      canvasRect.top + imgRect.top * sy,
      canvasRect.left + imgRect.right * sx,
      canvasRect.top + imgRect.bottom * sy,
    );
  }

  /// Hit-test for OCR blocks. Walks them in reverse paint order so the
  /// top-most overlapping block wins.
  OcrTextBlock? _blockAt(Offset localPosition) {
    if (_blocks.isEmpty) return null;
    final fit = _applyPanZoom(_fitRect(_imageSize, size));
    for (var i = _blocks.length - 1; i >= 0; i--) {
      final block = _blocks[i];
      final rect = _imageRectToCanvasRect(block.boundingBox, fit);
      if (rect.contains(localPosition)) return block;
    }
    return null;
  }

  /// Keep the panned/zoomed image's rect overlapping the box at its
  /// current zoom — prevents the user from flinging the image entirely
  /// out of view.
  void _clampPan() {
    final fit = _fitRect(_imageSize, size);
    final maxPanX = ((fit.width * _zoom) - size.width).clamp(0.0, double.infinity) / 2;
    final maxPanY = ((fit.height * _zoom) - size.height).clamp(0.0, double.infinity) / 2;
    _pan = Offset(
      _pan.dx.clamp(-maxPanX, maxPanX),
      _pan.dy.clamp(-maxPanY, maxPanY),
    );
  }

  // Lifecycle --------------------------------------------------------------

  @override
  void dispose() {
    _scaleRecognizer.dispose();
    _tapRecognizer.dispose();
    super.dispose();
  }
}

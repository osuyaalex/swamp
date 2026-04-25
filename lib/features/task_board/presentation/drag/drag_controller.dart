import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:untitled2/core/haptics.dart';
import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/presentation/task_board_controller.dart';

enum DragPhase { idle, dragging, dropping, cancelling }

/// Per-column metadata the drag controller needs for hit-testing and
/// auto-scroll. Columns register themselves on first build.
class ColumnDragRegistration {
  ColumnDragRegistration({
    required this.status,
    required this.listAreaKey,
    required this.scroll,
    required this.snapshot,
  });

  final TaskStatus status;
  final GlobalKey listAreaKey;
  final ScrollController scroll;
  final List<Task> Function() snapshot;
}

/// Drives custom drag-and-drop end-to-end.
///
/// Why custom (vs. `Draggable`/`DragTarget`)?
///  • Need a single ghost in an Overlay-style layer with shadow + tilt.
///  • Auto-scroll columns *and* the board horizontally as the finger nears
///    edges — `Draggable` won't drive arbitrary `ScrollController`s.
///  • Insertion index must be computed against live card rects, not just
///    target acceptance — gives us the slot-shift preview animation.
///  • Need to reject simultaneous secondary drags and animate cancellations
///    cleanly back to source on pointer-cancel.
class DragController extends ChangeNotifier {
  DragController({required this.boardController, required TickerProvider vsync})
      : _vsync = vsync {
    _autoScrollTicker = _vsync.createTicker(_onAutoScrollTick)..start();
  }

  final TaskBoardController boardController;
  final TickerProvider _vsync;
  late final Ticker _autoScrollTicker;

  // Public read-only state ----------------------------------------------------

  DragPhase _phase = DragPhase.idle;
  DragPhase get phase => _phase;

  Task? _task;
  Task? get task => _task;
  String? get activeTaskId => _task?.id;

  Offset _pointerGlobal = Offset.zero;
  Offset get pointerGlobal => _pointerGlobal;

  Offset _grabOffset = Offset.zero;
  Offset get grabOffset => _grabOffset;

  Size _cardSize = Size.zero;
  Size get cardSize => _cardSize;

  // Animated ghost top-left, in global coords. Used by the overlay.
  Offset _ghostTopLeft = Offset.zero;
  Offset get ghostTopLeft => _ghostTopLeft;

  TaskStatus? _hoverStatus;
  TaskStatus? get hoverStatus => _hoverStatus;

  int _hoverIndex = 0;
  int get hoverIndex => _hoverIndex;

  // Registry ------------------------------------------------------------------

  final Map<TaskStatus, ColumnDragRegistration> _columns = {};
  ScrollController? _boardScroll;

  void registerColumn(ColumnDragRegistration reg) {
    _columns[reg.status] = reg;
  }

  void unregisterColumn(TaskStatus status) {
    _columns.remove(status);
  }

  void registerBoardScroll(ScrollController controller) {
    _boardScroll = controller;
  }

  // Lifecycle -----------------------------------------------------------------

  bool get _busy =>
      _phase == DragPhase.dropping || _phase == DragPhase.cancelling;

  void start({
    required Task task,
    required Offset pointerGlobal,
    required Offset cardTopLeftGlobal,
    required Size cardSize,
  }) {
    if (_busy) return; // ignore secondary grabs while a drop/cancel animates
    _phase = DragPhase.dragging;
    _task = task;
    _pointerGlobal = pointerGlobal;
    _grabOffset = pointerGlobal - cardTopLeftGlobal;
    _cardSize = cardSize;
    _ghostTopLeft = cardTopLeftGlobal;
    _hoverStatus = task.status;
    _resolveInsertion();
    Haptics.dragStart();
    notifyListeners();
  }

  void updatePointer(Offset global) {
    if (_phase != DragPhase.dragging) return;
    _pointerGlobal = global;
    _ghostTopLeft = global - _grabOffset;
    final prevStatus = _hoverStatus;
    final prevIndex = _hoverIndex;
    _resolveInsertion();
    if (_hoverStatus != prevStatus || _hoverIndex != prevIndex) {
      Haptics.dragHover();
    }
    notifyListeners();
  }

  Future<void> drop() async {
    if (_phase != DragPhase.dragging) return;
    final task = _task;
    final destStatus = _hoverStatus;
    final destIndex = _hoverIndex;
    if (task == null || destStatus == null) {
      await cancel();
      return;
    }

    _phase = DragPhase.dropping;
    notifyListeners();

    // Commit to model first so the destination card's slot exists in layout
    // — we then animate the ghost into that slot's measured rect.
    await boardController.moveTask(
      taskId: task.id,
      toStatus: destStatus,
      toIndex: destIndex,
    );

    // After the frame settles, look up the new card rect and animate to it.
    await SchedulerBinding.instance.endOfFrame;

    final settled = _rectForTaskId(task.id) ?? Rect.fromLTWH(
      _ghostTopLeft.dx,
      _ghostTopLeft.dy,
      _cardSize.width,
      _cardSize.height,
    );

    await _animateGhostTo(settled.topLeft);
    Haptics.dragDrop();
    _reset();
  }

  Future<void> cancel() async {
    if (_phase == DragPhase.idle) return;
    _phase = DragPhase.cancelling;
    notifyListeners();

    final source = _task == null ? null : _rectForTaskId(_task!.id);
    if (source != null) {
      await _animateGhostTo(source.topLeft);
    }
    Haptics.dragCancel();
    _reset();
  }

  Future<void> _animateGhostTo(Offset target) async {
    final from = _ghostTopLeft;
    final ctrl = AnimationController(
      vsync: _vsync,
      duration: const Duration(milliseconds: 180),
    );
    final curve = CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic);
    void tick() {
      _ghostTopLeft = Offset.lerp(from, target, curve.value)!;
      notifyListeners();
    }
    curve.addListener(tick);
    try {
      await ctrl.forward();
    } finally {
      curve.removeListener(tick);
      ctrl.dispose();
    }
  }

  void _reset() {
    _phase = DragPhase.idle;
    _task = null;
    _pointerGlobal = Offset.zero;
    _grabOffset = Offset.zero;
    _cardSize = Size.zero;
    _hoverStatus = null;
    _hoverIndex = 0;
    notifyListeners();
  }

  // Hit-testing ---------------------------------------------------------------

  void _resolveInsertion() {
    final col = _columnAt(_pointerGlobal);
    if (col == null) {
      // Pointer is outside any column; keep last hover so a slight wobble
      // doesn't bounce the placeholder around.
      return;
    }
    _hoverStatus = col.status;
    _hoverIndex = _insertionIndex(col, _pointerGlobal);
  }

  ColumnDragRegistration? _columnAt(Offset global) {
    for (final c in _columns.values) {
      final ctx = c.listAreaKey.currentContext;
      if (ctx == null) continue;
      final rb = ctx.findRenderObject();
      if (rb is! RenderBox || !rb.attached) continue;
      final origin = rb.localToGlobal(Offset.zero);
      final rect = origin & rb.size;
      if (rect.contains(global)) return c;
    }
    return null;
  }

  int _insertionIndex(ColumnDragRegistration col, Offset global) {
    final tasks = col.snapshot();
    final draggedId = _task?.id;
    int rank = 0;
    for (final task in tasks) {
      if (task.id == draggedId) continue; // ignore the placeholder slot
      final ctx = GlobalObjectKey(task.id).currentContext;
      if (ctx == null) {
        rank++;
        continue;
      }
      final rb = ctx.findRenderObject();
      if (rb is! RenderBox || !rb.attached) {
        rank++;
        continue;
      }
      final cardOrigin = rb.localToGlobal(Offset.zero);
      final mid = cardOrigin.dy + rb.size.height / 2;
      if (global.dy < mid) return rank;
      rank++;
    }
    return rank;
  }

  Rect? _rectForTaskId(String taskId) {
    final ctx = GlobalObjectKey(taskId).currentContext;
    if (ctx == null) return null;
    final rb = ctx.findRenderObject();
    if (rb is! RenderBox || !rb.attached) return null;
    return rb.localToGlobal(Offset.zero) & rb.size;
  }

  // Auto-scroll ---------------------------------------------------------------

  static const _edgePx = 64.0;
  static const _maxPxPerSecond = 900.0;

  Duration _lastTick = Duration.zero;

  void _onAutoScrollTick(Duration elapsed) {
    if (_phase != DragPhase.dragging) {
      _lastTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;

    // Vertical: column under pointer.
    final col = _columnAt(_pointerGlobal);
    if (col != null) {
      final ctx = col.listAreaKey.currentContext;
      if (ctx != null) {
        final rb = ctx.findRenderObject();
        if (rb is RenderBox && rb.attached) {
          final origin = rb.localToGlobal(Offset.zero);
          final localY = _pointerGlobal.dy - origin.dy;
          final h = rb.size.height;
          double speed = 0;
          if (localY < _edgePx) {
            speed = -_lerpSpeed(localY, 0, _edgePx);
          } else if (localY > h - _edgePx) {
            speed = _lerpSpeed(h - localY, 0, _edgePx);
          }
          if (speed != 0 && col.scroll.hasClients) {
            final next = (col.scroll.offset + speed * dt)
                .clamp(0.0, col.scroll.position.maxScrollExtent);
            col.scroll.jumpTo(next);
          }
        }
      }
    }

    // Horizontal: board level.
    final boardScroll = _boardScroll;
    if (boardScroll != null && boardScroll.hasClients) {
      final viewport =
          WidgetsBinding.instance.platformDispatcher.views.first.physicalSize /
              WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      final w = viewport.width;
      double hSpeed = 0;
      if (_pointerGlobal.dx < _edgePx) {
        hSpeed = -_lerpSpeed(_pointerGlobal.dx, 0, _edgePx);
      } else if (_pointerGlobal.dx > w - _edgePx) {
        hSpeed = _lerpSpeed(w - _pointerGlobal.dx, 0, _edgePx);
      }
      if (hSpeed != 0) {
        final next = (boardScroll.offset + hSpeed * dt)
            .clamp(0.0, boardScroll.position.maxScrollExtent);
        boardScroll.jumpTo(next);
      }
    }
  }

  static double _lerpSpeed(double v, double atMin, double atMax) {
    final clamped = v.clamp(atMin, atMax);
    final t = 1 - (clamped - atMin) / (atMax - atMin);
    return _maxPxPerSecond * t;
  }

  @override
  void dispose() {
    _autoScrollTicker.dispose();
    super.dispose();
  }
}


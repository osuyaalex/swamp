import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/presentation/drag/drag_controller.dart';
import 'package:untitled2/features/task_board/presentation/widgets/chips.dart';
import 'package:untitled2/features/task_board/presentation/widgets/rich_text.dart';

/// Pure visual representation of a task card. Used both in-column and as
/// the floating ghost during a drag.
class TaskCardVisual extends StatelessWidget {
  const TaskCardVisual({
    super.key,
    required this.task,
    this.ghost = false,
  });

  final Task task;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overdue = task.isOverdue;
    return Container(
      decoration: BoxDecoration(
        color: ghost ? theme.colorScheme.primary.withValues(alpha: 0.1) : theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: ghost
              ? theme.colorScheme.primary
              : Colors.white.withValues(alpha: 0.08),
          width: ghost ? 2 : 1,
        ),
        boxShadow: ghost
            ? [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  blurRadius: 20,
                  spreadRadius: 2,
                )
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                PriorityChip(priority: task.priority, dense: true),
              ],
            ),
            if (task.description.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 60),
                child: ClipRect(
                  child: RichTextView(
                    task.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (task.dueDate != null)
                  DueDateChip(dueDate: task.dueDate!, overdue: overdue),
                const Spacer(),
                if (task.comments.isNotEmpty) ...[
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 13,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${task.comments.length}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Interactive wrapper: long-press starts a drag, tap opens detail.
/// Renders a transparent placeholder of identical size while it is the
/// active drag target so the column doesn't reflow.
class TaskCard extends StatefulWidget {
  const TaskCard({
    required this.task,
    required this.onTap,
    super.key,
  });

  final Task task;
  final VoidCallback onTap;

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  Offset? _pressOrigin;

  void _onLongPressStart(LongPressStartDetails details) {
    final drag = context.read<DragController>();
    if (drag.phase != DragPhase.idle) return; // already busy
    final rb = context.findRenderObject();
    if (rb is! RenderBox || !rb.attached) return;
    _pressOrigin = rb.localToGlobal(Offset.zero);
    drag.start(
      task: widget.task,
      pointerGlobal: details.globalPosition,
      cardTopLeftGlobal: _pressOrigin!,
      cardSize: rb.size,
    );
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    context.read<DragController>().updatePointer(details.globalPosition);
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    context.read<DragController>().drop();
  }

  void _onLongPressCancel() {
    final drag = context.read<DragController>();
    if (drag.phase == DragPhase.dragging) drag.cancel();
  }

  @override
  Widget build(BuildContext context) {
    // Watch only the active id slice — when the active drag is some other
    // card, this rebuild path is a no-op.
    final activeId = context.select<DragController, String?>((d) => d.activeTaskId);
    final isDragged = activeId == widget.task.id;

    final visual = TaskCardVisual(task: widget.task);

    return GestureDetector(
      key: GlobalObjectKey(widget.task.id),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPressStart: _onLongPressStart,
      onLongPressMoveUpdate: _onLongPressMoveUpdate,
      onLongPressEnd: _onLongPressEnd,
      onLongPressCancel: _onLongPressCancel,
      child: AnimatedOpacity(
        opacity: isDragged ? 0.18 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: isDragged
                ? Border.all(
                    color: widget.task.priority.color.withValues(alpha: 0.5),
                    width: 1.2,
                  )
                : null,
          ),
          child: visual,
        ),
      ),
    );
  }
}

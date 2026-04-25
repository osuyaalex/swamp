import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/presentation/drag/drag_controller.dart';
import 'package:untitled2/features/task_board/presentation/task_board_controller.dart';
import 'package:untitled2/features/task_board/presentation/widgets/task_card.dart';

class TaskColumn extends StatefulWidget {
  const TaskColumn({
    super.key,
    required this.status,
    required this.onTapTask,
    required this.onTapAdd,
  });

  final TaskStatus status;
  final void Function(Task task) onTapTask;
  final VoidCallback onTapAdd;

  @override
  State<TaskColumn> createState() => _TaskColumnState();
}

class _TaskColumnState extends State<TaskColumn> {
  final _scroll = ScrollController();
  final _listKey = GlobalKey();
  bool _registered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_registered) return;
    final drag = context.read<DragController>();
    final board = context.read<TaskBoardController>();
    drag.registerColumn(
      ColumnDragRegistration(
        status: widget.status,
        listAreaKey: _listKey,
        scroll: _scroll,
        snapshot: () => board.column(widget.status),
      ),
    );
    _registered = true;
  }

  @override
  void dispose() {
    final drag = context.read<DragController>();
    drag.unregisterColumn(widget.status);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final board = context.watch<TaskBoardController>();
    final tasks = board.column(widget.status);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ColumnHeader(
            status: widget.status,
            count: tasks.length,
            onAdd: widget.status == TaskStatus.todo ? widget.onTapAdd : null,
          ),
          Expanded(
            child: KeyedSubtree(
              key: _listKey,
              child: _ColumnBody(
                status: widget.status,
                tasks: tasks,
                scroll: _scroll,
                onTapTask: widget.onTapTask,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({
    required this.status,
    required this.count,
    required this.onAdd,
  });

  final TaskStatus status;
  final int count;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dot = switch (status) {
      TaskStatus.todo => theme.colorScheme.outline,
      TaskStatus.inProgress => theme.colorScheme.primary,
      TaskStatus.done => const Color(0xFF4CAF50),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            status.label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          if (onAdd != null)
            IconButton(
              tooltip: 'New task',
              icon: const Icon(Icons.add, size: 20),
              onPressed: onAdd,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

class _ColumnBody extends StatelessWidget {
  const _ColumnBody({
    required this.status,
    required this.tasks,
    required this.scroll,
    required this.onTapTask,
  });

  final TaskStatus status;
  final List<Task> tasks;
  final ScrollController scroll;
  final void Function(Task) onTapTask;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
      // +1 trailing slot for end-of-column drops.
      itemCount: tasks.length + 1,
      itemBuilder: (context, index) {
        if (index == tasks.length) {
          return _DropSlot(status: status, index: index, trailing: true);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DropSlot(status: status, index: index),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: TaskCard(
                task: tasks[index],
                onTap: () => onTapTask(tasks[index]),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Animated insertion indicator. Expands to leave space when the active
/// drag's hover index matches this slot, collapses otherwise.
class _DropSlot extends StatelessWidget {
  const _DropSlot({
    required this.status,
    required this.index,
    this.trailing = false,
  });

  final TaskStatus status;
  final int index;
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    return Selector<DragController, _SlotShape>(
      selector: (_, d) => _SlotShape(
        active: d.phase == DragPhase.dragging &&
            d.hoverStatus == status &&
            d.hoverIndex == index,
        targetHeight: d.cardSize.height,
      ),
      builder: (context, shape, _) {
        final h = shape.active
            ? (shape.targetHeight + 8.0)
            : (trailing ? 24.0 : 0.0);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          height: h,
          margin: shape.active
              ? const EdgeInsets.symmetric(vertical: 4)
              : EdgeInsets.zero,
          decoration: shape.active
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: 0.5),
                    width: 1.4,
                  ),
                )
              : null,
        );
      },
    );
  }
}

class _SlotShape {
  _SlotShape({required this.active, required this.targetHeight});
  final bool active;
  final double targetHeight;

  @override
  bool operator ==(Object other) =>
      other is _SlotShape &&
      other.active == active &&
      other.targetHeight == targetHeight;

  @override
  int get hashCode => Object.hash(active, targetHeight);
}

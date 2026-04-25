import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/presentation/sheets/task_editor_sheet.dart';
import 'package:untitled2/features/task_board/presentation/task_board_controller.dart';
import 'package:untitled2/features/task_board/presentation/widgets/chips.dart';
import 'package:untitled2/features/task_board/presentation/widgets/rich_text.dart';

class TaskDetailSheet extends StatefulWidget {
  const TaskDetailSheet({super.key, required this.taskId});

  final String taskId;

  static Future<void> show(BuildContext context, String taskId) {
    // Modal routes live under the root Navigator, above the screen-level
    // MultiProvider. Re-provide the board controller so the sheet can read it.
    final board = context.read<TaskBoardController>();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ChangeNotifierProvider<TaskBoardController>.value(
        value: board,
        child: TaskDetailSheet(taskId: taskId),
      ),
    );
  }

  @override
  State<TaskDetailSheet> createState() => _TaskDetailSheetState();
}

class _TaskDetailSheetState extends State<TaskDetailSheet> {
  final _commentCtrl = TextEditingController();

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete task?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    await context.read<TaskBoardController>().deleteTask(widget.taskId);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _postComment() async {
    final body = _commentCtrl.text;
    if (body.trim().isEmpty) return;
    await context.read<TaskBoardController>().addComment(
          taskId: widget.taskId,
          author: 'You',
          body: body,
        );
    _commentCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final board = context.watch<TaskBoardController>();
    final task = board.findById(widget.taskId);
    if (task == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('Task not found')),
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.title,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () =>
                              TaskEditorSheet.show(context, existing: task),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _confirmDelete,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PriorityChip(priority: task.priority),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color:
                                theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            task.status.label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (task.dueDate != null)
                          DueDateChip(
                            dueDate: task.dueDate!,
                            overdue: task.isOverdue,
                          ),
                      ],
                    ),
                    if (task.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        'Description',
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 6),
                      RichTextView(task.description),
                    ],
                    const SizedBox(height: 22),
                    Text('Activity', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    _ActivityFeed(task: task),
                    const SizedBox(height: 22),
                    Text('Comments', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    if (task.comments.isEmpty)
                      Text(
                        'No comments yet.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      )
                    else
                      Column(
                        children: [
                          for (final c in task.comments)
                            _CommentRow(comment: c),
                        ],
                      ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                      width: 0.5,
                    ),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _commentCtrl,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _postComment(),
                        decoration: const InputDecoration(
                          hintText: 'Add a comment…',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send_rounded),
                      onPressed: _postComment,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActivityFeed extends StatelessWidget {
  const _ActivityFeed({required this.task});
  final Task task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = [...task.activity]..sort((a, b) => b.at.compareTo(a.at));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  _iconFor(e.kind),
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.message,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Text(
                  _relative(e.at),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _iconFor(ActivityKind k) => switch (k) {
        ActivityKind.created => Icons.fiber_new_outlined,
        ActivityKind.edited => Icons.edit_outlined,
        ActivityKind.moved => Icons.swap_horiz_rounded,
        ActivityKind.prioritized => Icons.flag_outlined,
        ActivityKind.commented => Icons.chat_bubble_outline,
        ActivityKind.scheduled => Icons.event_outlined,
        ActivityKind.deleted => Icons.delete_outline,
      };

  static String _relative(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inSeconds < 45) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m';
    if (delta.inHours < 24) return '${delta.inHours}h';
    return '${delta.inDays}d';
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment});
  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 10,
                  backgroundColor:
                      theme.colorScheme.primary.withValues(alpha: 0.2),
                  child: Text(
                    comment.author.substring(0, 1),
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  comment.author,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _short(comment.createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(comment.body, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  static String _short(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inSeconds < 45) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m';
    if (delta.inHours < 24) return '${delta.inHours}h';
    return '${delta.inDays}d';
  }
}

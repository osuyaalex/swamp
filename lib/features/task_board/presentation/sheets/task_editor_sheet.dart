import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/presentation/task_board_controller.dart';
import 'package:untitled2/features/task_board/presentation/widgets/rich_text.dart';

/// Used for both create and edit. When [existing] is null we create.
class TaskEditorSheet extends StatefulWidget {
  const TaskEditorSheet({super.key, this.existing});

  final Task? existing;

  static Future<void> show(BuildContext context, {Task? existing}) {
    // Modal routes are pushed under the root Navigator — outside the
    // screen-level MultiProvider. Capture the controller here and re-provide
    // it inside the sheet so descendants can `read`/`watch` it.
    final board = context.read<TaskBoardController>();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => ChangeNotifierProvider<TaskBoardController>.value(
        value: board,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: TaskEditorSheet(existing: existing),
        ),
      ),
    );
  }

  @override
  State<TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<TaskEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _desc;
  late TaskPriority _priority;
  DateTime? _due;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _desc = TextEditingController(text: widget.existing?.description ?? '');
    _priority = widget.existing?.priority ?? TaskPriority.medium;
    _due = widget.existing?.dueDate;
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? now.add(const Duration(days: 1)),
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_due ?? now),
    );
    if (!mounted) return;
    final t = time ?? const TimeOfDay(hour: 9, minute: 0);
    setState(() {
      _due = DateTime(picked.year, picked.month, picked.day, t.hour, t.minute);
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title is required')),
      );
      return;
    }
    final board = context.read<TaskBoardController>();
    if (widget.existing == null) {
      await board.createTask(
        title: title,
        description: _desc.text.trim(),
        priority: _priority,
        dueDate: _due,
      );
    } else {
      await board.editTask(
        taskId: widget.existing!.id,
        title: title,
        description: _desc.text.trim(),
        priority: _priority,
        dueDate: _due,
        clearDueDate: _due == null && widget.existing!.dueDate != null,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              widget.existing == null ? 'New task' : 'Edit task',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _title,
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Task title'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 14),
            RichTextEditor(controller: _desc),
            const SizedBox(height: 14),
            Text('Priority', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final p in TaskPriority.values)
                  _PriorityToggle(
                    priority: p,
                    selected: _priority == p,
                    onTap: () => setState(() => _priority = p),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text('Due date', style: theme.textTheme.labelLarge),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: _pickDue,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: theme.inputDecorationTheme.fillColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.event_outlined,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _due == null ? 'No due date' : _formatDue(_due!),
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          if (_due != null)
                            IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close, size: 16),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => _due = null),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _save,
                  child: Text(widget.existing == null ? 'Create' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDue(DateTime due) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${due.year}-${two(due.month)}-${two(due.day)}  '
        '${two(due.hour)}:${two(due.minute)}';
  }
}

class _PriorityToggle extends StatelessWidget {
  const _PriorityToggle({
    required this.priority,
    required this.selected,
    required this.onTap,
  });

  final TaskPriority priority;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? priority.color.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: priority.color.withValues(alpha: selected ? 0.7 : 0.3),
            width: selected ? 1.6 : 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: priority.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              priority.label,
              style: TextStyle(
                color: priority.color,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'package:untitled2/features/task_board/domain/entities/task.dart';

class PriorityChip extends StatelessWidget {
  const PriorityChip({super.key, required this.priority, this.dense = false});

  final TaskPriority priority;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = priority.color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 9,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            priority.label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: dense ? 10.5 : 11.5,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class DueDateChip extends StatelessWidget {
  const DueDateChip({super.key, required this.dueDate, required this.overdue});

  final DateTime dueDate;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final base = overdue
        ? const Color(0xFFE53935)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final delta = dueDate.difference(DateTime.now());
    final label = _formatRelative(delta, dueDate);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          overdue ? Icons.error_outline : Icons.event_outlined,
          size: 13,
          color: base,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: base,
            fontSize: 11.5,
            fontWeight: overdue ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  static String _formatRelative(Duration delta, DateTime due) {
    if (delta.isNegative) {
      final days = (-delta.inHours / 24).floor();
      if (days >= 1) return 'Overdue ${days}d';
      final hours = (-delta.inMinutes / 60).floor();
      if (hours >= 1) return 'Overdue ${hours}h';
      return 'Overdue';
    }
    if (delta.inDays >= 1) return 'Due in ${delta.inDays}d';
    if (delta.inHours >= 1) return 'Due in ${delta.inHours}h';
    if (delta.inMinutes >= 1) return 'Due in ${delta.inMinutes}m';
    return 'Due now';
  }
}

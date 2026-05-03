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
        horizontal: dense ? 8 : 12,
        vertical: dense ? 3 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: color, 
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4, spreadRadius: 1),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            priority.label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: dense ? 10 : 11,
              letterSpacing: 1.1,
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

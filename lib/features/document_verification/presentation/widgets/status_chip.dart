import 'package:flutter/material.dart';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';

class DocumentStatusChip extends StatelessWidget {
  const DocumentStatusChip({
    super.key,
    required this.status,
    this.compact = false,
  });

  final DocumentStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
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
            status.label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 10.5 : 11.5,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

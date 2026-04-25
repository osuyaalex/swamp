import 'package:flutter/material.dart';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/widgets/status_chip.dart';

/// Single row in the dashboard list.
class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.document,
    required this.onTap,
    required this.onRetry,
    required this.onDelete,
  });

  final Document document;
  final VoidCallback onTap;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showProgress = !document.status.isTerminal;
    final eta = _eta(document);
    final canRetry = document.status == DocumentStatus.queued ||
        document.status == DocumentStatus.rejected;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: document.status.color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    document.type.icon,
                    color: document.status.color,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        document.type.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        document.originalName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DocumentStatusChip(status: document.status, compact: true),
                PopupMenuButton<String>(
                  tooltip: 'Actions',
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (v) {
                    switch (v) {
                      case 'retry':
                        onRetry();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    if (canRetry)
                      const PopupMenuItem(value: 'retry', child: Text('Retry')),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Remove')),
                  ],
                ),
              ],
            ),
            if (showProgress) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: document.status == DocumentStatus.uploading
                      ? null // indeterminate while bytes upload
                      : document.progress,
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(document.status.color),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      document.stage ?? document.status.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (eta != null)
                    Text(
                      eta,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
            if (document.status == DocumentStatus.rejected) ...[
              const SizedBox(height: 10),
              _RejectionStrip(
                reason: document.rejectionReason ?? 'Verification failed.',
                onRetry: onRetry,
              ),
            ],
            if (document.status == DocumentStatus.verified &&
                document.expiresAt != null) ...[
              const SizedBox(height: 8),
              Text(
                'Expires ${_relative(document.expiresAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String? _eta(Document d) {
    if (d.status.isTerminal) return null;
    if (d.progress <= 0) return null;
    if (d.uploadedAt == null) return null;
    final elapsed = DateTime.now().difference(d.uploadedAt!).inSeconds;
    if (elapsed <= 0 || d.progress < 0.05) return null;
    final total = elapsed / d.progress;
    final remaining = (total - elapsed).round();
    if (remaining < 1) return '<1s left';
    if (remaining < 60) return '${remaining}s left';
    final mins = (remaining / 60).round();
    return '${mins}m left';
  }

  static String _relative(DateTime at) {
    final delta = at.difference(DateTime.now());
    if (delta.inDays > 60) return 'in ${(delta.inDays / 30).round()} months';
    if (delta.inDays > 1) return 'in ${delta.inDays} days';
    if (delta.inHours > 1) return 'in ${delta.inHours} hours';
    if (delta.inMinutes > 1) return 'in ${delta.inMinutes} minutes';
    return 'soon';
  }
}

class _RejectionStrip extends StatelessWidget {
  const _RejectionStrip({required this.reason, required this.onRetry});

  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: c,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

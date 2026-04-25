import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_controller.dart';
import 'package:untitled2/features/document_verification/presentation/widgets/status_chip.dart';

class DocumentDetailSheet extends StatelessWidget {
  const DocumentDetailSheet({super.key, required this.documentId});

  final String documentId;

  static Future<void> show(BuildContext context, String documentId) {
    final controller = context.read<DocumentDashboardController>();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ChangeNotifierProvider<DocumentDashboardController>.value(
        value: controller,
        child: DocumentDetailSheet(documentId: documentId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DocumentDashboardController>();
    final doc = controller.documents
        .where((d) => d.id == documentId)
        .cast<Document?>()
        .firstWhere((_) => true, orElse: () => null);
    if (doc == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('Document not found')),
      );
    }
    final theme = Theme.of(context);
    final canRetry = doc.status == DocumentStatus.queued ||
        doc.status == DocumentStatus.rejected;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        return Column(
          children: [
            const SizedBox(height: 12),
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
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: doc.status.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(doc.type.icon, color: doc.status.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              doc.type.label,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              doc.originalName,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      DocumentStatusChip(status: doc.status),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (!doc.status.isTerminal) ...[
                    LinearProgressIndicator(
                      value: doc.status == DocumentStatus.uploading
                          ? null
                          : doc.progress,
                      minHeight: 6,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      valueColor:
                          AlwaysStoppedAnimation(doc.status.color),
                    ),
                    const SizedBox(height: 8),
                    if (doc.stage != null)
                      Text(
                        '${doc.stage!} — ${(doc.progress * 100).round()}%',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (doc.confidence != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Confidence ${(doc.confidence! * 100).round()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                  if (doc.status == DocumentStatus.rejected &&
                      doc.rejectionReason != null) ...[
                    _Notice(
                      icon: Icons.error_outline,
                      color: theme.colorScheme.error,
                      title: 'Rejected',
                      body: doc.rejectionReason!,
                    ),
                    if (doc.issues.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      for (final issue in doc.issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Icon(Icons.fiber_manual_record,
                                  size: 6, color: theme.colorScheme.error),
                              const SizedBox(width: 8),
                              Expanded(child: Text(issue)),
                            ],
                          ),
                        ),
                    ],
                  ],
                  if (doc.status == DocumentStatus.verified) ...[
                    _Notice(
                      icon: Icons.verified_outlined,
                      color: doc.status.color,
                      title: 'Verified',
                      body: 'This document is valid'
                          '${doc.expiresAt == null ? '.' : ' until ${_short(doc.expiresAt!)}.'}',
                    ),
                  ],
                  const SizedBox(height: 22),
                  Text('Audit trail', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  _AuditTimeline(entries: doc.audit),
                  const SizedBox(height: 22),
                  _Meta(doc: doc),
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
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await context
                          .read<DocumentDashboardController>()
                          .delete(documentId);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                  const Spacer(),
                  if (canRetry)
                    FilledButton.icon(
                      onPressed: () async {
                        await context
                            .read<DocumentDashboardController>()
                            .retry(documentId);
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _short(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)}';
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditTimeline extends StatelessWidget {
  const _AuditTimeline({required this.entries});
  final List<AuditEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ordered = [...entries]..sort((a, b) => b.at.compareTo(a.at));
    if (ordered.isEmpty) {
      return Text(
        'No audit entries yet.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in ordered)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _iconFor(e.kind),
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(e.message, style: theme.textTheme.bodySmall)),
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

  IconData _iconFor(AuditKind k) => switch (k) {
        AuditKind.uploaded => Icons.upload_outlined,
        AuditKind.statusChanged => Icons.timelapse,
        AuditKind.retried => Icons.refresh,
        AuditKind.verified => Icons.verified_outlined,
        AuditKind.rejected => Icons.cancel_outlined,
        AuditKind.deleted => Icons.delete_outline,
      };

  static String _relative(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inSeconds < 45) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m';
    if (delta.inHours < 24) return '${delta.inHours}h';
    return '${delta.inDays}d';
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.doc});
  final Document doc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('File size', _sizeLabel(doc.size)),
      ('Checksum', doc.checksum),
      if (doc.uploadedAt != null) ('Uploaded', _isoLocal(doc.uploadedAt!)),
      if (doc.verifiedAt != null) ('Verified', _isoLocal(doc.verifiedAt!)),
      if (doc.expiresAt != null) ('Expires', _isoLocal(doc.expiresAt!)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(value, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  static String _isoLocal(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    final l = at.toLocal();
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

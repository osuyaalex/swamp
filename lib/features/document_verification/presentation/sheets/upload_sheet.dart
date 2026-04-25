import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/document_verification/data/document_source.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_controller.dart';

class UploadSheet extends StatefulWidget {
  const UploadSheet({super.key});

  static Future<void> show(BuildContext context) {
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
        child: const UploadSheet(),
      ),
    );
  }

  @override
  State<UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<UploadSheet> {
  DocumentType? _picked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
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
            const SizedBox(height: 16),
            Text(
              _picked == null ? 'Upload a document' : 'How would you like to add it?',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            if (_picked == null) ..._typeOptions(theme) else ..._sourceOptions(theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _typeOptions(ThemeData theme) {
    return [
      for (final type in DocumentType.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _OptionTile(
            icon: type.icon,
            title: type.label,
            subtitle: _hintFor(type),
            onTap: () => setState(() => _picked = type),
          ),
        ),
    ];
  }

  List<Widget> _sourceOptions(ThemeData theme) {
    final options = [
      (
        DocumentSourceKind.camera,
        Icons.photo_camera_outlined,
        'Capture with camera',
        'Best for ID cards and passports.'
      ),
      (
        DocumentSourceKind.gallery,
        Icons.photo_library_outlined,
        'Choose from gallery',
        'Pick an existing photo.'
      ),
      (
        DocumentSourceKind.file,
        Icons.attach_file,
        'Pick a file',
        'PDF, JPG, or PNG (up to 10 MB).'
      ),
    ];
    return [
      _SelectedTypeBadge(type: _picked!),
      const SizedBox(height: 12),
      for (final (kind, icon, title, subtitle) in options)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _OptionTile(
            icon: icon,
            title: title,
            subtitle: subtitle,
            onTap: () async {
              final controller = context.read<DocumentDashboardController>();
              await controller.pickAndUpload(type: _picked!, kind: kind);
              if (!mounted) return;
              Navigator.of(context).pop();
              if (controller.lastError != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(controller.lastError!)),
                );
              }
            },
          ),
        ),
      const SizedBox(height: 6),
      TextButton(
        onPressed: () => setState(() => _picked = null),
        child: const Text('Choose a different type'),
      ),
    ];
  }

  static String _hintFor(DocumentType t) => switch (t) {
        DocumentType.passport => 'Photo page only — both sides if biometric.',
        DocumentType.nationalId => 'Front and back, in focus, no glare.',
        DocumentType.utilityBill => 'Issued in the last 90 days.',
      };
}

class _SelectedTypeBadge extends StatelessWidget {
  const _SelectedTypeBadge({required this.type});
  final DocumentType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(type.icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            type.label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.outline,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

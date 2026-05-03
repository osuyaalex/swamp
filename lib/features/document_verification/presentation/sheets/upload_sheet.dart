import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/document_verification/data/document_source.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_controller.dart';
import 'package:untitled2/features/document_verification/presentation/sheets/document_camera_screen.dart';

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
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _picked == null ? 'Upload Document' : 'Select Source',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w900,
                fontSize: 24,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _picked == null 
                  ? 'Select the type of document you want to verify.' 
                  : 'Choose how you want to provide your ${_picked!.label}.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
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
    return [
      _SelectedTypeBadge(type: _picked!),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _OptionTile(
          icon: Icons.document_scanner_outlined,
          title: 'Scan with custom camera',
          subtitle:
              'Real-time edge detection — best for IDs, passports, bills.',
          onTap: () async {
            Navigator.of(context).pop();
            await DocumentCameraScreen.open(
              context,
              documentType: _picked!,
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _OptionTile(
          icon: Icons.photo_camera_outlined,
          title: 'Quick photo',
          subtitle: 'Use the system camera (no edge detection).',
          onTap: () => _runPicker(DocumentSourceKind.camera),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _OptionTile(
          icon: Icons.photo_library_outlined,
          title: 'Choose from gallery',
          subtitle: 'Pick an existing photo.',
          onTap: () => _runPicker(DocumentSourceKind.gallery),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _OptionTile(
          icon: Icons.attach_file,
          title: 'Pick a file',
          subtitle: 'PDF, JPG, or PNG (up to 10 MB).',
          onTap: () => _runPicker(DocumentSourceKind.file),
        ),
      ),
      const SizedBox(height: 6),
      TextButton(
        onPressed: () => setState(() => _picked = null),
        child: const Text('Choose a different type'),
      ),
    ];
  }

  Future<void> _runPicker(DocumentSourceKind kind) async {
    final controller = context.read<DocumentDashboardController>();
    final messenger = ScaffoldMessenger.of(context);
    await controller.pickAndUpload(type: _picked!, kind: kind);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (controller.lastError != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(controller.lastError!)),
      );
    }
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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: theme.colorScheme.primary, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
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
                  Icons.arrow_forward_ios_rounded,
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

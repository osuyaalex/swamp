import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/document_verification/data/document_api_client.dart';
import 'package:untitled2/features/document_verification/data/document_polling_service.dart';
import 'package:untitled2/features/document_verification/data/document_repository_impl.dart';
import 'package:untitled2/features/document_verification/data/document_source.dart';
import 'package:untitled2/features/document_verification/data/document_websocket_client.dart';
import 'package:untitled2/features/document_verification/data/mock_document_backend.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_controller.dart';
import 'package:untitled2/features/document_verification/presentation/sheets/document_detail_sheet.dart';
import 'package:untitled2/features/document_verification/presentation/sheets/upload_sheet.dart';
import 'package:untitled2/features/document_verification/presentation/widgets/connection_banner.dart';
import 'package:untitled2/features/document_verification/presentation/widgets/document_card.dart';

class DocumentDashboardScreen extends StatefulWidget {
  const DocumentDashboardScreen({super.key});

  @override
  State<DocumentDashboardScreen> createState() =>
      _DocumentDashboardScreenState();
}

class _DocumentDashboardScreenState extends State<DocumentDashboardScreen> {
  late final DocumentDashboardController _controller;

  @override
  void initState() {
    super.initState();
    final backend = MockDocumentBackend();
    final api = DocumentApiClient(backend);
    final ws = DocumentWebSocketClient(backend);
    final polling = DocumentPollingService(api);
    final repo = DocumentRepositoryImpl(
      api: api,
      ws: ws,
      polling: polling,
    );
    _controller = DocumentDashboardController(
      repository: repo,
      source: PlatformDocumentSource(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DocumentDashboardController>.value(
      value: _controller,
      child: const _DashboardScaffold(),
    );
  }
}

class _DashboardScaffold extends StatelessWidget {
  const _DashboardScaffold();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'SWAMP_  •  Documents',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
        ),
        actions: [
          IconButton(
            tooltip: 'Upload',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: () => UploadSheet.show(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: const [
            ConnectionBanner(),
            Expanded(child: _DashboardBody()),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => UploadSheet.show(context),
        icon: const Icon(Icons.add),
        label: const Text('New document'),
      ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DocumentDashboardController>();
    if (controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final docs = controller.documents;
    if (docs.isEmpty) {
      return const _EmptyState();
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      children: [
        _SummaryHeader(summary: controller.summary),
        const SizedBox(height: 14),
        for (final d in docs)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DocumentCard(
              key: ValueKey(d.id),
              document: d,
              onTap: () => DocumentDetailSheet.show(context, d.id),
              onRetry: () => controller.retry(d.id),
              onDelete: () => controller.delete(d.id),
            ),
          ),
      ],
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.summary});
  final ({int verified, int rejected, int pending}) summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String label, int value, Color color) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Column(
            children: [
              Text(
                '$value',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        cell('VERIFIED', summary.verified, DocumentStatus.verified.color),
        const SizedBox(width: 8),
        cell('PENDING', summary.pending, DocumentStatus.processing.color),
        const SizedBox(width: 8),
        cell('REJECTED', summary.rejected, DocumentStatus.rejected.color),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 14),
            Text(
              'No documents yet',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Upload an ID, passport, or utility bill to start a verification.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => UploadSheet.show(context),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Upload your first document'),
            ),
          ],
        ),
      ),
    );
  }
}

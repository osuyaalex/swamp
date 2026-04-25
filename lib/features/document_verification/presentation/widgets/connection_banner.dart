import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/document_verification/domain/entities/document.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_controller.dart';

/// Slim banner that materialises when the WebSocket is not connected.
/// Tells the user (a) that real-time updates are degraded and (b) that
/// the polling fallback is keeping things current.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.select<DocumentDashboardController,
        DocumentConnectionState>((c) => c.connection);
    final isConnected = state == DocumentConnectionState.connected;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: isConnected
          ? const SizedBox.shrink(child: SizedBox(width: double.infinity))
          : _Banner(state: state),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.state});
  final DocumentConnectionState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isReconnecting = state == DocumentConnectionState.reconnecting;
    final color = isReconnecting
        ? const Color(0xFFFFA000)
        : theme.colorScheme.error;
    return Material(
      color: color.withValues(alpha: 0.10),
      child: InkWell(
        onTap: () =>
            context.read<DocumentDashboardController>().reconnect(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: isReconnecting
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Icon(Icons.cloud_off, size: 14, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isReconnecting
                      ? 'Reconnecting to live updates… '
                          'polling in the meantime.'
                      : 'Offline — falling back to polling. '
                          'Tap to retry the WebSocket.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                'Retry',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

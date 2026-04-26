import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_protector/screen_protector.dart';

import 'package:untitled2/core/connectivity_state.dart';
import 'package:untitled2/core/screen_capture_guard.dart';
import 'package:untitled2/features/document_verification/presentation/document_dashboard_screen.dart';
import 'package:untitled2/features/task_board/presentation/task_board_screen.dart';

/// App shell with two tabs plus two app-wide concerns:
///
///  • A network connectivity banner that materialises whenever the
///    device loses connectivity, so users never have to guess why an
///    upload or task sync isn't progressing.
///  • A platform-level screen-capture guard that activates while the
///    user is on the Documents tab. On Android this turns on
///    `FLAG_SECURE` (the OS refuses to capture the window into a
///    screenshot or recording). On iOS, where Apple does not expose an
///    API to block screenshots, the guard listens for screen-recording
///    state and presents a blur as a soft barrier.
///
/// Uses `IndexedStack` (not a `PageView` or rebuilt body) so both feature
/// screens stay mounted when you switch tabs. That matters because:
///   - the task board's `DragController` ticker would otherwise tear down
///     mid-drag if you happened to swipe to Documents
///   - in-flight uploads on the document side should keep streaming
///     status updates even when the user is looking at the task board
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _connectivity = ConnectivityWatcher();
  late final StreamSubscription<ConnectivityState> _connSub;
  ConnectivityState _connState = ConnectivityState.online;
  bool _screenGuardActive = false;

  static const _tabs = [
    _TabInfo(
      label: 'Tasks',
      icon: Icons.dashboard_customize_outlined,
      activeIcon: Icons.dashboard_customize,
    ),
    _TabInfo(
      label: 'Documents',
      icon: Icons.fact_check_outlined,
      activeIcon: Icons.fact_check,
    ),
  ];

  static const _docsTabIndex = 1;

  @override
  void initState() {
    super.initState();
    _connSub = _connectivity.stream.listen((next) {
      if (mounted) setState(() => _connState = next);
    });
    // TEMPORARY (for video recording): force-clear FLAG_SECURE that
    // may persist on the Android Activity from a previous run, since
    // hot restart doesn't reinitialise the activity. Revert this and
    // re-enable `ScreenCaptureGuard.protect()` before shipping.
    ScreenProtector.protectDataLeakageOff();
    _syncScreenGuardFor(_index);
  }

  @override
  void dispose() {
    _connSub.cancel();
    _connectivity.dispose();
    if (_screenGuardActive) {
      ScreenCaptureGuard.instance.release();
    }
    super.dispose();
  }

  void _onTabChanged(int next) {
    setState(() => _index = next);
    _syncScreenGuardFor(next);
  }

  Future<void> _syncScreenGuardFor(int tabIndex) async {
    final shouldProtect = tabIndex == _docsTabIndex;
    if (shouldProtect && !_screenGuardActive) {
      _screenGuardActive = true;
      await ScreenCaptureGuard.instance.protect();
    } else if (!shouldProtect && _screenGuardActive) {
      _screenGuardActive = false;
      await ScreenCaptureGuard.instance.release();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _OfflineBanner(state: _connState),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [
                  TaskBoardScreen(),
                  DocumentDashboardScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTabChanged,
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.activeIcon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.state});

  final ConnectivityState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: state == ConnectivityState.online
          ? const SizedBox(width: double.infinity)
          : Material(
              color: color.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, size: 14, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You are offline. Uploads and live updates will '
                        'resume once you reconnect.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _TabInfo {
  const _TabInfo({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

import 'package:flutter/material.dart';

import 'package:untitled2/features/document_verification/presentation/document_dashboard_screen.dart';
import 'package:untitled2/features/task_board/presentation/task_board_screen.dart';

/// App shell with two tabs.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          TaskBoardScreen(),
          DocumentDashboardScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/core/notifications.dart';
import 'package:untitled2/features/task_board/data/in_memory_task_repository.dart';
import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'drag/drag_controller.dart';
import 'drag/drag_overlay.dart';
import 'sheets/task_detail_sheet.dart';
import 'sheets/task_editor_sheet.dart';
import 'task_board_controller.dart';
import 'widgets/task_column.dart';

class TaskBoardScreen extends StatefulWidget {
  const TaskBoardScreen({super.key});

  @override
  State<TaskBoardScreen> createState() => _TaskBoardScreenState();
}

class _TaskBoardScreenState extends State<TaskBoardScreen>
    with TickerProviderStateMixin {
  late final TaskBoardController _board;
  late final DragController _drag;

  @override
  void initState() {
    super.initState();
    _board = TaskBoardController(
      repository: InMemoryTaskRepository(),
      notifications: InAppNotificationService(),
    );
    _drag = DragController(boardController: _board, vsync: this);
  }

  @override
  void dispose() {
    _drag.dispose();
    _board.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _board),
        ChangeNotifierProvider.value(value: _drag),
      ],
      child: const _BoardScaffold(),
    );
  }
}

class _BoardScaffold extends StatelessWidget {
  const _BoardScaffold();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SWAMP_  •  Tasks',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
        ),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            tooltip: 'New task',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => TaskEditorSheet.show(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: const [
            Positioned.fill(child: _BoardBody()),
            Positioned.fill(child: DragOverlayLayer()),
          ],
        ),
      ),
    );
  }
}

class _BoardBody extends StatefulWidget {
  const _BoardBody();

  @override
  State<_BoardBody> createState() => _BoardBodyState();
}

class _BoardBodyState extends State<_BoardBody> {
  final _hScroll = ScrollController();
  bool _registered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_registered) return;
    context.read<DragController>().registerBoardScroll(_hScroll);
    _registered = true;
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = context.watch<TaskBoardController>();
    if (board.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 3 columns side-by-side on tablets/desktop; horizontally scrollable
        // on phones.
        final isWide = constraints.maxWidth >= 900;
        final columnWidth = isWide
            ? (constraints.maxWidth - 16 * 4) / 3
            : (constraints.maxWidth * 0.82).clamp(280.0, 380.0);

        return Scrollbar(
          controller: _hScroll,
          child: SingleChildScrollView(
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            physics: isWide
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: isWide ? constraints.maxWidth - 32 : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < TaskStatus.values.length; i++) ...[
                    SizedBox(
                      width: columnWidth,
                      child: TaskColumn(
                        status: TaskStatus.values[i],
                        onTapTask: (t) =>
                            TaskDetailSheet.show(context, t.id),
                        onTapAdd: () => TaskEditorSheet.show(context),
                      ),
                    ),
                    if (i != TaskStatus.values.length - 1)
                      const SizedBox(width: 12),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

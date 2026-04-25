import 'package:flutter_test/flutter_test.dart';

import 'package:untitled2/core/notifications.dart';
import 'package:untitled2/features/task_board/data/in_memory_task_repository.dart';
import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/presentation/task_board_controller.dart';

/// Builds a controller with a clean (unseeded) repo so each test starts
/// from a known empty state.
Future<TaskBoardController> _emptyController() async {
  final c = TaskBoardController(
    repository: InMemoryTaskRepository(seed: false),
    notifications: InAppNotificationService(),
  );
  // The controller bootstraps via async load; pump until ready.
  while (c.loading) {
    await Future<void>.delayed(Duration.zero);
  }
  return c;
}

void main() {
  group('TaskBoardController', () {
    test('createTask lands in To Do at index 0', () async {
      final c = await _emptyController();
      await c.createTask(
        title: 'A',
        description: '',
        priority: TaskPriority.low,
      );
      expect(c.column(TaskStatus.todo).map((t) => t.title), ['A']);
      expect(c.column(TaskStatus.inProgress), isEmpty);
    });

    test('moveTask across columns updates status and clamps the index',
        () async {
      final c = await _emptyController();
      final a = await c.createTask(
        title: 'A',
        description: '',
        priority: TaskPriority.low,
      );

      await c.moveTask(
        taskId: a.id,
        toStatus: TaskStatus.done,
        toIndex: 999, // out of bounds — must clamp
      );

      expect(c.column(TaskStatus.todo), isEmpty);
      final done = c.column(TaskStatus.done);
      expect(done.length, 1);
      expect(done.first.id, a.id);
      expect(done.first.status, TaskStatus.done);
      expect(
        done.first.activity.last.kind,
        ActivityKind.moved,
        reason: 'cross-column move should append a "moved" activity entry',
      );
    });

    test(
      'moveTask within a column adjusts for the source index shift',
      () async {
        // Insertion at index N from a position before N should land at N-1
        // because the source element was removed first. This is the classic
        // ReorderableListView off-by-one.
        final c = await _emptyController();
        final a = await c.createTask(
          title: 'A', description: '', priority: TaskPriority.low,
        );
        final b = await c.createTask(
          title: 'B', description: '', priority: TaskPriority.low,
        );
        final cc = await c.createTask(
          title: 'C', description: '', priority: TaskPriority.low,
        );
        // Order in todo (createTask inserts at 0): C, B, A
        expect(
          c.column(TaskStatus.todo).map((t) => t.title).toList(),
          ['C', 'B', 'A'],
        );

        // Move C (index 0) "to index 2" — visually after B, before A.
        await c.moveTask(
          taskId: cc.id,
          toStatus: TaskStatus.todo,
          toIndex: 2,
        );

        expect(
          c.column(TaskStatus.todo).map((t) => t.title).toList(),
          ['B', 'C', 'A'],
        );

        // Sanity: ids preserved.
        expect(c.findById(a.id)?.title, 'A');
        expect(c.findById(b.id)?.title, 'B');
      },
    );

    test('addComment appends comment + activity entry', () async {
      final c = await _emptyController();
      final a = await c.createTask(
        title: 'A', description: '', priority: TaskPriority.low,
      );
      await c.addComment(taskId: a.id, author: 'Sam', body: 'looks good');
      final after = c.findById(a.id)!;
      expect(after.comments.length, 1);
      expect(after.comments.first.author, 'Sam');
      expect(after.activity.last.kind, ActivityKind.commented);
    });

    test('editTask logs priority + due-date changes as separate activity',
        () async {
      final c = await _emptyController();
      final a = await c.createTask(
        title: 'A', description: '', priority: TaskPriority.low,
      );
      final due = DateTime.now().add(const Duration(days: 2));
      await c.editTask(
        taskId: a.id,
        title: 'A2',
        description: 'desc',
        priority: TaskPriority.high,
        dueDate: due,
      );
      final t = c.findById(a.id)!;
      final kinds = t.activity.map((e) => e.kind).toList();
      expect(kinds, contains(ActivityKind.edited));
      expect(kinds, contains(ActivityKind.prioritized));
      expect(kinds, contains(ActivityKind.scheduled));
      expect(t.title, 'A2');
      expect(t.priority, TaskPriority.high);
      expect(t.dueDate, due);
    });

    test('deleteTask removes from board', () async {
      final c = await _emptyController();
      final a = await c.createTask(
        title: 'A', description: '', priority: TaskPriority.low,
      );
      await c.deleteTask(a.id);
      expect(c.findById(a.id), isNull);
      for (final s in TaskStatus.values) {
        expect(c.column(s), isEmpty);
      }
    });

    test('createTask with due date schedules a notification', () async {
      final notifier = InAppNotificationService();
      final c = TaskBoardController(
        repository: InMemoryTaskRepository(seed: false),
        notifications: notifier,
      );
      while (c.loading) {
        await Future<void>.delayed(Duration.zero);
      }
      final due = DateTime.now().add(const Duration(hours: 3));
      final t = await c.createTask(
        title: 'Pickup',
        description: '',
        priority: TaskPriority.medium,
        dueDate: due,
      );
      expect(notifier.debugScheduled[t.id], due);
    });
  });
}

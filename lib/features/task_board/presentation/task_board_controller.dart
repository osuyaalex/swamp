import 'package:flutter/foundation.dart';

import 'package:untitled2/core/id.dart';
import 'package:untitled2/core/notifications.dart';
import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/domain/repositories/task_repository.dart';

class TaskBoardController extends ChangeNotifier {
  TaskBoardController({
    required TaskRepository repository,
    required NotificationService notifications,
  })  : _repo = repository,
        _notifier = notifications {
    _bootstrap();
  }

  final TaskRepository _repo;
  final NotificationService _notifier;

  bool _loading = true;
  bool get loading => _loading;

  final Map<TaskStatus, List<Task>> _columns = {
    for (final s in TaskStatus.values) s: <Task>[],
  };

  /// Read-only column view used by the UI.
  List<Task> column(TaskStatus status) =>
      List.unmodifiable(_columns[status]!);

  int countIn(TaskStatus status) => _columns[status]!.length;

  Task? findById(String id) {
    for (final list in _columns.values) {
      for (final t in list) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  Future<void> _bootstrap() async {
    final all = await _repo.loadAll();
    for (final list in _columns.values) {
      list.clear();
    }
    for (final t in all) {
      _columns[t.status]!.add(t);
    }
    _loading = false;
    notifyListeners();
  }

  // ------------------------------- CRUD ----------------------------------

  Future<Task> createTask({
    required String title,
    required String description,
    required TaskPriority priority,
    DateTime? dueDate,
  }) async {
    final task = await _repo.create(
      title: title,
      description: description,
      priority: priority,
      dueDate: dueDate,
    );
    _columns[task.status]!.insert(0, task);
    if (dueDate != null) {
      await _notifier.scheduleForTask(
        taskId: task.id,
        title: task.title,
        at: dueDate,
      );
    }
    notifyListeners();
    return task;
  }

  Future<Task> editTask({
    required String taskId,
    required String title,
    required String description,
    required TaskPriority priority,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    final current = findById(taskId);
    if (current == null) {
      throw StateError('Unknown task: $taskId');
    }
    final priorityChanged = current.priority != priority;
    final dueChanged = clearDueDate
        ? current.dueDate != null
        : (dueDate != null && current.dueDate != dueDate);

    final activity = <ActivityEntry>[
      ...current.activity,
      ActivityEntry(
        id: IdGen.next('act'),
        kind: ActivityKind.edited,
        message: 'Task edited',
        at: DateTime.now(),
      ),
      if (priorityChanged)
        ActivityEntry(
          id: IdGen.next('act'),
          kind: ActivityKind.prioritized,
          message: 'Priority → ${priority.label}',
          at: DateTime.now(),
        ),
      if (dueChanged)
        ActivityEntry(
          id: IdGen.next('act'),
          kind: ActivityKind.scheduled,
          message: clearDueDate ? 'Due date cleared' : 'Due date updated',
          at: DateTime.now(),
        ),
    ];

    final next = current.copyWith(
      title: title,
      description: description,
      priority: priority,
      dueDate: dueDate,
      clearDueDate: clearDueDate,
      activity: activity,
    );
    await _repo.update(next);
    _replaceLocal(next);

    if (clearDueDate) {
      await _notifier.cancelForTask(taskId);
    } else if (dueChanged && dueDate != null) {
      await _notifier.scheduleForTask(
        taskId: taskId,
        title: title,
        at: dueDate,
      );
    }

    notifyListeners();
    return next;
  }

  Future<void> deleteTask(String taskId) async {
    await _repo.delete(taskId);
    for (final list in _columns.values) {
      list.removeWhere((t) => t.id == taskId);
    }
    await _notifier.cancelForTask(taskId);
    notifyListeners();
  }

  // -------------------------- Drag operations ----------------------------

  /// Used by the drag layer once the user releases. Idempotent: if the task
  /// is already at `(toStatus, toIndex)` we still notify so any visual
  /// placeholder collapses cleanly.
  Future<void> moveTask({
    required String taskId,
    required TaskStatus toStatus,
    required int toIndex,
  }) async {
    final current = findById(taskId);
    if (current == null) return;

    final fromStatus = current.status;
    final fromList = _columns[fromStatus]!;
    final fromIndex = fromList.indexWhere((t) => t.id == taskId);

    if (fromStatus == toStatus) {
      // Account for index shift when moving down within the same column.
      final adjusted = (fromIndex < toIndex) ? toIndex - 1 : toIndex;
      if (adjusted == fromIndex) {
        notifyListeners();
        return;
      }
      final next = await _repo.reorderWithin(
        taskId: taskId,
        toIndex: adjusted,
      );
      fromList.removeAt(fromIndex);
      final clamped = adjusted.clamp(0, fromList.length);
      fromList.insert(clamped, next);
    } else {
      final next = await _repo.move(
        taskId: taskId,
        toStatus: toStatus,
        toIndex: toIndex,
      );
      fromList.removeAt(fromIndex);
      final dest = _columns[toStatus]!;
      final clamped = toIndex.clamp(0, dest.length);

      // Append a "moved" activity entry on the live task.
      final logged = next.copyWith(
        activity: [
          ...next.activity,
          ActivityEntry(
            id: IdGen.next('act'),
            kind: ActivityKind.moved,
            message: '${fromStatus.label} → ${toStatus.label}',
            at: DateTime.now(),
          ),
        ],
      );
      await _repo.update(logged);
      dest.insert(clamped, logged);
    }

    notifyListeners();
  }

  // ------------------------------ Comments -------------------------------

  Future<void> addComment({
    required String taskId,
    required String author,
    required String body,
  }) async {
    if (body.trim().isEmpty) return;
    final next = await _repo.addComment(
      taskId: taskId,
      author: author,
      body: body.trim(),
    );
    _replaceLocal(next);
    notifyListeners();
  }

  // ------------------------------ Internals ------------------------------

  void _replaceLocal(Task next) {
    for (final entry in _columns.entries) {
      final idx = entry.value.indexWhere((t) => t.id == next.id);
      if (idx >= 0) {
        if (entry.key == next.status) {
          entry.value[idx] = next;
        } else {
          entry.value.removeAt(idx);
          _columns[next.status]!.insert(0, next);
        }
        return;
      }
    }
  }
}

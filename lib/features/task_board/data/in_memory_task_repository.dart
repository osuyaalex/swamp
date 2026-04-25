import 'package:untitled2/core/id.dart';
import 'package:untitled2/features/task_board/domain/entities/task.dart';
import 'package:untitled2/features/task_board/domain/repositories/task_repository.dart';

class InMemoryTaskRepository implements TaskRepository {
  InMemoryTaskRepository({bool seed = true}) {
    if (seed) _seed();
  }

  final Map<TaskStatus, List<Task>> _byStatus = {
    TaskStatus.todo: <Task>[],
    TaskStatus.inProgress: <Task>[],
    TaskStatus.done: <Task>[],
  };

  @override
  Future<List<Task>> loadAll() async {
    return [
      for (final status in TaskStatus.values) ..._byStatus[status]!,
    ];
  }

  Task? _find(String taskId) {
    for (final list in _byStatus.values) {
      for (final t in list) {
        if (t.id == taskId) return t;
      }
    }
    return null;
  }

  void _replaceById(Task next) {
    final list = _byStatus[next.status]!;
    final idx = list.indexWhere((t) => t.id == next.id);
    if (idx >= 0) {
      list[idx] = next;
      return;
    }
    // Status changed — remove from old list first.
    for (final entry in _byStatus.entries) {
      final oldIdx = entry.value.indexWhere((t) => t.id == next.id);
      if (oldIdx >= 0) {
        entry.value.removeAt(oldIdx);
        break;
      }
    }
    list.add(next);
  }

  @override
  Future<Task> create({
    required String title,
    required String description,
    required TaskPriority priority,
    DateTime? dueDate,
  }) async {
    final now = DateTime.now();
    final task = Task(
      id: IdGen.next('task'),
      title: title,
      description: description,
      status: TaskStatus.todo,
      priority: priority,
      createdAt: now,
      dueDate: dueDate,
      activity: [
        ActivityEntry(
          id: IdGen.next('act'),
          kind: ActivityKind.created,
          message: 'Task created',
          at: now,
        ),
        if (dueDate != null)
          ActivityEntry(
            id: IdGen.next('act'),
            kind: ActivityKind.scheduled,
            message: 'Due date set',
            at: now,
          ),
      ],
    );
    _byStatus[TaskStatus.todo]!.insert(0, task);
    return task;
  }

  @override
  Future<Task> update(Task task) async {
    _replaceById(task);
    return task;
  }

  @override
  Future<void> delete(String taskId) async {
    for (final list in _byStatus.values) {
      list.removeWhere((t) => t.id == taskId);
    }
  }

  @override
  Future<Task> move({
    required String taskId,
    required TaskStatus toStatus,
    required int toIndex,
  }) async {
    final task = _find(taskId);
    if (task == null) {
      throw StateError('Unknown task: $taskId');
    }

    _byStatus[task.status]!.removeWhere((t) => t.id == taskId);
    final dest = _byStatus[toStatus]!;
    final clamped = toIndex.clamp(0, dest.length);
    final next = task.copyWith(status: toStatus);
    dest.insert(clamped, next);
    return next;
  }

  @override
  Future<Task> reorderWithin({
    required String taskId,
    required int toIndex,
  }) async {
    final task = _find(taskId);
    if (task == null) {
      throw StateError('Unknown task: $taskId');
    }
    final list = _byStatus[task.status]!;
    final from = list.indexWhere((t) => t.id == taskId);
    if (from < 0) return task;
    final removed = list.removeAt(from);
    final clamped = toIndex.clamp(0, list.length);
    list.insert(clamped, removed);
    return removed;
  }

  @override
  Future<Task> addComment({
    required String taskId,
    required String author,
    required String body,
  }) async {
    final task = _find(taskId);
    if (task == null) {
      throw StateError('Unknown task: $taskId');
    }
    final now = DateTime.now();
    final next = task.copyWith(
      comments: [
        ...task.comments,
        Comment(id: IdGen.next('c'), author: author, body: body, createdAt: now),
      ],
      activity: [
        ...task.activity,
        ActivityEntry(
          id: IdGen.next('act'),
          kind: ActivityKind.commented,
          message: '$author commented',
          at: now,
        ),
      ],
    );
    _replaceById(next);
    return next;
  }

  void _seed() {
    final now = DateTime.now();
    Task t({
      required String title,
      required String desc,
      required TaskStatus status,
      required TaskPriority priority,
      DateTime? due,
    }) {
      return Task(
        id: IdGen.next('task'),
        title: title,
        description: desc,
        status: status,
        priority: priority,
        createdAt: now,
        dueDate: due,
        activity: [
          ActivityEntry(
            id: IdGen.next('act'),
            kind: ActivityKind.created,
            message: 'Task created',
            at: now,
          ),
        ],
      );
    }

    _byStatus[TaskStatus.todo]!.addAll([
      t(
        title: 'Audit waste collection routes',
        desc:
            'Cross-reference **last quarter** truck telemetry against the '
            'reported pickup logs. Flag any *gaps* over 24h.',
        status: TaskStatus.todo,
        priority: TaskPriority.high,
        due: now.add(const Duration(days: 2)),
      ),
      t(
        title: 'Draft KYC compliance checklist',
        desc:
            'List every document type the verification flow must accept '
            'and the *minimum* fields each must surface.',
        status: TaskStatus.todo,
        priority: TaskPriority.medium,
      ),
      t(
        title: 'Review depot sensor firmware notes',
        desc: 'Quick read of vendor patch notes — flag anything affecting MQTT.',
        status: TaskStatus.todo,
        priority: TaskPriority.low,
      ),
    ]);

    _byStatus[TaskStatus.inProgress]!.addAll([
      t(
        title: 'Wire WebSocket reconnection backoff',
        desc:
            'Exponential backoff capped at 30s. Resume from last seen '
            '`documentId` cursor on reconnect.',
        status: TaskStatus.inProgress,
        priority: TaskPriority.urgent,
        due: now.add(const Duration(days: 1)),
      ),
      t(
        title: 'Spike: image quality validation',
        desc: 'Compare laplacian-variance vs. perceptual-hash for blur detection.',
        status: TaskStatus.inProgress,
        priority: TaskPriority.medium,
      ),
    ]);

    _byStatus[TaskStatus.done]!.addAll([
      t(
        title: 'Bootstrap project + theme',
        desc: 'Provider + screenutil wired, brand palette applied.',
        status: TaskStatus.done,
        priority: TaskPriority.low,
      ),
    ]);
  }
}

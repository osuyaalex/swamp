import '../entities/task.dart';

abstract class TaskRepository {
  Future<List<Task>> loadAll();

  Future<Task> create({
    required String title,
    required String description,
    required TaskPriority priority,
    DateTime? dueDate,
  });

  Future<Task> update(Task task);

  Future<void> delete(String taskId);

  Future<Task> move({
    required String taskId,
    required TaskStatus toStatus,
    required int toIndex,
  });

  Future<Task> reorderWithin({
    required String taskId,
    required int toIndex,
  });

  Future<Task> addComment({
    required String taskId,
    required String author,
    required String body,
  });
}
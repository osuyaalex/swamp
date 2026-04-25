import 'package:flutter/material.dart';

enum TaskStatus { todo, inProgress, done }

extension TaskStatusX on TaskStatus {
  String get label => switch (this) {
        TaskStatus.todo => 'To Do',
        TaskStatus.inProgress => 'In Progress',
        TaskStatus.done => 'Done',
      };
}

enum TaskPriority { low, medium, high, urgent }

extension TaskPriorityX on TaskPriority {
  String get label => switch (this) {
        TaskPriority.low => 'Low',
        TaskPriority.medium => 'Medium',
        TaskPriority.high => 'High',
        TaskPriority.urgent => 'Urgent',
      };

  Color get color => switch (this) {
        TaskPriority.low => const Color(0xFF65A2FF),
        TaskPriority.medium => const Color(0xFFFFB547),
        TaskPriority.high => const Color(0xFFFF6E40),
        TaskPriority.urgent => const Color(0xFFE53935),
      };

  int get rank => index;
}

@immutable
class Comment {
  const Comment({
    required this.id,
    required this.author,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String author;
  final String body;
  final DateTime createdAt;
}

enum ActivityKind {
  created,
  edited,
  moved,
  prioritized,
  commented,
  scheduled,
  deleted,
}

@immutable
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.kind,
    required this.message,
    required this.at,
  });

  final String id;
  final ActivityKind kind;
  final String message;
  final DateTime at;
}

@immutable
class Task {
  const Task({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.priority,
    required this.createdAt,
    this.dueDate,
    this.comments = const [],
    this.activity = const [],
  });

  final String id;
  final String title;
  final String description;
  final TaskStatus status;
  final TaskPriority priority;
  final DateTime createdAt;
  final DateTime? dueDate;
  final List<Comment> comments;
  final List<ActivityEntry> activity;

  bool get isOverdue =>
      dueDate != null &&
      status != TaskStatus.done &&
      dueDate!.isBefore(DateTime.now());

  Task copyWith({
    String? title,
    String? description,
    TaskStatus? status,
    TaskPriority? priority,
    DateTime? dueDate,
    bool clearDueDate = false,
    List<Comment>? comments,
    List<ActivityEntry>? activity,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      createdAt: createdAt,
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      comments: comments ?? this.comments,
      activity: activity ?? this.activity,
    );
  }
}
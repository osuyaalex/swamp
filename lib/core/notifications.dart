import 'package:flutter/foundation.dart';

abstract class NotificationService {
  Future<void> scheduleForTask({
    required String taskId,
    required String title,
    required DateTime at,
  });

  Future<void> cancelForTask(String taskId);
}

/// Phase-1 placeholder. A production implementation would forward to
/// `flutter_local_notifications`/native; the interface is the seam where it
/// would slot in without touching domain or UI.
class InAppNotificationService implements NotificationService {
  final Map<String, DateTime> _scheduled = {};

  Map<String, DateTime> get debugScheduled => Map.unmodifiable(_scheduled);

  @override
  Future<void> scheduleForTask({
    required String taskId,
    required String title,
    required DateTime at,
  }) async {
    _scheduled[taskId] = at;
    if (kDebugMode) {
      debugPrint('[notify] scheduled "$title" for $at (task=$taskId)');
    }
  }

  @override
  Future<void> cancelForTask(String taskId) async {
    _scheduled.remove(taskId);
    if (kDebugMode) {
      debugPrint('[notify] cancelled task=$taskId');
    }
  }
}

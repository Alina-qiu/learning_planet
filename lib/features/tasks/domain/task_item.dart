import 'task.dart';

class TaskItem {
  const TaskItem({
    required this.id,
    required this.childId,
    required this.title,
    required this.status,
    required this.coinReward,
    required this.xpReward,
    required this.dueDate,
    required this.accumulatedSeconds,
    this.activeStartedAt,
    this.minimumSeconds = 0,
  });

  final String id;
  final String childId;
  final String title;
  final TaskStatus status;
  final int coinReward;
  final int xpReward;
  final DateTime dueDate;
  final int accumulatedSeconds;
  final DateTime? activeStartedAt;
  final int minimumSeconds;
  int elapsedSeconds(DateTime now) {
    final active = activeStartedAt;
    return accumulatedSeconds +
        (status == TaskStatus.inProgress && active != null
            ? now.difference(active).inSeconds.clamp(0, 2147483647)
            : 0);
  }
}

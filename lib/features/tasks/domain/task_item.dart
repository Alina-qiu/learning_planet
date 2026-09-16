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
  });

  final String id;
  final String childId;
  final String title;
  final TaskStatus status;
  final int coinReward;
  final int xpReward;
  final DateTime dueDate;
  final int accumulatedSeconds;
}

import '../../tasks/domain/task.dart';
import '../../tasks/domain/task_item.dart';

/// A presentation of the current task list, never a source of rewards or XP.
class TaskAdventure {
  const TaskAdventure({
    required this.total,
    required this.completed,
    required this.pending,
  });
  final int total, completed, pending;
  int get remaining => total - completed;
  double get energy => total == 0 ? 0 : remaining / total;
  factory TaskAdventure.fromTasks(
    Iterable<TaskItem> tasks, {
    required String childId,
    required DateTime familyDate,
    Set<String> pendingTaskIds = const {},
  }) {
    final today = DateTime(familyDate.year, familyDate.month, familyDate.day);
    var total = 0, completed = 0, pending = 0;
    final seen = <String>{};
    for (final task in tasks) {
      final day = DateTime(
        task.dueDate.year,
        task.dueDate.month,
        task.dueDate.day,
      );
      if (task.childId != childId ||
          day.isAfter(today) ||
          (task.isTerminal && day != today) ||
          !seen.add(task.id)) {
        continue;
      }
      total++;
      if (task.status == TaskStatus.completed) {
        completed++;
        if (pendingTaskIds.contains(task.id)) pending++;
      }
    }
    return TaskAdventure(total: total, completed: completed, pending: pending);
  }
}

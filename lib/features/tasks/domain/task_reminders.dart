import 'task_item.dart';
import 'schedule_config.dart';

/// Keep merged reminders for the remaining tasks, including future templates.
List<Map<String, dynamic>> filterTaskReminders(
  List<Map<String, dynamic>> reminders,
  List<TaskItem> tasks,
) {
  final terminal = tasks.where((task) => task.isTerminal).toList();
  return [for (final row in reminders) ..._filter(row, terminal)];
}

Iterable<Map<String, dynamic>> _filter(
  Map<String, dynamic> row,
  List<TaskItem> terminal,
) sync* {
  final entries = row['tasks'];
  if (entries is! List) {
    yield row;
    return;
  }
  final kept = entries
      .cast<Map<String, dynamic>>()
      .where(
        (entry) => !terminal.any(
          (task) =>
              entry['task_id'] == task.id ||
              task.templateId != null &&
                  entry['template_id'] == task.templateId &&
                  entry['due_date'] == scheduleDate(task.dueDate),
        ),
      )
      .toList();
  if (kept.isEmpty) return;
  final titles = kept.map((entry) => entry['title'] as String).toSet().toList()
    ..sort();
  yield {...row, 'tasks': kept, 'titles': titles.join('、')};
}

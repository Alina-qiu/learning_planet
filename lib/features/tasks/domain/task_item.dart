import 'task.dart';
import 'task_priority.dart';
import 'task_growth_category.dart';

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
    this.serverVersion = 0,
    this.sourceType = 'parent_template',
    this.taskKind = 'standard',
    this.priority = TaskPriority.recommended,
    this.growthCategory = TaskGrowthCategory.general,
    this.expectedMinutes,
    this.scheduledAt,
    this.dueAt,
    this.templateId,
    this.abandonedAt,
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
  final int serverVersion;
  final String sourceType;
  final String taskKind;
  final TaskPriority priority;
  final TaskGrowthCategory growthCategory;
  final int? expectedMinutes;
  final DateTime? scheduledAt, dueAt, abandonedAt;
  final String? templateId;
  bool get isTerminal => const {
    TaskStatus.completed,
    TaskStatus.skipped,
    TaskStatus.abandoned,
  }.contains(status);

  static List<TaskItem> ordered(Iterable<TaskItem> tasks) =>
      tasks.toList()..sort((a, b) {
        if (a.isTerminal != b.isTerminal) return a.isTerminal ? 1 : -1;
        final day = a.dueDate.compareTo(b.dueDate);
        if (day != 0) return day;
        final priority = a.priority.index.compareTo(b.priority.index);
        if (priority != 0) return priority;
        final time = (a.scheduledAt ?? a.dueDate).compareTo(
          b.scheduledAt ?? b.dueDate,
        );
        return time != 0 ? time : a.id.compareTo(b.id);
      });

  factory TaskItem.fromJson(Map<String, dynamic> row) => TaskItem(
    id: row['id'] as String,
    childId: row['child_id'] as String,
    title: row['title'] as String,
    status: switch (row['status']) {
      'in_progress' => TaskStatus.inProgress,
      'expired' => TaskStatus.skipped,
      final String value => TaskStatus.values.byName(value),
      _ => throw const FormatException('Invalid task status'),
    },
    coinReward: row['coin_reward'] as int,
    xpReward: row['xp_reward'] as int,
    dueDate: DateTime.parse(row['due_date'] as String),
    accumulatedSeconds: row['accumulated_seconds'] as int,
    minimumSeconds: row['minimum_seconds'] as int,
    serverVersion: (row['sync_version'] as num?)?.toInt() ?? 0,
    sourceType: row['source_type'] as String? ?? 'parent_template',
    taskKind: row['task_kind'] as String? ?? 'standard',
    priority: TaskPriority.parse(
      row['task_priority'] as String? ??
          (row['task_kind'] == 'challenge' ? 'challenge' : null),
    ),
    expectedMinutes: row['expected_minutes'] as int?,
    growthCategory: TaskGrowthCategory.parse(row['growth_category'] as String?),
    scheduledAt: _date(row['scheduled_at']),
    dueAt: _date(row['due_at']),
    templateId: row['template_id'] as String?,
    abandonedAt: _date(row['abandoned_at']),
    activeStartedAt: row['active_started_at'] == null
        ? null
        : DateTime.parse(row['active_started_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'child_id': childId,
    'title': title,
    'status': status == TaskStatus.inProgress ? 'in_progress' : status.name,
    'coin_reward': coinReward,
    'xp_reward': xpReward,
    'due_date': dueDate.toIso8601String(),
    'accumulated_seconds': accumulatedSeconds,
    'minimum_seconds': minimumSeconds,
    'sync_version': serverVersion,
    'source_type': sourceType,
    'task_kind': taskKind,
    'task_priority': priority.value,
    'growth_category': growthCategory.name,
    'expected_minutes': expectedMinutes,
    'scheduled_at': scheduledAt?.toIso8601String(),
    'due_at': dueAt?.toIso8601String(),
    'template_id': templateId,
    'abandoned_at': abandonedAt?.toIso8601String(),
    'active_started_at': activeStartedAt?.toIso8601String(),
  };

  int elapsedSeconds(DateTime now) {
    final active = activeStartedAt;
    return accumulatedSeconds +
        (status == TaskStatus.inProgress && active != null
            ? now.difference(active).inSeconds.clamp(0, 2147483647)
            : 0);
  }

  static DateTime? _date(dynamic value) =>
      value == null ? null : DateTime.parse(value as String);
}

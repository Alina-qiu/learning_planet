import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/application/task_start_provider.dart';
import '../../tasks/data/schedule_repository.dart';
import '../../tasks/domain/task.dart';
import '../../tasks/domain/task_item.dart';
import '../../tasks/domain/schedule_config.dart';
import '../../tasks/presentation/task_actions.dart';
import '../../tasks/presentation/task_presentation.dart';

class HomeTaskList extends ConsumerStatefulWidget {
  const HomeTaskList({
    required this.childId,
    required this.familyId,
    required this.onManageTasks,
    super.key,
  });
  final String childId, familyId;
  final VoidCallback onManageTasks;
  @override
  ConsumerState<HomeTaskList> createState() => _HomeTaskListState();
}

class _HomeTaskListState extends ConsumerState<HomeTaskList>
    with TaskActions<HomeTaskList> {
  @override
  String get childId => widget.childId;
  @override
  String get familyId => widget.familyId;

  @override
  Widget build(BuildContext context) {
    watchTaskFeedbackScope();
    final tasks = ref.watch(tasksProvider(childId));
    final familyToday = ref.watch(familyTodayProvider(childId));
    final origin = ref.watch(taskStartOriginProvider(familyId));
    final reminders = ref.watch(remindersProvider(childId));
    return tasks.when(
      data: (items) {
        if (familyToday.hasError) {
          return SliverToBoxAdapter(
            child: Text('家庭日期读取失败：${familyToday.error}'),
          );
        }
        final value = familyToday.value;
        if (value == null) {
          return const SliverToBoxAdapter(child: LinearProgressIndicator());
        }
        final today = DateUtils.dateOnly(value);
        final visible = items
            .where(
              (task) =>
                  !DateUtils.dateOnly(task.dueDate).isAfter(today) &&
                  (!task.isTerminal ||
                      DateUtils.isSameDay(task.dueDate, today)),
            )
            .toList();
        if (visible.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(24), child: Text('暂无到期任务')),
          );
        }
        final ordered = TaskItem.ordered(visible);
        final indices = {
          for (var i = 0; i < ordered.length; i++)
            'home-task:$childId:${ordered[i].id}': i,
        };
        return SliverList.builder(
          itemCount: ordered.length,
          findChildIndexCallback: (key) =>
              key is ValueKey<String> ? indices[key.value] : null,
          itemBuilder: (context, index) {
            final task = ordered[index];
            final review = task.sourceType == 'automatic_wrong_review';
            final record = review && task.isTerminal;
            final counting =
                task.status == TaskStatus.inProgress ||
                task.status == TaskStatus.paused;
            return Card(
              key: ValueKey('home-task:$childId:${task.id}'),
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TaskHeading(task: task),
                    if (task.status == TaskStatus.scheduled ||
                        task.status == TaskStatus.ready)
                      _BeforeStartStatus(
                        task: task,
                        today: today,
                        slots: reminders.asData?.value ?? const [],
                      ),
                    if (!review && counting) _TaskTimer(task: task),
                    Text(
                      task.status == TaskStatus.abandoned
                          ? '已放弃 · 保留有效时长，不扣已有奖励'
                          : review
                          ? '${record
                                ? task.status == TaskStatus.completed
                                      ? '已完成 · '
                                      : '已跳过 · '
                                : ''}自动错题/拼音复习 · 全部作答后按结果发奖${task.expectedMinutes == null ? '' : '\n目标 ${task.expectedMinutes} 分钟'}'
                          : '+${task.coinReward} 金币 · +${task.xpReward} XP',
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonal(
                          onPressed:
                              taskActionBusy || task.isTerminal && !review
                              ? null
                              : () => advanceTask(task),
                          child: Text(taskActionLabel(task, origin)),
                        ),
                        if (!review && counting)
                          FilledButton(
                            style: const ButtonStyle(enableFeedback: false),
                            onPressed: taskActionBusy
                                ? null
                                : () => completeTask(task),
                            child: const Text('完成'),
                          ),
                        if (!review)
                          TextButton(
                            onPressed: taskActionBusy
                                ? null
                                : widget.onManageTasks,
                            child: const Text('查看任务'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      loading: () => const SliverToBoxAdapter(child: LinearProgressIndicator()),
      error: (_, __) => const SliverToBoxAdapter(child: Text('任务读取失败，请下拉重试')),
    );
  }
}

class _TaskTimer extends ConsumerWidget {
  const _TaskTimer({required this.task});
  final TaskItem task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = task.status == TaskStatus.paused;
    final seconds = paused
        ? task.accumulatedSeconds
        : ref.watch(
            taskDisplayTimeProvider(
              task.childId,
            ).select((now) => now == null ? null : task.elapsedSeconds(now)),
          );
    if (seconds == null) return const Text('计时中 · 等待时间校准');
    String duration(int value) =>
        '${value ~/ 60}分${(value % 60).toString().padLeft(2, '0')}秒';
    final minimum = task.minimumSeconds > 0
        ? ' / 最低 ${duration(task.minimumSeconds)}'
        : '';
    return Text('${paused ? '已暂停' : '计时中'} · ${duration(seconds)}$minimum');
  }
}

class _BeforeStartStatus extends ConsumerWidget {
  const _BeforeStartStatus({
    required this.task,
    required this.today,
    required this.slots,
  });
  final DateTime today;
  final TaskItem task;
  final List<Map<String, dynamic>> slots;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (task.sourceType == 'automatic_wrong_review' ||
        !DateUtils.isSameDay(today, task.dueDate)) {
      return const Text('未开始');
    }
    // Use the enabled, unacknowledged reminders outside quiet hours. A slot
    // created before the instance may still reference its template and date.
    DateTime? earliest;
    for (final row in slots) {
      final at = DateTime.tryParse(row['remind_at'] as String? ?? '');
      final entries = row['tasks'];
      if (at == null ||
          entries is! List ||
          earliest != null && !at.isBefore(earliest)) {
        continue;
      }
      if (entries.whereType<Map>().any(
        (entry) =>
            entry['task_id'] == task.id ||
            entry['task_id'] == null &&
                task.templateId != null &&
                entry['template_id'] == task.templateId &&
                entry['due_date'] == scheduleDate(task.dueDate),
      )) {
        earliest = at;
      }
    }
    final firstReminder = earliest;
    if (firstReminder == null) return const Text('未开始');
    final due = task.dueAt;
    final soon = ref.watch(
      taskDisplayTimeProvider(task.childId).select((now) {
        return now != null &&
            !now.isBefore(firstReminder) &&
            (due == null || !now.isAfter(due));
      }),
    );
    return Text(soon ? '快开始啦' : '未开始');
  }
}

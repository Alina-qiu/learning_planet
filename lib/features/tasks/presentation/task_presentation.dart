import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../domain/task_item.dart';
import '../domain/task_priority.dart';

class TaskHeading extends StatelessWidget {
  const TaskHeading({required this.task, super.key});
  final TaskItem task;
  @override
  Widget build(BuildContext context) {
    final color = switch (task.priority) {
      TaskPriority.mandatory => Theme.of(context).colorScheme.primary,
      TaskPriority.recommended => Theme.of(context).colorScheme.secondary,
      TaskPriority.challenge => Theme.of(context).colorScheme.tertiary,
    };
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Text(
              task.priority.label,
              style: TextStyle(color: color, fontSize: 14),
            ),
          ),
        ),
        Text(task.title),
        Text(
          '成长分类：${task.growthCategory.label}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 14),
        ),
      ],
    );
  }
}

bool _zonesReady = false;
String taskWindow(TaskItem task, String? zone) {
  if (zone == null || task.scheduledAt == null || task.dueAt == null) return '';
  if (!_zonesReady) {
    tzdata.initializeTimeZones();
    _zonesReady = true;
  }
  String format(DateTime date) {
    final value = tz.TZDateTime.from(date, tz.getLocation(zone));
    return '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  return '建议开始 ${format(task.scheduledAt!)} · 截止 ${format(task.dueAt!)}（$zone）';
}

Future<bool> confirmTaskAbandon(
  BuildContext context, {
  required bool review,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃这次任务？'),
        content: Text(
          '保留已经计入的有效时长，停止这次提醒，不获得本任务的完成奖励，也不扣除已有金币或 XP。'
          '${review ? '已提交题目的判定和复习排期会保留；未作答的题仍待复习。' : '如果是误操作，家长可以填写原因补签。'}'
          '后续日期的重复任务不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认放弃'),
          ),
        ],
      ),
    ) ??
    false;

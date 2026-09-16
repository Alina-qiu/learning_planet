import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/task_providers.dart';
import '../domain/task.dart';
import '../domain/task_item.dart';

class TaskManagementScreen extends ConsumerWidget {
  const TaskManagementScreen({
    required this.childId,
    required this.childNickname,
    required this.isParentMode,
    super.key,
  });

  final String childId;
  final String childNickname;
  final bool isParentMode;

  Future<void> _manualComplete(
    BuildContext context,
    WidgetRef ref,
    TaskItem task,
  ) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('家长补签'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '补签原因（必填）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确认补签'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.isEmpty) return;
    await ref.read(taskRepositoryProvider).manualComplete(task.id, reason);
    ref.invalidate(tasksProvider(childId));
  }

  Future<void> _createTask(BuildContext context, WidgetRef ref) async {
    final titleController = TextEditingController();
    final coinController = TextEditingController(text: '20');
    final xpController = TextEditingController(text: '20');
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('给 $childNickname 创建任务'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: '任务名称'),
            ),
            TextField(
              controller: coinController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '金币奖励'),
            ),
            TextField(
              controller: xpController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'XP 奖励'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (created != true || titleController.text.trim().isEmpty) return;
    await ref.read(taskRepositoryProvider).createOneTimeTask(
          childId: childId,
          title: titleController.text.trim(),
          dueDate: DateTime.now(),
          coinReward: int.tryParse(coinController.text) ?? 0,
          xpReward: int.tryParse(xpController.text) ?? 0,
        );
    titleController.dispose();
    coinController.dispose();
    xpController.dispose();
    ref.invalidate(tasksProvider(childId));
  }

  Future<void> _transition(WidgetRef ref, TaskItem task) async {
    final repository = ref.read(taskRepositoryProvider);
    switch (task.status) {
      case TaskStatus.scheduled:
      case TaskStatus.ready:
        await repository.start(task.id);
      case TaskStatus.inProgress:
        await repository.pause(task.id);
      case TaskStatus.paused:
        await repository.resume(task.id);
      case TaskStatus.completed:
      case TaskStatus.skipped:
        return;
    }
    ref.invalidate(tasksProvider(childId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('$childNickname 的任务')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createTask(context, ref),
        icon: const Icon(Icons.add_task),
        label: const Text('新建任务'),
      ),
      body: ref.watch(tasksProvider(childId)).when(
            data: (tasks) => tasks.isEmpty
                ? const Center(child: Text('还没有任务'))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          title: Text(task.title),
                          subtitle: Text(
                            '+${task.coinReward} 金币 · +${task.xpReward} XP · '
                            '${task.accumulatedSeconds ~/ 60} 分钟',
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              if (task.status == TaskStatus.inProgress ||
                                  task.status == TaskStatus.paused)
                                IconButton(
                                  tooltip: '完成',
                                  onPressed: () async {
                                    await ref
                                        .read(taskRepositoryProvider)
                                        .complete(task.id);
                                    ref.invalidate(tasksProvider(childId));
                                  },
                                  icon: const Icon(Icons.task_alt),
                                ),
                              if (isParentMode &&
                                  task.status != TaskStatus.completed)
                                IconButton(
                                  tooltip: '家长补签',
                                  onPressed: () =>
                                      _manualComplete(context, ref, task),
                                  icon: const Icon(Icons.fact_check_outlined),
                                ),
                              FilledButton.tonal(
                                onPressed: task.status == TaskStatus.completed
                                    ? null
                                    : () => _transition(ref, task),
                                child: Text(_actionLabel(task.status)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Text('任务读取失败：$error'),
            ),
          ),
    );
  }

  static String _actionLabel(TaskStatus status) => switch (status) {
        TaskStatus.scheduled || TaskStatus.ready => '开始',
        TaskStatus.inProgress => '暂停',
        TaskStatus.paused => '继续',
        TaskStatus.completed => '已完成',
        TaskStatus.skipped => '已跳过',
      };
}

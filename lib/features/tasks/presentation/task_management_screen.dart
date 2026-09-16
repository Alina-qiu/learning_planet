import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../application/task_providers.dart';
import '../data/schedule_repository.dart';
import '../domain/task.dart';
import '../domain/task_item.dart';
import 'schedule_management_screen.dart';

class TaskManagementScreen extends ConsumerStatefulWidget {
  const TaskManagementScreen({
    required this.childId,
    required this.childNickname,
    required this.isParentMode,
    this.familyId,
    super.key,
  });
  final String childId, childNickname;
  // Kept for constructor compatibility; authority is always read dynamically.
  final bool isParentMode;
  final String? familyId;
  @override
  ConsumerState<TaskManagementScreen> createState() =>
      _TaskManagementScreenState();
}

class _TaskManagementScreenState extends ConsumerState<TaskManagementScreen> {
  bool _busy = false;
  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
      if (!mounted) return;
      ref.invalidate(tasksProvider(widget.childId));
      ref.invalidate(walletProvider(widget.childId));
      ref.invalidate(remindersProvider(widget.childId));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manualComplete(TaskItem task) => _perform(() async {
    var input = '';
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('家长补签'),
        content: TextField(
          onChanged: (v) => input = v,
          decoration: const InputDecoration(labelText: '补签原因（必填）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.trim()),
            child: const Text('确认补签'),
          ),
        ],
      ),
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长授权已到期');
    }
    await ref.read(taskRepositoryProvider).manualComplete(task.id, reason);
  });
  Future<void> _transition(TaskItem task) => _perform(() async {
    final repository = ref.read(taskRepositoryProvider);
    switch (task.status) {
      case TaskStatus.ready:
      case TaskStatus.scheduled:
        await repository.start(task.id);
      case TaskStatus.inProgress:
        await repository.pause(task.id);
      case TaskStatus.paused:
        await repository.resume(task.id);
      case TaskStatus.completed:
      case TaskStatus.skipped:
        return;
    }
  });
  Future<void> _schedules() async {
    if (widget.familyId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScheduleManagementScreen(
          childId: widget.childId,
          familyId: widget.familyId!,
        ),
      ),
    );
    if (!mounted) return;
    ref.invalidate(tasksProvider(widget.childId));
    ref.invalidate(walletProvider(widget.childId));
  }

  @override
  Widget build(BuildContext context) {
    final authorized =
        widget.familyId != null &&
        ref.watch(activeParentFamilyProvider) == widget.familyId;
    final now = ref.watch(authorizationClockProvider).value ?? DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.childNickname} 的任务'),
        actions: [
          if (widget.familyId != null)
            IconButton(
              tooltip: '周期模板、长期计划与提醒',
              onPressed: _busy ? null : _schedules,
              icon: const Icon(Icons.event_repeat),
            ),
        ],
      ),
      floatingActionButton: authorized
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _schedules,
              icon: const Icon(Icons.add_task),
              label: const Text('新建任务'),
            )
          : null,
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ref
                .watch(tasksProvider(widget.childId))
                .when(
                  data: (tasks) => RefreshIndicator(
                    onRefresh: () async {
                      ref.invalidate(tasksProvider(widget.childId));
                      await ref.read(tasksProvider(widget.childId).future);
                    },
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (tasks.isEmpty) const Center(child: Text('还没有任务')),
                        for (final task in tasks)
                          Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              title: Text(task.title),
                              subtitle: Text(
                                '+${task.coinReward} 金币 · +${task.xpReward} XP · '
                                '${task.elapsedSeconds(now) ~/ 60} 分钟 / 最低 ${(task.minimumSeconds / 60).ceil()} 分钟',
                              ),
                              trailing: Wrap(
                                spacing: 8,
                                children: [
                                  if (task.status == TaskStatus.inProgress ||
                                      task.status == TaskStatus.paused)
                                    IconButton(
                                      tooltip: '完成',
                                      onPressed: _busy
                                          ? null
                                          : () => _perform(
                                              () => ref
                                                  .read(taskRepositoryProvider)
                                                  .complete(task.id),
                                            ),
                                      icon: const Icon(Icons.task_alt),
                                    ),
                                  if (authorized &&
                                      task.status != TaskStatus.completed &&
                                      task.status != TaskStatus.skipped)
                                    IconButton(
                                      tooltip: '家长补签',
                                      onPressed: _busy
                                          ? null
                                          : () => _manualComplete(task),
                                      icon: const Icon(
                                        Icons.fact_check_outlined,
                                      ),
                                    ),
                                  FilledButton.tonal(
                                    onPressed:
                                        _busy ||
                                            task.status ==
                                                TaskStatus.completed ||
                                            task.status == TaskStatus.skipped
                                        ? null
                                        : () => _transition(task),
                                    child: Text(switch (task.status) {
                                      TaskStatus.scheduled ||
                                      TaskStatus.ready => '开始',
                                      TaskStatus.inProgress => '暂停',
                                      TaskStatus.paused => '继续',
                                      TaskStatus.completed => '已完成',
                                      TaskStatus.skipped => '已跳过',
                                    }),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(child: Text('任务读取失败：$error')),
                ),
          ),
        ],
      ),
    );
  }
}

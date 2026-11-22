import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../growth/presentation/task_feedback.dart';
import '../../wrong_questions/presentation/review_session_screen.dart';
import '../application/task_providers.dart';
import '../application/task_start_provider.dart';
import '../data/offline_task_repository.dart';
import '../data/schedule_repository.dart';
import '../data/task_repository.dart';
import '../domain/task.dart';
import '../domain/task_item.dart';
import '../domain/task_start_origin.dart';

/// Keep the action on the screen so completion feedback survives a reordered row.
mixin TaskActions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get childId;
  String? get familyId;
  bool _busy = false;
  bool get taskActionBusy => _busy;
  final _celebratedTasks = <String>{};

  Future<void> runTaskAction(Future<void> Function() action) async {
    if (_busy) return;
    final child = childId;
    final repository = ref.read(taskRepositoryProvider);
    bool current() =>
        child == childId &&
        identical(repository, ref.read(taskRepositoryProvider));
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted || !current()) return;
      ref.invalidate(tasksProvider(child));
      ref.invalidate(walletProvider(child));
      ref.invalidate(remindersProvider(child));
    } catch (error) {
      if (mounted && current()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> completeTask(TaskItem task) => runTaskAction(() async {
    final repository = ref.read(taskRepositoryProvider);
    await repository.complete(task.id);
    if (!mounted ||
        childId != task.childId ||
        !identical(repository, ref.read(taskRepositoryProvider)) ||
        !_celebratedTasks.add(task.id)) {
      return;
    }
    showTaskCompletionFeedback(
      context,
      ref,
      pending: repository is OfflineTaskRepository,
    );
  });

  Future<void> advanceTask(TaskItem task) => runTaskAction(() async {
    if (task.sourceType == 'automatic_wrong_review') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReviewSessionScreen(
            taskId: task.id,
            childId: task.childId,
            familyId: familyId,
          ),
        ),
      );
      return;
    }
    final repository = ref.read(taskRepositoryProvider);
    switch (task.status) {
      case TaskStatus.ready:
      case TaskStatus.scheduled:
        await startTaskWithOrigin(
          repository,
          task.id,
          ref.read(taskStartOriginProvider(familyId)),
        );
      case TaskStatus.inProgress:
        await repository.pause(task.id);
      case TaskStatus.paused:
        await repository.resume(task.id);
      case TaskStatus.completed:
      case TaskStatus.skipped:
      case TaskStatus.abandoned:
        return;
    }
  });
}

String taskActionLabel(TaskItem task, TaskStartOrigin origin) {
  if (task.sourceType == 'automatic_wrong_review') {
    return task.isTerminal ? '查看记录' : '去复习';
  }
  return switch (task.status) {
    TaskStatus.ready || TaskStatus.scheduled =>
      origin == TaskStartOrigin.parentAssisted ? '家长代开始' : '开始',
    TaskStatus.inProgress => '暂停',
    TaskStatus.paused => '继续',
    TaskStatus.completed => '已完成',
    TaskStatus.skipped => '已跳过',
    TaskStatus.abandoned => '已放弃',
  };
}

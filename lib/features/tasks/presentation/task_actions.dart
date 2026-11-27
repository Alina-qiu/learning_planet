import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/auth_providers.dart';
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

typedef _TaskScope = ({
  TaskRepository repository,
  String? owner,
  String? sessionOwner,
  String child,
  String? family,
});

/// Keep the action on the screen so completion feedback survives a reordered row.
mixin TaskActions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get childId;
  String? get familyId;
  final _feedback = TaskFeedbackPresenter();
  final _celebratedTasks = <String>{};
  _TaskScope? _scope;
  Object? _activeAction;
  String? _lastTask;
  bool get taskActionBusy => _activeAction != null;

  _TaskScope get _currentScope {
    final repository = ref.read(taskRepositoryProvider);
    final owner = repository is OfflineTaskRepository
        ? repository.accountId()
        : taskSupabaseClient(repository)?.auth.currentUser?.id;
    return (
      repository: repository,
      owner: owner,
      sessionOwner: ref.read(authAccountIdProvider),
      child: childId,
      family: familyId,
    );
  }

  void watchTaskFeedbackScope() {
    ref.watch(authAccountIdProvider);
    ref.watch(taskRepositoryProvider);
    final scope = _currentScope;
    if (_scope != scope) {
      _feedback.clear();
      _celebratedTasks.clear();
      _activeAction = null;
      _lastTask = null;
      _scope = scope;
    }
    if (ModalRoute.isCurrentOf(context) == false) _feedback.clear();
  }

  @override
  void dispose() {
    _feedback.clear();
    super.dispose();
  }

  Future<void> runTaskAction(
    TaskItem task,
    Future<void> Function() action, {
    VoidCallback? onSuccess,
  }) async {
    if (taskActionBusy || task.childId != childId) return;
    final scope = _currentScope;
    final actionId = Object();
    final child = childId;
    bool current() =>
        identical(_activeAction, actionId) && _currentScope == scope;
    if (_lastTask != task.id) {
      _feedback.clear();
    } else {
      _feedback.clearError();
    }
    _lastTask = task.id;
    setState(() => _activeAction = actionId);
    try {
      await action();
      if (!mounted || !current()) return;
      onSuccess?.call();
      ref.invalidate(tasksProvider(child));
      ref.invalidate(walletProvider(child));
      ref.invalidate(remindersProvider(child));
    } catch (error) {
      if (mounted && current()) {
        _feedback.error(context, '操作失败：$error');
      }
    } finally {
      if (mounted && identical(_activeAction, actionId)) {
        setState(() => _activeAction = null);
      }
    }
  }

  Future<void> completeTask(TaskItem task) {
    final repository = ref.read(taskRepositoryProvider);
    return runTaskAction(
      task,
      () => repository.complete(task.id),
      onSuccess: () {
        if (_celebratedTasks.add(task.id)) {
          _feedback.complete(
            context,
            ref,
            pending: repository is OfflineTaskRepository,
          );
        }
      },
    );
  }

  Future<void> advanceTask(TaskItem task) => runTaskAction(task, () async {
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

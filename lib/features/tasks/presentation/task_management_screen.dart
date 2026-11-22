import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../application/task_providers.dart';
import '../application/task_start_provider.dart';
import '../data/offline_task_repository.dart';
import '../domain/task.dart';
import '../domain/task_item.dart';
import 'schedule_management_screen.dart';
import 'task_sync_banner.dart';
import 'task_presentation.dart';
import 'task_actions.dart';
import 'task_note_screen.dart';
import 'task_time_correction_screen.dart';
import '../../reports/data/report_repository.dart';
import '../../growth/data/feedback_preferences.dart';
import '../../wrong_questions/data/review_repository.dart';
import '../../wrong_questions/presentation/review_hub_screen.dart';

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

class _TaskManagementScreenState extends ConsumerState<TaskManagementScreen>
    with TaskActions<TaskManagementScreen> {
  @override
  String get childId => widget.childId;
  @override
  String? get familyId => widget.familyId;
  Future<void> _manualComplete(TaskItem task) => runTaskAction(() async {
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
  Future<void> _correctTime(TaskItem task) => runTaskAction(() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskTimeCorrectionScreen(
          scope: (
            taskId: task.id,
            childId: widget.childId,
            familyId: widget.familyId!,
          ),
          title: task.title,
        ),
      ),
    );
    if (!mounted) return;
    final repository = ref.read(taskRepositoryProvider);
    if (repository is OfflineTaskRepository) {
      await repository.synchronize(widget.childId);
    }
    if (mounted) ref.invalidate(learningReportProvider);
  });
  Future<void> _abandon(TaskItem task) => runTaskAction(() async {
    if (!await confirmTaskAbandon(
          context,
          review: task.sourceType == 'automatic_wrong_review',
        ) ||
        !mounted) {
      return;
    }
    await ref.read(taskRepositoryProvider).abandon(task.id);
    ref.invalidate(reviewTaskProvider(task.id));
    ref.invalidate(reviewOverviewProvider(widget.childId));
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
    ref.watch(feedbackPreferencesProvider);
    final origin = ref.watch(taskStartOriginProvider(widget.familyId));
    final authorized =
        widget.familyId != null &&
        ref.watch(activeParentFamilyProvider) == widget.familyId;
    final now = ref.watch(taskDisplayTimeProvider(widget.childId));
    final zone = ref
        .watch(familiesProvider)
        .valueOrNull
        ?.where((f) => f.id == widget.familyId)
        .firstOrNull
        ?.timezone;
    final pending =
        ref.watch(taskSyncStateProvider).valueOrNull?.pendingTaskIds ??
        const <String>{};
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.childNickname} 的任务'),
        actions: [
          if (widget.familyId != null)
            IconButton(
              tooltip: '错题与拼音复习',
              icon: const Icon(Icons.school_outlined),
              onPressed: taskActionBusy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ReviewHubScreen(
                          childId: widget.childId,
                          familyId: widget.familyId!,
                        ),
                      ),
                    ),
            ),
          if (widget.familyId != null)
            IconButton(
              tooltip: '周期模板、长期计划与提醒',
              onPressed: taskActionBusy ? null : _schedules,
              icon: const Icon(Icons.event_repeat),
            ),
        ],
      ),
      floatingActionButton: authorized
          ? FloatingActionButton.extended(
              onPressed: taskActionBusy ? null : _schedules,
              icon: const Icon(Icons.add_task),
              label: const Text('新建任务'),
            )
          : null,
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(tasksProvider(widget.childId));
            await ref.read(tasksProvider(widget.childId).future);
          },
          child: CustomScrollView(
            key: PageStorageKey('tasks:${widget.childId}'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: TaskSyncBanner(childId: widget.childId),
              ),
              if (taskActionBusy)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              ref
                  .watch(tasksProvider(widget.childId))
                  .when(
                    data: (tasks) {
                      final ordered = TaskItem.ordered(tasks);
                      final indices = {
                        for (var i = 0; i < ordered.length; i++)
                          'task:${widget.childId}:${ordered[i].id}': i,
                      };
                      return SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                        sliver: SliverList.builder(
                          itemCount: ordered.isEmpty ? 1 : ordered.length,
                          findChildIndexCallback: (key) =>
                              key is ValueKey<String>
                              ? indices[key.value]
                              : null,
                          itemBuilder: (context, index) {
                            if (ordered.isEmpty) {
                              return const Center(child: Text('还没有任务'));
                            }
                            final task = ordered[index];
                            final elapsed = now != null
                                ? task.elapsedSeconds(now)
                                : task.status == TaskStatus.inProgress
                                ? null
                                : task.accumulatedSeconds;
                            final review =
                                task.sourceType == 'automatic_wrong_review';
                            final record = review && task.isTerminal;
                            return Card(
                              key: ValueKey(
                                'task:${widget.childId}:${task.id}',
                              ),
                              margin: const EdgeInsets.only(bottom: 10),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TaskHeading(task: task),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${record && task.status == TaskStatus.completed
                                          ? '已完成\n'
                                          : record && task.status == TaskStatus.skipped
                                          ? '已跳过\n'
                                          : ''}'
                                      '${task.status == TaskStatus.abandoned ? '' : '完成奖励 +${task.coinReward} 金币 · +${task.xpReward} XP\n'}'
                                      '${elapsed == null ? '等待时间校准' : '${elapsed ~/ 60} 分钟'} / 最低 ${(task.minimumSeconds / 60).ceil()} 分钟'
                                      '${task.expectedMinutes == null ? '' : '\n目标 ${task.expectedMinutes} 分钟（超时不扣分）'}'
                                      '${taskWindow(task, zone).isEmpty ? '' : '\n${taskWindow(task, zone)}'}'
                                      '${task.status == TaskStatus.abandoned ? '\n已放弃 · 保留计时，不发放完成奖励' : ''}'
                                      '${pending.contains(task.id) ? '\n已保存本机 · 待同步确认' : ''}',
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        if (widget.familyId != null)
                                          IconButton(
                                            tooltip: '补充说明',
                                            onPressed: taskActionBusy
                                                ? null
                                                : () => Navigator.of(context).push(
                                                    MaterialPageRoute<void>(
                                                      builder: (_) =>
                                                          TaskNoteScreen(
                                                            scope: (
                                                              taskId: task.id,
                                                              childId: widget
                                                                  .childId,
                                                              familyId: widget
                                                                  .familyId!,
                                                            ),
                                                            title: task.title,
                                                          ),
                                                    ),
                                                  ),
                                            icon: const Icon(
                                              Icons.notes_outlined,
                                            ),
                                          ),
                                        if (!task.isTerminal)
                                          IconButton(
                                            tooltip: '放弃任务',
                                            onPressed: taskActionBusy
                                                ? null
                                                : () => _abandon(task),
                                            icon: const Icon(
                                              Icons.stop_circle_outlined,
                                            ),
                                          ),
                                        if (authorized &&
                                            widget.familyId != null)
                                          IconButton(
                                            tooltip: '家长纠正计时',
                                            onPressed: taskActionBusy
                                                ? null
                                                : () => _correctTime(task),
                                            icon: const Icon(Icons.more_time),
                                          ),
                                        if (task.sourceType !=
                                                'automatic_wrong_review' &&
                                            (task.status ==
                                                    TaskStatus.inProgress ||
                                                task.status ==
                                                    TaskStatus.paused))
                                          IconButton(
                                            tooltip: '完成',
                                            enableFeedback: false,
                                            onPressed: taskActionBusy
                                                ? null
                                                : () => completeTask(task),
                                            icon: const Icon(Icons.task_alt),
                                          ),
                                        if (authorized &&
                                            task.sourceType !=
                                                'automatic_wrong_review' &&
                                            task.status !=
                                                TaskStatus.completed &&
                                            task.status != TaskStatus.skipped)
                                          IconButton(
                                            tooltip: '家长补签',
                                            onPressed: taskActionBusy
                                                ? null
                                                : () => _manualComplete(task),
                                            icon: const Icon(
                                              Icons.fact_check_outlined,
                                            ),
                                          ),
                                        FilledButton.tonal(
                                          onPressed:
                                              taskActionBusy ||
                                                  (task.isTerminal && !review)
                                              ? null
                                              : () => advanceTask(task),
                                          child: Text(
                                            taskActionLabel(task, origin),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                    loading: () => const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (error, _) => SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('任务读取失败：$error')),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

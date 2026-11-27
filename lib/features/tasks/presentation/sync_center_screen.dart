import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/presentation/parent_mode_prompt.dart';
import '../../wrong_questions/data/offline_question_media_repository.dart';
import '../../wrong_questions/data/question_media_repository.dart';
import '../../wrong_questions/presentation/image_drafts_screen.dart';
import '../../wrong_questions/presentation/review_session_screen.dart';
import '../application/task_providers.dart';
import '../data/offline_task_repository.dart';
import '../domain/sync_diagnostics.dart';
import '../domain/task.dart';
import '../domain/task_sync_state.dart';

final syncDiagnosticsProvider = FutureProvider.autoDispose
    .family<SyncDiagnostics, String>((ref, child) {
      ref.watch(taskSyncStateProvider);
      final repository = ref.watch(taskRepositoryProvider);
      if (repository is! OfflineTaskRepository) throw StateError('本机同步不可用');
      return repository.diagnostics(child);
    });

String _time(DateTime? at) =>
    at == null ? '暂无记录' : at.toLocal().toString().split('.').first;
String _status(TaskStatus status) => switch (status) {
  TaskStatus.scheduled => '未到开始时间',
  TaskStatus.ready => '未开始',
  TaskStatus.inProgress => '进行中',
  TaskStatus.paused => '已暂停',
  TaskStatus.completed => '已完成',
  TaskStatus.skipped => '已跳过',
  TaskStatus.abandoned => '已放弃',
};

class SyncCenterScreen extends ConsumerStatefulWidget {
  const SyncCenterScreen({required this.childId, super.key});
  final String childId;
  @override
  ConsumerState<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends ConsumerState<SyncCenterScreen> {
  String? _openedOwner;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final repository = ref.read(taskRepositoryProvider);
    if (repository is OfflineTaskRepository) {
      _openedOwner = repository.accountId();
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '未能完成核对。请检查网络或重新验证访问权限；尚未确认的本机记录仍保留。');
      }
    } finally {
      if (mounted) {
        ref.invalidate(syncDiagnosticsProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _adopt(OfflineTaskRepository repo, TaskSyncGroup group) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('采用服务端状态？'),
        content: Text(
          '联网核对后，将丢弃此任务的 ${group.operations.length} 项未确认本机操作'
          '（含 ${group.answers} 次复习作答），保留服务端已确认的结果与奖励。'
          '普通任务补签需家长 PIN；复习需按服务端状态继续作答。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留本机记录'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('联网核对并采用'),
          ),
        ],
      ),
    );
    if (yes == true && mounted && repo.accountId() == _openedOwner) {
      await _run(() => repo.acceptServer(widget.childId, group.taskId));
    }
  }

  Future<void> _copy(OfflineTaskRepository repo, String? familyId) async {
    final details = await repo.diagnostics(widget.childId);
    Map<String, int>? counts;
    if (mounted &&
        familyId != null &&
        ref.read(activeParentFamilyProvider) == familyId) {
      final images = await ref.read(
        imageDraftsProvider((child: widget.childId, family: familyId)).future,
      );
      if (mounted && ref.read(activeParentFamilyProvider) == familyId) {
        counts = {};
        for (final row in images) {
          final stage = row['stage'] as String;
          counts[stage] = (counts[stage] ?? 0) + 1;
        }
      }
    }
    if (!mounted ||
        details.owner != _openedOwner ||
        repo.accountId() != _openedOwner) {
      return;
    }
    await Clipboard.setData(
      ClipboardData(
        text: details.summary(
          phase: repo.state.phase.name,
          imageCounts: counts,
        ),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制不含身份和题目内容的诊断摘要')));
    }
  }

  Widget _group(
    OfflineTaskRepository repo,
    TaskSyncGroup group,
    String? familyId,
  ) => Card(
    child: ExpansionTile(
      key: PageStorageKey(
        'sync-$_openedOwner-${widget.childId}-${group.taskId}',
      ),
      title: Text(
        group.confirmed?.title ?? (group.review ? '复习任务（快照不可用）' : '任务（快照不可用）'),
      ),
      subtitle: Text(
        '${group.conflict ? '需要处理' : '等待同步'} · ${group.operations.length} 项操作',
      ),
      childrenPadding: const EdgeInsets.all(16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '云端最近确认：${group.confirmed == null ? '暂无可用快照' : _status(group.confirmed!.status)}',
        ),
        if (group.confirmed != null)
          Text('已确认有效时长：${group.confirmed!.accumulatedSeconds} 秒'),
        const Text('本机待确认操作（按顺序）：'),
        for (final operation in group.operations)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${operation.label} · ${_time(operation.at)}'),
                if (operation.attempts > 0)
                  Text('传输失败 ${operation.attempts} 次'),
                if (!operation.conflict && operation.nextAttempt != null)
                  Text('重试时间：${_time(operation.nextAttempt)}；恢复网络后会尽快尝试'),
              ],
            ),
          ),
        for (final reason
            in group.operations
                .map((o) => o.explanation)
                .whereType<String>()
                .toSet())
          Text(reason),
        if (group.answers > 0)
          Text('${group.answers} 次答案尚未获服务端确认，不能据此判定对错或发奖。'),
        Wrap(
          spacing: 8,
          children: [
            if (group.review)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ReviewSessionScreen(
                            taskId: group.taskId,
                            childId: widget.childId,
                            familyId: familyId,
                          ),
                        ),
                      ),
                child: const Text('查看复习记录'),
              ),
            if (group.conflict)
              TextButton(
                onPressed: _busy ? null : () => _adopt(repo, group),
                child: const Text('采用服务端状态'),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _images(String? familyId) {
    if (familyId == null) return const Text('暂未取得孩子所属家庭，刷新家庭资料后可查看图片队列。');
    final parent = ref.watch(activeParentFamilyProvider) == familyId;
    if (!parent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('家长验证后可查看图片草稿与上传状态。'),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() => enterParentMode(context, ref, familyId)),
            child: const Text('验证家长 PIN'),
          ),
        ],
      );
    }
    final rows = ref.watch(
      imageDraftsProvider((child: widget.childId, family: familyId)),
    );
    return rows.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => const Text('暂时无法读取图片队列，请重新验证家长 PIN 后刷新。'),
      data: (rows) {
        final counts = <String, int>{};
        for (final row in rows) {
          final stage = row['stage'] as String;
          counts[stage] = (counts[stage] ?? 0) + 1;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rows.isEmpty) const Text('当前孩子没有本机图片草稿或待上传图片。'),
            for (final entry in const {
              'editing': '待校对（尚未同意上传）',
              'queued': '等待上传',
              'uploading': '上传中或上次上传尚未确认',
              'retry': '网络中断，等待重试',
              'blocked': '上传未被接受',
              'needs_authorization': '需要重新验证家长授权',
            }.entries)
              if ((counts[entry.key] ?? 0) > 0)
                Text('${entry.value}：${counts[entry.key]} 张'),
            const Text('只重试已同意上传的图片。待校对草稿不会自动上传。'),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy || rows.every((r) => r['stage'] == 'editing')
                      ? null
                      : () => _run(() async {
                          if (ref.read(activeParentFamilyProvider) !=
                              familyId) {
                            return;
                          }
                          final repo = ref.read(
                            questionMediaRepositoryProvider,
                          );
                          if (repo is OfflineQuestionMediaRepository) {
                            await repo.synchronize(
                              retryBlocked: true,
                              childId: widget.childId,
                            );
                          }
                        }),
                  child: const Text('重试当前孩子的上传'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => ImageDraftsScreen(
                              childId: widget.childId,
                              familyId: familyId,
                            ),
                          ),
                        ),
                  child: const Text('管理图片草稿'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(taskRepositoryProvider);
    if (repo is! OfflineTaskRepository ||
        _openedOwner == null ||
        repo.accountId() != _openedOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('同步中心')),
        body: const Center(child: Text('登录账号已变化，请返回首页重新打开')),
      );
    }
    final state = ref.watch(taskSyncStateProvider).valueOrNull ?? repo.state;
    final data = ref.watch(syncDiagnosticsProvider(widget.childId));
    String? familyId, nickname;
    final families = ref.watch(familiesProvider).valueOrNull;
    for (final family in families ?? []) {
      for (final child in family.children) {
        if (child.id == widget.childId) {
          familyId = family.id;
          nickname = child.nickname;
        }
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('同步中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            nickname == null ? '当前孩子 · 此设备' : '$nickname · 此设备',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text('任务和复习操作先保存在本机。前台每 15 秒尝试同步；钱包只显示服务端确认的余额。'),
          Text(switch (state.phase) {
            TaskSyncPhase.synced => '任务通道：暂无同步异常',
            TaskSyncPhase.syncing => '任务通道：正在同步',
            TaskSyncPhase.offline => '任务通道：网络暂不可用',
            TaskSyncPhase.conflict => '任务通道：需要核对',
          }),
          if (state.message != null) Text(syncExplanation(state.message)),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy || state.phase == TaskSyncPhase.syncing
                    ? null
                    : () => _run(() => repo.synchronize(widget.childId)),
                child: const Text('立即同步任务与复习'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => ref.invalidate(
                        syncDiagnosticsProvider(widget.childId),
                      ),
                child: const Text('刷新本机状态'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => _copy(repo, familyId)),
                child: const Text('复制诊断摘要'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          data.when(
            skipLoadingOnReload: false,
            skipLoadingOnRefresh: false,
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const Text('本机状态暂不可用，可能已清理。请返回首页核对。'),
            data: (details) => details.owner != _openedOwner
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '待同步 ${details.pending} 项操作 · 冲突 ${details.conflicts} 个任务',
                      ),
                      Text('最近任务快照：${_time(details.confirmedAt)}（设备显示时区）'),
                      Text('离线授权到期：${_time(details.leaseExpiresAt)}'),
                      const Text('快照可能已被其他设备更新。采用服务端状态前会重新联网核对；核对失败不会丢弃本机操作。'),
                      if (details.groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('当前孩子没有待确认的任务或复习操作。'),
                        ),
                      for (final group in details.groups)
                        _group(repo, group, familyId),
                      if (details.otherChildOperations > 0)
                        Text(
                          '本账号其他孩子还有 ${details.otherChildOperations} 项未确认操作，可返回首页切换孩子查看。任务同步会尝试本账号队列。',
                        ),
                    ],
                  ),
          ),
          const Divider(height: 32),
          Text('图片草稿与上传', style: Theme.of(context).textTheme.titleLarge),
          _images(familyId),
        ],
      ),
    );
  }
}

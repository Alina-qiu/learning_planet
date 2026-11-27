import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/notification_scheduler.dart';
import '../../tasks/data/schedule_repository.dart';
import '../../wrong_questions/data/review_repository.dart';
import '../../wrong_questions/data/question_catalog.dart';
import '../../wrong_questions/data/question_media_repository.dart';
import '../../worksheets/data/worksheet_repository.dart';
import '../../economy/data/economy_repository.dart';
import '../../growth/data/growth_repository.dart';
import '../../reports/data/report_repository.dart';
import '../data/child_deletion_repository.dart';
import '../data/child_export_repository.dart';

const _labels = {
  'tasks': '任务',
  'templates': '任务模板',
  'questions': '错题与拼音',
  'ocr_drafts': 'OCR来源与草稿',
  'ai_requests': 'AI分析请求与建议',
  'worksheets': '组卷',
  'redemptions': '兑换记录',
  'ledger_entries': '账本记录',
  'coins': '可用金币',
  'frozen_coins': '冻结金币',
  'xp': '经验值',
  'files': '文件路径',
};

class ChildDeletionScreen extends ConsumerStatefulWidget {
  const ChildDeletionScreen({
    required this.familyId,
    this.childId,
    this.nickname,
    super.key,
  });
  final String familyId;
  final String? childId, nickname;
  @override
  ConsumerState<ChildDeletionScreen> createState() =>
      _ChildDeletionScreenState();
}

class _ChildDeletionScreenState extends ConsumerState<ChildDeletionScreen> {
  bool _busy = false, _accepted = false;
  Map<String, dynamic>? _preview, _confirmedCounts;
  String? _requestId, _message;
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId;
  void _check() {
    if (!mounted || !_authorized) throw StateError('家长授权已到期，请重新验证 PIN');
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      _check();
      await work();
    } catch (error) {
      if (mounted) setState(() => _message = '操作未确认：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadPreview() => _run(() async {
    final result = await ref
        .read(childDeletionRepositoryProvider)
        .preview(widget.childId!);
    _check();
    if (result['child_id'] != widget.childId ||
        result['family_id'] != widget.familyId) {
      throw StateError('删除范围不匹配');
    }
    setState(() => _preview = result);
  });
  void _invalidateChild() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ref.invalidate(selectedChildIdProvider);
    ref.invalidate(familiesProvider);
    ref.invalidate(tasksProvider);
    ref.invalidate(walletProvider);
    ref.invalidate(familyTodayProvider);
    ref.invalidate(schedulesProvider);
    ref.invalidate(remindersProvider);
    ref.invalidate(reviewQuestionsProvider);
    ref.invalidate(questionCatalogRepositoryProvider);
    ref.invalidate(reviewOverviewProvider);
    ref.invalidate(reviewTaskProvider);
    ref.invalidate(questionProvenanceProvider);
    ref.invalidate(questionImageUrlProvider);
    ref.invalidate(worksheetHistoryProvider);
    ref.invalidate(worksheetBytesProvider);
    ref.invalidate(economyDataProvider);
    ref.invalidate(growthProvider);
    ref.invalidate(learningEventsProvider);
    ref.invalidate(learningReportProvider);
    ref.invalidate(childExportPreviewProvider);
    ref.invalidate(childDeletionHistoryProvider(widget.familyId));
  }

  Future<void> _submit() => _run(() async {
    // A stable UUID is retained after a timeout, including when the server already
    // committed and this device still needs to purge its offline copy.
    await ref.read(notificationSchedulerProvider).setScope(null);
    _check();
    try {
      await ref
          .read(childDeletionRepositoryProvider)
          .request(widget.childId!, _requestId!, _confirmedCounts!);
    } on PostgrestException catch (error) {
      if (error.code == '40001') {
        _requestId = null;
        _confirmedCounts = null;
        _preview = null;
      }
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      _accepted = true;
      _preview = null;
      _message = '孩子业务数据已移除，文件正在等待后台清理。请在下方查看最终状态。';
    });
    _invalidateChild();
  });
  Future<void> _confirm() async {
    var phrase = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('永久删除${widget.nickname ?? '孩子'}？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '确认后立即移除档案、任务、错题、金币/XP及兑换记录，也会丢弃此孩子未同步的本机操作。无法恢复，请先导出需要保留的数据。',
              ),
              TextField(
                onChanged: (value) => phrase = value,
                decoration: const InputDecoration(labelText: '输入“永久删除孩子”确认'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (phrase == '永久删除孩子') Navigator.pop(context, true);
            },
            child: const Text('确认永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_authorized) return;
    _requestId = const Uuid().v4();
    _confirmedCounts = Map<String, dynamic>.from(_preview!['counts'] as Map);
    await _submit();
  }

  Future<void> _retryJob(String id) => _run(() async {
    await ref.read(childDeletionRepositoryProvider).retry(id);
    _check();
    ref.invalidate(childDeletionHistoryProvider(widget.familyId));
  });

  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(title: const Text('孩子删除与记录')),
      body: !authorized
          ? const Center(child: Text('请返回首页验证家长 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '仅家庭管理员可删除。业务数据在确认后立即移除；图片/PDF至少等待10分钟，并等待旧生成任务结束后清理。失败会保留文件清单并重试，只有“文件清理完成”代表已验证文件不存在。',
                ),
                const SizedBox(height: 8),
                const Text(
                  '已完成的删除任务记录保留30天；不含姓名或题目的孩子UUID标记保留到家庭删除，用于其他设备联网后清除旧缓存。已下载或分享的副本无法远程擦除。',
                ),
                if (_message != null)
                  Text(_message!, key: const Key('deletion-message')),
                if (_busy) const LinearProgressIndicator(),
                if (widget.childId != null && !_accepted) ...[
                  Text(
                    widget.nickname ?? '所选孩子',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (_requestId != null) ...[
                    const Text('请求结果尚未确认。重试会使用相同标识，不会创建第二次删除。'),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: const Text('重试同一删除请求'),
                    ),
                  ] else ...[
                    OutlinedButton(
                      onPressed: _busy ? null : _loadPreview,
                      child: const Text('预览删除范围'),
                    ),
                    if (_preview != null) ...[
                      for (final entry
                          in (_preview!['counts'] as Map<String, dynamic>)
                              .entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_labels[entry.key] ?? entry.key),
                          trailing: Text('${entry.value}'),
                        ),
                      FilledButton(
                        onPressed: _busy ? null : _confirm,
                        child: const Text('永久删除孩子'),
                      ),
                    ],
                  ],
                ],
                const Divider(),
                Row(
                  children: [
                    const Expanded(child: Text('家庭删除记录（不含孩子姓名）')),
                    IconButton(
                      tooltip: '刷新记录',
                      onPressed: _busy
                          ? null
                          : () => ref.invalidate(
                              childDeletionHistoryProvider(widget.familyId),
                            ),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                ref
                    .watch(childDeletionHistoryProvider(widget.familyId))
                    .when(
                      loading: () => const Text('正在读取…'),
                      error: (error, _) => Text('记录读取失败：$error'),
                      data: (jobs) => Column(
                        children: [
                          if (jobs.isEmpty) const Text('暂无删除记录'),
                          for (final job in jobs)
                            ListTile(
                              title: Text(
                                job['status'] == 'completed'
                                    ? '文件清理完成'
                                    : job['status'] == 'failed'
                                    ? '文件清理失败，等待重试'
                                    : job['status'] == 'running'
                                    ? '正在清理文件'
                                    : '业务数据已移除，等待文件清理',
                              ),
                              subtitle: Text(
                                '孩子ID：${job['child_id']}\n提交：${job['created_at']}\n${job['status'] == 'completed' ? '完成：${job['completed_at']}' : '最早重试：${job['next_attempt_at']}'}',
                              ),
                              trailing: job['status'] == 'completed'
                                  ? const Icon(Icons.check_circle_outline)
                                  : TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () =>
                                                _retryJob(job['id'] as String),
                                      child: const Text('重试/查询'),
                                    ),
                            ),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}

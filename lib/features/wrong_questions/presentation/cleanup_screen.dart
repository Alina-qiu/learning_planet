import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/cleanup_repository.dart';
import '../data/review_repository.dart';
import '../data/question_catalog.dart';
import '../../tasks/application/task_providers.dart';
import '../data/question_media_repository.dart';
import '../../worksheets/data/worksheet_repository.dart';

class CleanupScreen extends ConsumerStatefulWidget {
  const CleanupScreen({
    required this.childId,
    required this.familyId,
    this.questionIds = const [],
    super.key,
  });
  final String childId, familyId;
  final List<String> questionIds;
  @override
  ConsumerState<CleanupScreen> createState() => _CleanupScreenState();
}

class _CleanupScreenState extends ConsumerState<CleanupScreen> {
  bool _busy = false;
  final _keys = <String, String>{};
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId;
  void _check() {
    if (!_authorized) throw StateError('家长 PIN 授权已到期，请重新验证');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _check();
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理未确认完成：$error。刷新记录后重试，不要新建相同请求。')),
        );
      }
    } finally {
      if (mounted) {
        ref.invalidate(cleanupJobsProvider(widget.childId));
        ref.invalidate(reviewQuestionsProvider(widget.childId));
        ref.invalidate(questionCatalogRepositoryProvider);
        ref.invalidate(reviewOverviewProvider(widget.childId));
        ref.invalidate(reviewTaskProvider);
        ref.invalidate(questionProvenanceProvider);
        ref.invalidate(questionImageUrlProvider);
        ref.invalidate(worksheetHistoryProvider(widget.childId));
        ref.invalidate(worksheetBytesProvider);
        ref.invalidate(tasksProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _request(String scope) => _run(() async {
    final repo = ref.read(cleanupRepositoryProvider);
    final ids = scope == 'abandoned_ocr' ? <String>[] : widget.questionIds;
    final preview = await repo.preview(widget.childId, scope, ids);
    if (!mounted) return;
    final controller = TextEditingController();
    final confirmed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除，无法恢复'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '涉及 ${preview['questions']} 道题、${preview['drafts']} 个图片记录、${preview['files']} 个文件，含 ${preview['worksheets'] ?? 0} 份关联PDF。将作废 ${preview['unfinished_reviews']} 个未完成复习。正在生成的PDF需等待旧进程结束后清理。',
              ),
              Text(
                scope == 'originals'
                    ? '只删除原图，保留处理图、错题及复习。'
                    : scope == 'abandoned_ocr'
                    ? '清理本人超过24小时且尚未入库的图片草稿，包括已提交但待家长确认的错题。'
                    : '删除题目与图片，历史题目和答案脱敏；受影响复习任务的本机待同步答案也会清除。已结算金币及XP不撤回。',
              ),
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: '输入“永久删除”确认'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text == '永久删除') {
                Navigator.pop(context, controller.text);
              }
            },
            child: const Text('确认永久删除'),
          ),
        ],
      ),
    );
    // Dialog exit animation may still hold its controller for one frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (!mounted || confirmed == null) return;
    _check();
    final key = _keys.putIfAbsent(scope, () => const Uuid().v4());
    await repo.request(widget.childId, scope, ids, key, confirmed);
    _keys.remove(scope);
  });
  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(
        title: const Text('永久清理'),
        actions: [
          IconButton(
            onPressed: _busy
                ? null
                : () => ref.invalidate(cleanupJobsProvider(widget.childId)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('归档可以恢复，永久清理无法恢复。清理任务保存到服务端；失败或网络中断不代表已删除，请查看记录并重试。'),
          if (!authorized) const Text('请先在首页验证家长 PIN。'),
          if (_busy) const Text('正在确认真实文件清理状态…'),
          if (widget.questionIds.isNotEmpty) ...[
            FilledButton(
              onPressed: authorized && !_busy
                  ? () => _request('questions')
                  : null,
              child: Text('永久删除所选 ${widget.questionIds.length} 道题'),
            ),
            OutlinedButton(
              onPressed: authorized && !_busy
                  ? () => _request('originals')
                  : null,
              child: const Text('仅清理所选题目的原图'),
            ),
          ],
          OutlinedButton(
            onPressed: authorized && !_busy
                ? () => _request('abandoned_ocr')
                : null,
            child: const Text('清理本人超过24小时的未保存图片'),
          ),
          const Divider(),
          const Text('服务端清理记录'),
          if (authorized)
            ref
                .watch(cleanupJobsProvider(widget.childId))
                .when(
                  loading: () => const Text('读取清理记录…'),
                  error: (error, _) => Text('读取失败：$error'),
                  data: (jobs) => Column(
                    children: [
                      for (final job in jobs)
                        ListTile(
                          title: Text('${job['scope']} · ${job['status']}'),
                          subtitle: Text(
                            '尝试 ${job['attempts']} 次 · ${job['created_at']}\n${job['error_code'] ?? ''}',
                          ),
                          trailing: job['status'] == 'completed'
                              ? const Icon(Icons.check_circle_outline)
                              : TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(
                                          () => ref
                                              .read(cleanupRepositoryProvider)
                                              .retry(job['id'] as String),
                                        ),
                                  child: const Text('重试 / 查询'),
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

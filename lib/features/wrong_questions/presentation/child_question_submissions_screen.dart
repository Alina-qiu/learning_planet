import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/presentation/parent_mode_prompt.dart';
import '../data/child_question_submissions.dart';
import '../data/review_repository.dart';
import '../data/question_catalog.dart';
import 'review_question_editor.dart';

class ChildQuestionSubmissionsScreen extends ConsumerStatefulWidget {
  const ChildQuestionSubmissionsScreen({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;
  @override
  ConsumerState<ChildQuestionSubmissionsScreen> createState() =>
      _ChildQuestionSubmissionsScreenState();
}

class _ChildQuestionSubmissionsScreenState
    extends ConsumerState<ChildQuestionSubmissionsScreen> {
  SubmissionScope get _scope =>
      (childId: widget.childId, familyId: widget.familyId);
  ChildQuestionSubmissions? _service;
  SubmissionAccess? _access;
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic>? _cursor, _selected, _approval;
  String? _request, _error;
  bool _busy = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _current =>
      _access != null && _service?.isCurrent(_scope, _access!) == true;
  void _reset() {
    _epoch++;
    _rows = [];
    _cursor = null;
    _selected = null;
    _approval = null;
    _request = null;
    _access = null;
    _busy = false;
  }

  Future<void> _load({bool more = false}) async {
    if (_busy || !mounted) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
      if (!more) {
        _rows = [];
        _approval = null;
        _request = null;
        _selected = null;
        _cursor = null;
      }
    });
    try {
      final service = ref.read(childQuestionSubmissionsProvider);
      if (service == null) throw StateError('请配置后端并登录后查看云端提交');
      final access = more ? _access! : service.capture(_scope);
      _service = service;
      _access = access;
      final page = await service.list(
        _scope,
        access,
        cursor: more ? _cursor : null,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        final seen = _rows.map((r) => r['id']).toSet();
        _rows = [
          ..._rows,
          for (final item in page['items'] as List)
            if (seen.add(item['id'])) Map<String, dynamic>.from(item as Map),
        ];
        _cursor = page['next_cursor'] == null
            ? null
            : Map<String, dynamic>.from(page['next_cursor'] as Map);
      });
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = '读取失败：$error');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _open(String id) async {
    if (_busy || !_current) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final row = await _service!.read(_scope, _access!, id);
      if (mounted && epoch == _epoch) setState(() => _selected = row);
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = '读取失败：$error');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _review() async {
    if (_busy || !_current || !_access!.parent || _selected == null) return;
    final epoch = ++_epoch,
        row = _selected!,
        access = _access!,
        service = _service!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_approval == null) {
        final config = row['config'] as Map;
        final result = await Navigator.push<Map<String, dynamic>>(
          context,
          MaterialPageRoute(
            builder: (_) => Consumer(
              builder: (_, ref, _) {
                ref.watch(activeParentFamilyProvider);
                ref.watch(parentAuthorizationRevisionProvider);
                return service.isCurrent(_scope, access)
                    ? ReviewQuestionEditor(
                        pinyin: false,
                        fromImage: true,
                        initial: {
                          ...config,
                          'ocr_field_confirmations': <String>[],
                          'final_text': config['prompt'],
                          'pronunciation_context': config['context'],
                        },
                        ocrResult: Map<String, dynamic>.from(
                          row['recognition'] as Map? ?? {},
                        ),
                        imageUrls: (row['image_urls'] as List).cast<String>(),
                        familyId: widget.familyId,
                        childId: widget.childId,
                      )
                    : Scaffold(
                        appBar: AppBar(title: const Text('家长授权已变化')),
                        body: const Center(child: Text('请返回并重新验证家长 PIN')),
                      );
              },
            ),
          ),
        );
        if (!mounted || epoch != _epoch || result == null) return;
        if (!service.isCurrent(_scope, access)) throw StateError('家长授权已变化，请刷新');
        _approval = result;
        _request = const Uuid().v4();
      }
      final confirmed = await service.approve(
        _scope,
        access,
        row['draft_id'] as String,
        _request!,
        _approval!,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _selected = {...confirmed, 'image_urls': row['image_urls']};
        _rows = [
          for (final r in _rows)
            r['id'] == confirmed['draft_id']
                ? {
                    ...r,
                    'state': 'approved',
                    'question_id': confirmed['question_id'],
                  }
                : r,
        ];
        _approval = null;
        _request = null;
      });
      ref.invalidate(reviewQuestionsProvider(widget.childId));
      ref.invalidate(questionCatalogRepositoryProvider);
      ref.invalidate(reviewOverviewProvider(widget.childId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标准答案已确认，错题已加入复习库。本次确认不发放奖励。')),
      );
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = '确认结果未取得：$error。可重试原确认请求；若已由其他家长处理，请返回刷新。');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    ref.watch(parentAuthorizationRevisionProvider);
    ref.watch(childQuestionSubmissionsProvider);
    ref.listen(parentAuthorizationRevisionProvider, (_, _) {
      setState(_reset);
    });
    final selected = _current ? _selected : null;
    final config = selected?['config'] as Map?;
    return Scaffold(
      appBar: AppBar(
        title: const Text('孩子提交与家长确认'),
        actions: [
          IconButton(
            onPressed: _busy || _approval != null ? null : () => _load(),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                const Text('孩子提交的题目须经家长确认标准答案，才会加入奖励复习。提交和确认本身均不发奖励。'),
                if (!parent)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await enterParentMode(
                              context,
                              ref,
                              widget.familyId,
                            );
                            if (mounted) await _load();
                          },
                    child: const Text('家长验证 PIN 后确认'),
                  ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                if (!_current && !_busy)
                  FilledButton(
                    onPressed: () => _load(),
                    child: const Text('重新读取提交记录'),
                  ),
                if (selected != null) ...[
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _selected = null;
                              _approval = null;
                              _request = null;
                            });
                            _load();
                          },
                    child: const Text('返回列表并刷新'),
                  ),
                  Text(
                    selected['state'] == 'approved' ? '家长已确认并入库' : '待家长确认标准答案',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Text('以下为孩子提交时的内容；正式答案以复习库中家长确认后的题目为准。'),
                  SelectableText(config?['prompt'] as String? ?? ''),
                  Text(
                    '孩子填写的参考答案：${(config?['answers'] as List? ?? []).join('；')}',
                  ),
                  for (final url in selected['image_urls'] as List? ?? [])
                    SizedBox(
                      height: 240,
                      child: InteractiveViewer(
                        child: Image.network(
                          url as String,
                          errorBuilder: (_, _, _) => const Text('图片加载失败，请刷新'),
                        ),
                      ),
                    ),
                  ExpansionTile(
                    title: const Text('原始 OCR（只读）'),
                    children: [
                      SelectableText(
                        (selected['recognition'] as Map?)?['text'] as String? ??
                            '手工校对，无识别文本',
                      ),
                    ],
                  ),
                  if (parent && selected['state'] == 'pending')
                    FilledButton(
                      onPressed: _busy ? null : _review,
                      child: Text(
                        _approval == null ? '核对标准答案并确认入库' : '重试原确认请求',
                      ),
                    ),
                  if (_approval != null)
                    const Text('已保留本次确认内容，重试不会重复建题。返回刷新可查看服务端最终状态。'),
                ] else if (_current) ...[
                  if (_rows.isEmpty && !_busy)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无已提交记录。本机草稿须完成校对并上传后才会出现在这里。'),
                    ),
                ],
              ],
            ),
          ),
          if (_current && selected == null)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.builder(
                itemCount: _rows.length,
                itemBuilder: (context, index) {
                  final row = _rows[index];
                  return Card(
                    child: ListTile(
                      title: Text(row['title'] as String),
                      subtitle: Text(
                        row['state'] == 'approved' ? '已确认入库' : '待家长确认',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _open(row['id'] as String),
                    ),
                  );
                },
              ),
            ),
          if (_current && selected == null && _cursor != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('加载更多'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../../wrong_questions/data/review_repository.dart';
import '../data/worksheet_repository.dart';
import 'worksheet_pdf_screen.dart';

class WorksheetScreen extends ConsumerStatefulWidget {
  const WorksheetScreen({
    required this.childId,
    required this.familyId,
    this.initialQuestionIds = const [],
    super.key,
  });
  final String childId, familyId;
  final List<String> initialQuestionIds;
  @override
  ConsumerState<WorksheetScreen> createState() => _WorksheetScreenState();
}

class _WorksheetScreenState extends ConsumerState<WorksheetScreen> {
  final _title = TextEditingController(text: '学习星球练习卷');
  final _deleteKeys = <String, String>{};
  late final List<String> _selected;
  String _key = const Uuid().v4(),
      _orientation = 'portrait',
      _pinyinMode = 'word_to_pinyin',
      _grid = 'both',
      _keyword = '';
  int _margin = 12, _blankLines = 3, _repeats = 1;
  bool _questions = true,
      _answers = false,
      _explanations = false,
      _busy = false,
      _pending = false,
      _activeJobs = false;
  Map<String, dynamic>? _frozenConfig;
  List<String>? _frozenIds;
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _selected = widget.initialQuestionIds.toSet().take(100).toList();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted &&
          _activeJobs &&
          ref.read(activeParentFamilyProvider) == widget.familyId) {
        ref.invalidate(worksheetHistoryProvider(widget.childId));
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _title.dispose();
    super.dispose();
  }

  void _check() {
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长PIN授权已到期');
    }
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
          SnackBar(content: Text('尚未确认完成：$error。请在历史记录重试同一份组卷，不会重复建卷或扣费。')),
        );
      }
    } finally {
      if (mounted) {
        ref.invalidate(worksheetHistoryProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete(String id) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('永久删除 PDF？'),
        content: const Text(
          '将清除服务端 PDF 和题目、答案快照，无法恢复。已下载或分享的外部副本无法远程删除。正在生成的文件需等待旧进程结束后清理。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认永久删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run(() async {
      final key = _deleteKeys.putIfAbsent(id, () => const Uuid().v4());
      await ref.read(worksheetRepositoryProvider).delete(id, key);
      ref.invalidate(worksheetBytesProvider(id));
    });
  }

  Future<void> _create() => _run(() async {
    if (!_pending) {
      if (_selected.isEmpty ||
          _title.text.trim().isEmpty ||
          !_questions && !_answers && !_explanations) {
        throw StateError('请选择题目、填写标题，并至少打开题目/答案/解析中的一项');
      }
      _frozenIds = List.of(_selected);
      _frozenConfig = {
        'title': _title.text.trim(),
        'orientation': _orientation,
        'margin_mm': _margin,
        'blank_lines': _blankLines,
        'repeats': _repeats,
        'pinyin_mode': _pinyinMode,
        'grid': _grid,
        'include_questions': _questions,
        'include_answers': _answers,
        'include_explanations': _explanations,
      };
      setState(() => _pending = true);
    }
    await ref
        .read(worksheetRepositoryProvider)
        .create(widget.childId, _frozenIds!, _frozenConfig!, _key);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务端已受理，请在生成历史查看进度；不扣金币或XP。')),
      );
    }
  });
  Future<void> _new() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('新建另一份组卷？'),
        content: const Text('当前卷可能已创建，请先检查历史记录。新建会使用新的标识，原记录仍保留30天。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认新建'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _key = const Uuid().v4();
        _pending = false;
        _frozenIds = null;
        _frozenConfig = null;
      });
    }
  }

  Widget _choice(
    String label,
    String value,
    Map<String, String> values,
    void Function(String) change,
    bool editable,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('$label：'),
      Semantics(
        label: label,
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          itemHeight: null,
          items: [
            for (final entry in values.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: editable
              ? (value) => setState(() => change(value!))
              : null,
        ),
      ),
    ],
  );
  Widget _builder(bool editable) => ref
      .watch(reviewQuestionsProvider(widget.childId))
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('题目读取失败：$error'),
              TextButton(
                onPressed: () =>
                    ref.invalidate(reviewQuestionsProvider(widget.childId)),
                child: const Text('重新读取题目'),
              ),
            ],
          ),
        ),
        data: (rows) {
          final byId = {for (final row in rows) row['id'] as String: row};
          final filtered = rows
              .where(
                (row) => '${row['final_text']} ${row['knowledge_point'] ?? ''}'
                    .toLowerCase()
                    .contains(_keyword.toLowerCase()),
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('选择错题和拼音词语，拖动已选列表调整顺序。服务器冻结题干与答案，之后编辑源题不改变已创建的卷。'),
              TextField(
                controller: _title,
                enabled: editable,
                maxLength: 60,
                decoration: const InputDecoration(labelText: '试卷标题'),
              ),
              _choice(
                'A4方向',
                _orientation,
                {'portrait': '纵向', 'landscape': '横向'},
                (value) => _orientation = value,
                editable,
              ),
              Text('边距 $_margin mm（至少12 mm）'),
              Slider(
                value: _margin.toDouble(),
                min: 12,
                max: 25,
                divisions: 13,
                onChanged: editable
                    ? (value) => setState(() => _margin = value.round())
                    : null,
              ),
              Text('普通题作答空行 $_blankLines'),
              Slider(
                value: _blankLines.toDouble(),
                min: 0,
                max: 12,
                divisions: 12,
                onChanged: editable
                    ? (value) => setState(() => _blankLines = value.round())
                    : null,
              ),
              Text('作答区重复 $_repeats 次'),
              Slider(
                value: _repeats.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                onChanged: editable
                    ? (value) => setState(() => _repeats = value.round())
                    : null,
              ),
              _choice(
                '拼音模式',
                _pinyinMode,
                {
                  'word_to_pinyin': '看词写拼音',
                  'pinyin_to_word': '看拼音写词',
                  'mixed': '固定随机混合',
                },
                (value) => _pinyinMode = value,
                editable,
              ),
              _choice(
                '拼音作答区',
                _grid,
                {
                  'both': '四线格 + 田字格',
                  'four_lines': '四线三格',
                  'tianzige': '田字格',
                  'none': '普通空行',
                },
                (value) => _grid = value,
                editable,
              ),
              CheckboxListTile(
                value: _questions,
                onChanged: editable
                    ? (value) => setState(() => _questions = value!)
                    : null,
                title: const Text('包含题目页'),
              ),
              CheckboxListTile(
                value: _answers,
                onChanged: editable
                    ? (value) => setState(() => _answers = value!)
                    : null,
                title: const Text('包含独立答案页'),
              ),
              CheckboxListTile(
                value: _explanations,
                onChanged: editable
                    ? (value) => setState(() => _explanations = value!)
                    : null,
                title: const Text('包含解析（独立于答案开关）'),
              ),
              const Divider(),
              Text('已选 ${_selected.length}/100 · 可拖动排序'),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _selected.length,
                // Preserve Flutter 3.38 support; onReorderItem requires 3.41.
                // ignore: deprecated_member_use
                onReorder: (oldIndex, newIndex) {
                  if (!editable) return;
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final id = _selected.removeAt(oldIndex);
                    _selected.insert(newIndex, id);
                  });
                },
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey(_selected[index]),
                  title: Text(
                    '${index + 1}. ${byId[_selected[index]]?['final_text'] ?? '源题已变化，请重新读取'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: IconButton(
                    tooltip: '移除第${index + 1}题',
                    onPressed: editable
                        ? () => setState(() => _selected.removeAt(index))
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
              ),
              TextField(
                enabled: editable,
                decoration: const InputDecoration(labelText: '搜索可选题目或知识点'),
                onChanged: (value) => setState(() => _keyword = value),
              ),
              for (final row in filtered)
                CheckboxListTile(
                  value: _selected.contains(row['id']),
                  onChanged:
                      editable &&
                          (_selected.length < 100 ||
                              _selected.contains(row['id']))
                      ? (value) => setState(() {
                          if (value == true) {
                            _selected.add(row['id'] as String);
                          } else {
                            _selected.remove(row['id']);
                          }
                        })
                      : null,
                  title: Text(
                    row['final_text'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    row['review_kind'] == 'pinyin'
                        ? '拼音词语'
                        : '错题 · ${row['subject']}',
                  ),
                ),
            ],
          );
        },
      );
  Widget _historyJob(Map<String, dynamic> job) {
    final id = job['id'] as String;
    final status = job['status'];
    final available =
        ['ready', 'queued', 'running', 'failed'].contains(status) &&
        DateTime.parse(job['expires_at'] as String).isAfter(DateTime.now());
    final label = switch (status) {
      'queued' => '等待生成',
      'running' => '正在生成',
      'ready' => available ? '可预览' : '已到期',
      'failed' => '生成失败',
      'deleting' => '正在删除',
      'deleted' => '已删除',
      _ => '状态待确认',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (job['config'] as Map)['title'] as String? ?? '已永久删除的组卷',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('$label · ${job['progress']}% · ${job['pages'] ?? '-'}页'),
            if (status != 'deleted')
              Text(
                '保留至 ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse(job['expires_at'] as String).toLocal())}（本机时间）',
              ),
            if (status == 'failed') const Text('生成未完成，可重试同一份组卷。'),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (status == 'ready' && available)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => WorksheetPdfScreen(
                                id: id,
                                familyId: widget.familyId,
                              ),
                            ),
                          ),
                    child: const Text('预览 / 导出'),
                  )
                else if (['queued', 'running', 'failed'].contains(status) &&
                    available)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => ref
                                .read(worksheetRepositoryProvider)
                                .generate(id),
                          ),
                    child: const Text('重试 / 查询'),
                  ),
                if (status != 'deleted')
                  TextButton(
                    onPressed: _busy ? null : () => _delete(id),
                    child: Text(
                      status == 'deleting' ? '查询 / 重试清理' : '永久删除 PDF',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    if (!parent) {
      return Scaffold(
        appBar: AppBar(title: const Text('A4组卷与PDF')),
        body: const Center(child: Text('请先返回首页验证家长PIN')),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('A4组卷与PDF'),
          actions: [
            IconButton(
              tooltip: '刷新生成历史',
              onPressed: _busy
                  ? null
                  : () => ref.invalidate(
                      worksheetHistoryProvider(widget.childId),
                    ),
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '混合选题与配置'),
              Tab(text: '生成历史'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: Column(
            children: [
              if (_busy) const Text('正在提交或核对生成状态…'),
              if (_pending) const Text('当前请求配置已冻结，重试不会重复建卷。'),
              Expanded(
                child: TabBarView(
                  children: [
                    _builder(!_busy && !_pending),
                    ref
                        .watch(worksheetHistoryProvider(widget.childId))
                        .when(
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (error, _) =>
                              Center(child: Text('历史读取失败：$error')),
                          data: (jobs) {
                            _activeJobs = jobs.any(
                              (job) => [
                                'queued',
                                'running',
                                'deleting',
                              ].contains(job['status']),
                            );
                            return ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                const Text(
                                  '服务端保留30天，生成失败可以重试相同记录，不额外收费。进度自动刷新；预览、下载和导出需有效家长PIN。',
                                ),
                                for (final job in jobs) _historyJob(job),
                              ],
                            );
                          },
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final create = FilledButton(
                  onPressed: _busy ? null : _create,
                  child: Text(_pending ? '重试同一份组卷' : '生成服务端 PDF'),
                );
                final another = TextButton(
                  onPressed: _busy ? null : _new,
                  child: const Text('新建另一份'),
                );
                return constraints.maxWidth < 520
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [create, if (_pending) another],
                      )
                    : Row(
                        children: [
                          Expanded(child: create),
                          if (_pending) another,
                        ],
                      );
              },
            ),
          ),
        ),
      ),
    );
  }
}

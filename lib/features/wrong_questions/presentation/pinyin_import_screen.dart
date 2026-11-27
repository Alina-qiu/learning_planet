import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../../worksheets/presentation/worksheet_screen.dart';
import '../data/pinyin_import_repository.dart';
import '../data/review_repository.dart';
import '../data/question_catalog.dart';
import '../domain/pinyin_import.dart';

class _WordDraft {
  _WordDraft(PinyinImportRow row)
    : word = TextEditingController(text: row.word),
      reading = TextEditingController(text: row.reading),
      context = TextEditingController(text: row.context),
      knowledge = TextEditingController(text: row.knowledge);
  final TextEditingController word, reading, context, knowledge;
  bool confirmed = false, sandhi = false;
  String? hint;
  void dispose() {
    word.dispose();
    reading.dispose();
    context.dispose();
    knowledge.dispose();
  }

  PinyinImportRow get value => PinyinImportRow(
    word: word.text,
    reading: reading.text,
    context: context.text,
    knowledge: knowledge.text,
  );
}

class PinyinImportScreen extends ConsumerStatefulWidget {
  const PinyinImportScreen({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;
  @override
  ConsumerState<PinyinImportScreen> createState() => _PinyinImportScreenState();
}

class _PinyinImportScreenState extends ConsumerState<PinyinImportScreen> {
  final _source = TextEditingController();
  final _drafts = <_WordDraft>[];
  String _requestId = const Uuid().v4();
  String? _error;
  bool _busy = false;
  List<Map<String, dynamic>>? _pending;
  Map<String, dynamic>? _result;
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId;
  @override
  void dispose() {
    _source.dispose();
    for (final row in _drafts) {
      row.dispose();
    }
    super.dispose();
  }

  void _preview() {
    try {
      final rows = parsePinyinImport(_source.text);
      for (final row in _drafts) {
        row.dispose();
      }
      setState(() {
        _drafts
          ..clear()
          ..addAll(rows.map(_WordDraft.new));
        _error = null;
        _requestId = const Uuid().v4();
      });
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final text = await ref.read(pinyinFileReaderProvider)();
      if (!mounted || !_authorized || text == null) return;
      _source.text = text;
      _preview();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _suggest(_WordDraft row) {
    try {
      final value = suggestPinyin(
        row.word.text,
        row.context.text,
        toneSandhi: row.sandhi,
      );
      setState(() {
        row.reading.text = value.reading;
        row.confirmed = false;
        row.hint = value.alternatives.isEmpty
            ? '本地候选，仍需按教材与语境核对'
            : '多音字候选：${value.alternatives.entries.map((e) => '${e.key} ${e.value.join('/')}').join('；')}';
      });
    } catch (error) {
      setState(() => row.hint = '$error');
    }
  }

  Future<void> _save() async {
    if (_busy || !_authorized) return;
    if (_pending == null) {
      for (var i = 0; i < _drafts.length; i++) {
        final row = _drafts[i];
        final value = row.value;
        if (!row.confirmed ||
            value.word.trim().isEmpty ||
            value.word.length > 80 ||
            value.reading.trim().isEmpty ||
            value.reading.length > 500 ||
            value.context.trim().isEmpty ||
            value.context.length > 2000 ||
            value.knowledge.length > 200) {
          setState(() => _error = '第${i + 1}条尚未完整核对：请填写词语、读音、语境并勾选确认');
          return;
        }
      }
      _pending = [
        for (final row in _drafts) row.value.toConfig(confirmed: row.confirmed),
      ];
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(pinyinImportRepositoryProvider)
          .importWords(widget.childId, _requestId, _pending!);
      if (!mounted) return;
      ref.invalidate(reviewQuestionsProvider(widget.childId));
      ref.invalidate(questionCatalogRepositoryProvider);
      ref.invalidate(reviewOverviewProvider(widget.childId));
      setState(() {
        _result = result;
        _pending = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          // An explicit database rejection rolls back the entire transaction.
          if (error is PostgrestException &&
              const {
                '22023',
                'P0001',
                '42501',
                '23514',
                '22001',
                '40001',
              }.contains(error.code)) {
            _pending = null;
            _error = '导入未通过：${error.message}。请检查后重试。';
          } else {
            _error = '导入结果尚未确认：$error。重试将使用原请求与原内容，避免重复导入。';
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final locked = _busy || _pending != null;
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('导入拼音词库')),
      body: !authorized
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : result != null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '已新增 ${(result['created'] as List).length} 条，跳过 ${(result['skipped'] as List).length} 条',
                ),
                const Text(
                  '相同词语和语境已存在时，保留原读音、掌握状态与归档状态。新增词语进入后续每日复习；已生成的当天题目保持固定。导入不发奖。',
                ),
                if ((result['skipped'] as List).isNotEmpty)
                  Text(
                    '保留已有配置的行：${(result['skipped'] as List).map((row) => row['row']).join('、')}',
                  ),
                if ((result['created'] as List).isNotEmpty)
                  FilledButton(
                    onPressed: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WorksheetScreen(
                          childId: widget.childId,
                          familyId: widget.familyId,
                          initialQuestionIds: (result['created'] as List)
                              .map((row) => row['question_id'] as String)
                              .toList(),
                        ),
                      ),
                    ),
                    child: const Text('用新增词语生成练习卷'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回词库'),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '支持UTF-8 CSV、TSV或粘贴，每次最多100条、256 KiB。逐条核对语境及读音后才会保存；文件只在本机解析。',
                ),
                if (_error != null && _drafts.isEmpty)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_pending != null)
                  const Text('原导入内容已冻结，可重试核对结果。离开后请先查看词库再重新导入。'),
                if (_drafts.isEmpty) ...[
                  SelectableText(pinyinImportTemplate),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: locked
                            ? null
                            : () => Clipboard.setData(
                                const ClipboardData(text: pinyinImportTemplate),
                              ),
                        child: const Text('复制模板'),
                      ),
                      OutlinedButton(
                        onPressed: locked ? null : _pick,
                        child: const Text('选择词库文件'),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _source,
                    enabled: !locked,
                    maxLines: 7,
                    maxLength: pinyinImportMaxBytes,
                    decoration: const InputDecoration(labelText: '粘贴词库（含表头）'),
                  ),
                  FilledButton(
                    onPressed: locked ? null : _preview,
                    child: const Text('解析并逐条核对'),
                  ),
                ] else ...[
                  Text(
                    '待核对 ${_drafts.length} 条 · 已确认 ${_drafts.where((row) => row.confirmed).length} 条',
                  ),
                  TextButton(
                    onPressed: locked
                        ? null
                        : () {
                            for (final row in _drafts) {
                              row.dispose();
                            }
                            setState(_drafts.clear);
                          },
                    child: const Text('返回修改导入内容'),
                  ),
                  for (var i = 0; i < _drafts.length; i++)
                    _card(_drafts[i], i, locked),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(
                      _busy
                          ? '正在确认导入…'
                          : _pending != null
                          ? '重试同一批导入'
                          : '确认导入已核对词语',
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _card(_WordDraft row, int index, bool locked) => Card(
    key: ValueKey('pinyin-row-$index'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('第${index + 1}条'),
          for (final entry in [
            (row.word, '词语', 80),
            (row.context, '语境/例句', 2000),
            (row.reading, '确认后的拼音', 500),
            (row.knowledge, '知识点（可选）', 200),
          ])
            TextField(
              controller: entry.$1,
              enabled: !locked,
              maxLength: entry.$3,
              decoration: InputDecoration(labelText: entry.$2),
              onChanged: (_) => setState(() => row.confirmed = false),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('候选考虑“一、不”的变调'),
            value: row.sandhi,
            onChanged: locked
                ? null
                : (value) => setState(() {
                    row.sandhi = value;
                    row.confirmed = false;
                  }),
          ),
          OutlinedButton(
            onPressed: locked ? null : () => _suggest(row),
            child: const Text('填入本地候选读音'),
          ),
          if (row.hint != null) Text(row.hint!),
          const Text('候选可能读错，轻声、变调和多音字须按教材与语境审核；手工修改不会自动确认。'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('我已按语境核对本条读音'),
            value: row.confirmed,
            onChanged: locked
                ? null
                : (value) => setState(() => row.confirmed = value!),
          ),
        ],
      ),
    ),
  );
}

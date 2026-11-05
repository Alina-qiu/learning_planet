import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../../wrong_questions/data/review_repository.dart';
import '../../wrong_questions/data/question_catalog.dart';
import '../../wrong_questions/presentation/review_question_editor.dart';
import '../data/ai_repository.dart';
import '../data/similar_question_repository.dart';
import 'ai_analysis_screen.dart' show aiDifficultyLabels;
import 'ai_settings_screen.dart';

class SimilarQuestionsScreen extends ConsumerStatefulWidget {
  const SimilarQuestionsScreen({
    required this.familyId,
    required this.childId,
    required this.sourceId,
    super.key,
  });
  final String familyId, childId, sourceId;
  @override
  ConsumerState<SimilarQuestionsScreen> createState() =>
      _SimilarQuestionsScreenState();
}

class _SimilarQuestionsScreenState
    extends ConsumerState<SimilarQuestionsScreen> {
  final _query = TextEditingController(), _knowledge = TextEditingController();
  String _difficulty = 'unknown', _feedback = 'wrong_answer';
  Map<String, dynamic>? _source,
      _settings,
      _draft,
      _receipt,
      _adoption,
      _checked,
      _edited;
  List<Map<String, dynamic>> _matches = [];
  bool _busy = false,
      _consent = false,
      _showAnswers = false,
      _feedbackSent = false;
  String? _error;
  AiRepository get _ai => ref.read(aiRepositoryProvider);
  SimilarQuestionRepository get _repo =>
      ref.read(similarQuestionRepositoryProvider);
  bool get _allowed => ref.read(activeParentFamilyProvider) == widget.familyId;
  bool get _same =>
      _draft == null ||
      ((_draft!['input'] as Map)['kind'] == 'similar' &&
          (_draft!['input'] as Map)['source_question_id'] == widget.sourceId);
  String get _request => _draft!['request_id'] as String;
  Map<String, dynamic>? get _output =>
      (_receipt?['result'] as Map?)?['structured_output'] is Map
      ? Map<String, dynamic>.from(
          (_receipt!['result'] as Map)['structured_output'] as Map,
        )
      : null;
  bool get _ready =>
      _same &&
      _receipt?['status'] == 'completed' &&
      ((_receipt?['result'] as Map?)?['safety_flags'] as List? ?? ['unknown'])
          .isEmpty &&
      _output?['prompt'] is String;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _query.dispose();
    _knowledge.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_allowed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '未能确认结果。请检查网络、额度或家长授权，再核对原请求；不会自动重新生成或重复保存。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final settings = await _ai.context(widget.childId);
    var draft = await _ai.pending(widget.childId);
    if (draft != null && draft['generation'] != settings['generation']) {
      await _ai.dismiss(widget.childId, draft['request_id'] as String);
      draft = null;
    }
    if (!mounted || !_allowed) return;
    setState(() {
      _settings = settings;
      _draft = draft;
      _receipt = null;
      _adoption = null;
      _edited = null;
      _showAnswers = false;
    });
    if (draft != null && _same) await _inspect();
    final source = await _repo.context(widget.childId, widget.sourceId);
    if (!mounted || !_allowed) return;
    if (source['family_id'] != widget.familyId) throw StateError('家庭不匹配');
    setState(() {
      _source = source;
      _knowledge.text = source['input']['knowledge_point'] as String;
      _difficulty = source['input']['difficulty'] as String;
    });
    await _search();
  });
  Future<void> _search() async {
    final rows = await _repo.search(
      widget.childId,
      widget.sourceId,
      _query.text.trim(),
    );
    if (mounted && _allowed) setState(() => _matches = rows);
  }

  Future<void> _inspect() async {
    final adoption = await _repo.inspect(widget.childId, _request);
    final receipt = await _ai.resolve(widget.childId, _request, 'inspect');
    if (mounted && _allowed) {
      setState(() {
        _receipt = receipt;
        _adoption = adoption;
      });
    }
  }

  Future<void> _generate() => _run(() async {
    if (!_consent ||
        !_same ||
        _settings?['enabled'] != true ||
        _settings?['available'] != true) {
      return;
    }
    final input = {
      ...Map<String, dynamic>.from(_source!['input'] as Map),
      'knowledge_point': _knowledge.text.trim(),
      'difficulty': _difficulty,
    };
    final draft =
        _draft ??
        await _ai.prepare(
          widget.familyId,
          widget.childId,
          input,
          generation: _settings!['generation'] as int,
        );
    if (!mounted || !_allowed) return;
    setState(() => _draft = draft);
    if (!_same) return;
    await _inspect();
    if (!mounted || !_allowed || _receipt?['status'] != 'unknown') return;
    final result = await _ai.resolve(widget.childId, _request, 'submit');
    if (mounted && _allowed) setState(() => _receipt = result);
  });
  Future<void> _saveOriginal() async {
    final status = await _repo.inspect(widget.childId, _request);
    final result = status['status'] == 'unknown'
        ? await _repo.save(widget.childId, _request)
        : status;
    if (mounted && _allowed) {
      setState(() => _adoption = result);
      ref.invalidate(reviewQuestionsProvider(widget.childId));
      ref.invalidate(questionCatalogRepositoryProvider);
    }
  }

  Future<void> _approve(Map<String, dynamic> fields) async {
    if (!_ready || !_showAnswers || _draft?['approval'] != null) return;
    if (fields['subject'] != _output!['subject']) {
      setState(() {
        _error = null;
        _checked = {
          'status': 'failed',
          'message': '本次生成绑定原题学科。请在编辑中恢复原学科，或选择对应学科的原题重新生成。审核内容尚未冻结。',
        };
      });
      return;
    }
    final config = <String, dynamic>{
      for (final key in [
        'prompt',
        'answers',
        'subject',
        'knowledge_point',
        'explanation',
      ])
        key: fields[key] ?? '',
      'difficulty': _output!['difficulty'],
      'reviewed': true,
    };
    Map<String, dynamic>? checked;
    await _run(() async {
      await _inspect();
      if (!_ready) return;
      checked = await _repo.check(widget.childId, config);
      if (mounted && _allowed) setState(() => _checked = checked);
    });
    if (!mounted ||
        !_allowed ||
        checked == null ||
        checked!['status'] == 'failed') {
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认采纳 AI 练习题'),
        content: Text(
          '${checked!['message']}\n\n请确认已核对题干、全部标准答案和解析，包括低置信度内容。保存后进入错题库与复习队列，保留 AI 来源和版本；它作为已审核题目保存，不受临时 AI 结果保留期限制。录入不发奖。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('我已逐项核对，确认保存'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _run(() async {
      final draft = await _repo.prepareApproval(
        widget.childId,
        _request,
        config,
      );
      if (!mounted || !_allowed) return;
      setState(() => _draft = draft);
      await _saveOriginal();
    });
  }

  Future<void> _end() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束原请求或重新生成'),
        content: const Text(
          '将清除本次临时结果及本机审核内容，并阻止尚未完成的采纳。已经保存到题库的题目会保留。已发送的请求无法撤回，额度不退还；再次生成计为新请求。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结束原请求'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _run(() async {
      await _ai.dismiss(widget.childId, _request);
      if (mounted) {
        setState(() {
          _draft = null;
          _receipt = null;
          _adoption = null;
          _consent = false;
          _showAnswers = false;
          _checked = null;
          _edited = null;
          _feedbackSent = false;
        });
      }
    });
    if (mounted && _draft == null) await _load();
  }

  Future<void> _view(Map<String, dynamic> row) => _run(() async {
    final question = await _repo.question(widget.childId, row['id'] as String);
    if (!mounted || !_allowed) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            _CandidateScreen(familyId: widget.familyId, question: question),
      ),
    );
  });

  Future<void> _edit() async {
    final candidate = _edited ?? _output!;
    final edited = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => Consumer(
          builder: (context, ref, _) =>
              ref.watch(activeParentFamilyProvider) == widget.familyId
              ? ReviewQuestionEditor(
                  pinyin: false,
                  collectErrorReasons: false,
                  initial: {
                    ...candidate,
                    'final_text': candidate['prompt'],
                    'ai_generated': true,
                  },
                )
              : const Scaffold(body: Center(child: Text('家长授权已到期，请返回后重新验证'))),
        ),
      ),
    );
    if (mounted && _allowed && edited != null) {
      setState(() {
        _edited = edited;
        _checked = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final result = _receipt?['result'] as Map?;
    final flags = result?['safety_flags'] as List? ?? [];
    final approved = _adoption?['status'] == 'saved',
        removed = _adoption?['status'] == 'deleted';
    final frozen = _draft?['approval'] as Map?;
    final candidate = _edited ?? _output;
    return Scaffold(
      appBar: AppBar(title: const Text('相似题与练习建议')),
      body: !allowed
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                Text(
                  '从当前孩子的题库查找',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text('优先显示相同知识点，其余为同学科候选，最多20题；匹配标签不代表题目难度或解法相同。'),
                TextField(
                  controller: _query,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '题干或知识点关键词'),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _run(_search),
                  child: const Text('查找题库'),
                ),
                if (_matches.isEmpty && !_busy)
                  const Text('暂未找到候选，可以修改关键词或生成练习建议。'),
                for (final row in _matches)
                  ListTile(
                    title: Text(
                      '${row['ai_generated'] == true ? '【AI生成·家长已审核】' : ''}${row['final_text']}',
                    ),
                    subtitle: Text(
                      row['match_reason'] == 'knowledge'
                          ? '相同知识点'
                          : '同学科候选，需核对关联',
                    ),
                    onTap: _busy ? null : () => _view(row),
                  ),
                const Divider(height: 32),
                Text(
                  'AI 生成一题练习建议',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text(
                  'AI 生成内容可能有误，必须家长审核。只发送原题文字、学科、年级、知识点和目标难度；不发送图片、孩子姓名、作答历史或标准答案。第三方模型可能保留安全审查记录。',
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  AiSettingsScreen(familyId: widget.familyId),
                            ),
                          );
                          if (mounted) await _load();
                        },
                  child: const Text('AI 与隐私设置'),
                ),
                if (!_same)
                  const Text('当前孩子还有另一题、分类或周报的未结束请求。请返回原页面核对，或明确结束原请求后继续。'),
                if (_source != null && _draft == null) ...[
                  Text('原题：${_source!['input']['text']}'),
                  TextField(
                    controller: _knowledge,
                    maxLength: 120,
                    decoration: const InputDecoration(labelText: '希望练习的知识点'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _difficulty,
                    decoration: const InputDecoration(labelText: '目标难度'),
                    items: [
                      for (final entry in aiDifficultyLabels.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _difficulty = v!),
                  ),
                ],
                if (_draft != null && _same)
                  Text('已冻结原题：${(_draft!['input'] as Map)['text']}'),
                if (_same &&
                    (_draft == null || _receipt?['status'] == 'unknown')) ...[
                  CheckboxListTile(
                    value: _consent,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _consent = v!),
                    title: const Text('已去除隐私信息，同意发送以上内容生成本次练习'),
                  ),
                  FilledButton(
                    onPressed:
                        _busy ||
                            !_consent ||
                            _source == null ||
                            _settings?['enabled'] != true ||
                            _settings?['available'] != true
                        ? null
                        : _generate,
                    child: const Text('生成本次练习'),
                  ),
                  if (_settings?['enabled'] != true ||
                      _settings?['available'] != true)
                    const Text('家庭 AI 未启用或服务尚未开放，仍可使用题库检索。'),
                ],
                if (_draft != null) ...[
                  if (_same)
                    Text(
                      '请求状态：${const {'unknown': '尚未提交', 'running': '处理中或结果尚未确认', 'completed': '已生成，待审核', 'failed': '未获得有效结果', 'cancelled': '已结束', 'discarded': '已清除', 'expired': '已过期'}[_receipt?['status']] ?? '待核对'}',
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (_same)
                        TextButton(
                          onPressed: _busy ? null : () => _run(_inspect),
                          child: const Text('核对原请求'),
                        ),
                      TextButton(
                        onPressed: _busy ? null : _end,
                        child: const Text('结束或重新生成'),
                      ),
                    ],
                  ),
                ],
                if (flags.isNotEmpty)
                  const Text('本次内容不适合继续普通练习。请由可信任的成年人核对原题与孩子的实际情况。'),
                if (approved)
                  const Text('已保存到题库，可在错题本中继续编辑、复习或选入练习卷；本次保存没有发奖。'),
                if (removed) const Text('这次采纳的题目已删除，重复请求不会重新创建。'),
                if (_ready && !approved && !removed) ...[
                  const Text('【AI 生成 · 待家长审核】'),
                  Text(
                    '模型：${result!['model_version']} · 提示版本：${result['prompt_version']}',
                  ),
                  if ((result['confidence'] as num) < .8)
                    const Text('低置信度建议：请重点核对全部题目条件、答案和解析。'),
                  Text((frozen?['prompt'] ?? candidate!['prompt']) as String),
                  Text(
                    (_checked ?? _output!['answer_check'] as Map?)?['message']
                            as String? ??
                        '需核对答案与解析',
                  ),
                  SwitchListTile(
                    value: _showAnswers,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _showAnswers = v),
                    title: const Text('显示答案与解析，开始审核'),
                  ),
                  if (frozen != null) ...[
                    const Text('已保存本机审核内容，正在核对原保存请求；结果未知时不能改写内容。'),
                    if (_showAnswers)
                      Text(
                        '标准答案：${(frozen['answers'] as List).join('；')}\n解析：${frozen['explanation']}',
                      ),
                    FilledButton(
                      onPressed: _busy ? null : () => _run(_saveOriginal),
                      child: const Text('核对并继续原保存请求'),
                    ),
                  ] else if (_showAnswers) ...[
                    Text('标准答案：${(candidate!['answers'] as List).join('；')}'),
                    Text('解析：${candidate['explanation']}'),
                    TextButton(
                      onPressed: _busy ? null : _edit,
                      child: const Text('编辑题目、答案与解析'),
                    ),
                    FilledButton(
                      onPressed: _busy ? null : () => _approve(candidate),
                      child: const Text('复算并确认采纳'),
                    ),
                  ],
                ],
                if (_draft != null && _same && result != null) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _feedback,
                    decoration: const InputDecoration(labelText: '这条练习建议有问题'),
                    items: const [
                      DropdownMenuItem(
                        value: 'wrong_answer',
                        child: Text('答案或解析有误'),
                      ),
                      DropdownMenuItem(
                        value: 'not_similar',
                        child: Text('与原题不相似'),
                      ),
                      DropdownMenuItem(value: 'unclear', child: Text('题意不清楚')),
                      DropdownMenuItem(value: 'unsafe', child: Text('内容不适合孩子')),
                      DropdownMenuItem(value: 'other', child: Text('其他问题')),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _feedback = v!),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _repo.feedback(
                              widget.childId,
                              _request,
                              _feedback,
                            );
                            if (mounted) setState(() => _feedbackSent = true);
                          }),
                    child: Text(_feedbackSent ? '反馈已记录' : '提交反馈'),
                  ),
                  const Text('反馈记录问题类型与模型版本，不发送题目全文，也不会自动重试付费生成。'),
                ],
              ],
            ),
    );
  }
}

class _CandidateScreen extends ConsumerWidget {
  const _CandidateScreen({required this.familyId, required this.question});
  final String familyId;
  final Map<String, dynamic> question;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('题库候选')),
    body: ref.watch(activeParentFamilyProvider) != familyId
        ? const Center(child: Text('家长授权已到期，请返回后重新验证'))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (question['ai_generated'] == true) const Text('【AI生成·家长已审核】'),
              Text(question['final_text'] as String),
              ExpansionTile(
                title: const Text('显示答案与解析'),
                children: [
                  Text(
                    '标准答案：${(question['answers'] as List? ?? []).join('；')}',
                  ),
                  Text(question['explanation'] as String? ?? ''),
                ],
              ),
              const Text('可返回错题本将本题选入练习卷。'),
            ],
          ),
  );
}

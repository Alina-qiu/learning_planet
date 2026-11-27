import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../ai/data/ai_repository.dart';
import '../../ai/presentation/ai_settings_screen.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/ai_weekly_report_repository.dart';
import '../domain/learning_report.dart';

const weeklyEvidenceLabels = {
  'tasks': '到期任务与计时',
  'daily': '逐日任务趋势',
  'activities': '实际完成记录',
  'reviews': '复测作答',
  'due_now': '当前到期复习',
  'coins': '金币产消',
};

class AiWeeklyReportScreen extends StatelessWidget {
  const AiWeeklyReportScreen({
    required this.familyId,
    required this.childId,
    required this.endDate,
    super.key,
  });
  final String familyId, childId, endDate;
  @override
  Widget build(BuildContext context) => _WeeklyReport(
    key: ValueKey((familyId, childId, endDate)),
    familyId: familyId,
    childId: childId,
    endDate: endDate,
  );
}

class _WeeklyReport extends ConsumerStatefulWidget {
  const _WeeklyReport({
    required this.familyId,
    required this.childId,
    required this.endDate,
    super.key,
  });
  final String familyId, childId, endDate;
  @override
  ConsumerState<_WeeklyReport> createState() => _WeeklyReportState();
}

class _WeeklyReportState extends ConsumerState<_WeeklyReport> {
  Map<String, dynamic>? _settings, _source, _draft, _receipt;
  final Set<String> _feedback = {};
  bool _busy = false, _consent = false;
  bool _closed = false;
  late final String? _owner;
  late final int _revision;
  ValueNotifier<Map?>? _openEvidence;
  String? _error;
  AiRepository get _ai => ref.read(aiRepositoryProvider);
  AiWeeklyReportRepository get _reports =>
      ref.read(aiWeeklyReportRepositoryProvider);
  bool get _allowed =>
      mounted &&
      !_closed &&
      ref.read(activeParentFamilyProvider) == widget.familyId &&
      ref.read(authAccountIdProvider) == _owner &&
      ref.read(parentAuthorizationRevisionProvider) == _revision;
  bool get _same =>
      _draft == null ||
      ((_draft!['input'] as Map)['kind'] == 'weekly_report' &&
          (_draft!['input'] as Map)['end_date'] == widget.endDate);
  String get _request => _draft!['request_id'] as String;
  Map? get _input =>
      _same ? (_draft?['input'] ?? _source?['input']) as Map? : null;
  Map? get _result => _receipt?['result'] as Map?;
  bool get _ready =>
      _same &&
      _receipt?['status'] == 'completed' &&
      _result?['prompt_version'] == 'weekly-report-v1' &&
      ((_result?['safety_flags'] as List?) ?? ['unknown']).isEmpty &&
      _result?['evidence'] is Map;
  @override
  void initState() {
    super.initState();
    _owner = ref.read(authAccountIdProvider);
    _revision = ref.read(parentAuthorizationRevisionProvider);
    Future.microtask(_load);
  }

  @override
  void dispose() {
    if (_openEvidence != null) {
      // The detail route can outlive its report when the selected child changes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openEvidence?.value = null;
      });
    }
    super.dispose();
  }

  void _closeAccess() {
    if (!mounted || _closed) return;
    setState(() {
      _closed = true;
      _settings = _source = _draft = _receipt = null;
      _consent = false;
      _feedback.clear();
      _error = null;
    });
    _openEvidence?.value = null;
  }

  bool _denied(Object error) =>
      error is PostgrestException &&
          const {
            '42501',
            '401',
            '403',
            'PGRST301',
            'PGRST303',
          }.contains(error.code) ||
      error is AuthSessionMissingException ||
      error is AuthException &&
          const {'401', '403'}.contains(error.statusCode) ||
      error is FunctionException &&
          (error.status == 401 ||
              error.status == 403 &&
                  error.details is Map &&
                  error.details['error'] == 'AI_ACCESS_DENIED');

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_allowed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (_allowed && _denied(error)) {
        _closeAccess();
      } else if (mounted && _allowed) {
        setState(
          () => _error = '未能确认结果。请先核对原请求；若数据已变化，可结束本次请求后重新查看统计。不会自动重新付费生成。',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未能确认结果，请核对原请求；不会自动重新生成。')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final source = await _reports.context(widget.childId, widget.endDate);
    if (!_allowed) return;
    if (source['family_id'] != widget.familyId) {
      _closeAccess();
      return;
    }
    final settings = await _ai.context(widget.childId);
    if (!_allowed) return;
    var draft = await _ai.pending(widget.childId);
    if (!_allowed) return;
    if (draft != null && draft['generation'] != settings['generation']) {
      setState(() {
        _draft = _receipt = _source = null;
        _feedback.clear();
      });
      await _ai.dismiss(widget.childId, draft['request_id'] as String);
      draft = null;
    }
    if (!mounted || !_allowed) return;
    setState(() {
      _settings = settings;
      if (draft == null || _draft?['request_id'] != draft['request_id']) {
        _receipt = null;
        _feedback.clear();
      }
      _draft = draft;
      _consent = false;
      _source = source;
    });
    if (draft != null && _same) await _inspect();
  });
  Future<void> _inspect() async {
    if (!_allowed) return;
    final Map<String, dynamic> receipt;
    try {
      receipt = await _ai.resolve(widget.childId, _request, 'inspect');
    } catch (error) {
      if (!_allowed) return;
      if (!_denied(error)) rethrow;
      _closeAccess();
      return;
    }
    if (!_allowed) return;
    setState(() => _receipt = receipt);
    _openEvidence?.value = _ready
        ? (_result!['evidence'] as Map)['snapshot'] as Map
        : null;
  }

  Future<void> _generate() => _run(() async {
    if (!_same ||
        !_consent ||
        _input == null ||
        _settings?['enabled'] != true ||
        _settings?['available'] != true) {
      return;
    }
    final draft =
        _draft ??
        await _ai.prepare(
          widget.familyId,
          widget.childId,
          Map<String, dynamic>.from(_input!),
          generation: _settings!['generation'] as int,
        );
    if (!mounted || !_allowed) return;
    setState(() => _draft = draft);
    if (!_same) return;
    await _inspect();
    if (!mounted || !_allowed || _receipt?['status'] != 'unknown') return;
    final receipt = await _ai.resolve(widget.childId, _request, 'submit');
    if (mounted && _allowed) setState(() => _receipt = receipt);
  });
  Future<void> _end() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束当前 AI 请求'),
        content: const Text(
          '清除本服务保存的本次临时结果与数据快照，并阻止迟到结果；已保存题目和学习记录保留。已经发出的模型请求无法撤回，额度不退回。再次生成需要重新同意并占用新额度。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认结束'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _run(() async {
      await _ai.dismiss(widget.childId, _request);
      if (mounted && _allowed) {
        setState(() {
          _draft = null;
          _receipt = null;
          _source = null;
          _consent = false;
          _feedback.clear();
        });
      }
    });
    if (mounted && _draft == null) await _load();
  }

  Future<void> _viewEvidence(List ids) => _run(() async {
    await _inspect();
    if (!mounted || !_allowed || !_ready) return;
    final evidence = ValueNotifier<Map?>(
      (_result!['evidence'] as Map)['snapshot'] as Map,
    );
    _openEvidence = evidence;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => _EvidenceScreen(
            evidence: evidence,
            ids: ids.cast<String>(),
            allowed: () => _allowed,
            refresh: _inspect,
          ),
        ),
      );
    } finally {
      _openEvidence = null;
      evidence.dispose();
    }
  });
  Future<void> _sendFeedback(String key) => _run(() async {
    await _inspect();
    if (!_ready || !_allowed) return;
    await _reports.feedback(widget.childId, _request, key);
    if (mounted && _allowed) setState(() => _feedback.add(key));
  });
  Widget _statement(Map item, String key, String label) => Card(
    margin: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          SelectableText(item['text'] as String),
          TextButton(
            key: ValueKey('evidence:$key'),
            onPressed: _busy
                ? null
                : () => _viewEvidence(item['evidence_ids'] as List),
            child: Text(
              '查看依据：${(item['evidence_ids'] as List).map((id) => weeklyEvidenceLabels[id]).join('、')}',
            ),
          ),
          TextButton(
            key: ValueKey('feedback:$key'),
            onPressed: _busy || _feedback.contains(key)
                ? null
                : () => _sendFeedback(key),
            child: Text(_feedback.contains(key) ? '已记录反馈' : '这条建议不准确'),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(activeParentFamilyProvider, (_, family) {
      if (family != widget.familyId) _closeAccess();
    });
    ref.listen(authAccountIdProvider, (_, owner) {
      if (owner != _owner) _closeAccess();
    });
    ref.listen(parentAuthorizationRevisionProvider, (_, _) => _closeAccess());
    final allowed = _allowed;
    final output = _ready ? _result!['structured_output'] as Map : null;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 学习周报')),
      body: !allowed
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                const Text('AI 解读仅供家长参考，可能不准确。不会修改任务、金币或掌握状态。'),
                const Text('只发送下方日期与汇总数字，不发送姓名、题目、答案、任务标题或图片。第三方模型可能保留安全审查记录。'),
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
                if (_settings != null &&
                    (_settings!['enabled'] != true ||
                        _settings!['available'] != true))
                  const Text('AI 尚未启用或服务不可用；原有统计报告仍可查看。'),
                if (!_same)
                  const Text('当前孩子有另一项 AI 请求或其他日期的周报。请返回对应入口核对，或结束原请求后继续。'),
                if (_input != null)
                  ExpansionTile(
                    title: const Text('查看本次发送的汇总数据'),
                    subtitle: Text(
                      '${(_input!['snapshot'] as Map)['start_date']} 至 ${_input!['end_date']}',
                    ),
                    children: [
                      _EvidenceBody(
                        snapshot: _input!['snapshot'] as Map,
                        ids: weeklyEvidenceLabels.keys.toList(),
                      ),
                    ],
                  ),
                if (_same &&
                    _input != null &&
                    (_draft == null || _receipt?['status'] == 'unknown')) ...[
                  CheckboxListTile(
                    value: _consent,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _consent = value!),
                    title: const Text('同意发送以上汇总数据，生成本次周报'),
                  ),
                  FilledButton(
                    onPressed:
                        _busy ||
                            !_consent ||
                            _settings?['enabled'] != true ||
                            _settings?['available'] != true
                        ? null
                        : _generate,
                    child: const Text('生成本次 AI 周报'),
                  ),
                ],
                if (_draft != null) ...[
                  if (_same)
                    Text(
                      '请求状态：${const {'unknown': '尚未提交', 'running': '处理中或结果尚未确认', 'completed': '已生成', 'failed': '未获得有效结果', 'cancelled': '已结束', 'discarded': '已清除', 'expired': '已过期'}[_receipt?['status']] ?? '待核对'}',
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
                if (_same &&
                    (_result?['safety_flags'] as List? ?? []).isNotEmpty)
                  const Text('本次结果被安全检查拦截或模型拒答，未展示普通建议。请由家长核对。'),
                if (_ready) ...[
                  const Text('AI 生成 · 请核对每条结论的数据依据'),
                  Text(
                    '模型：${_result!['model_version']} · 提示版本：${_result!['prompt_version']}',
                  ),
                  Text(
                    '数据快照：${_receipt!['created_at'] ?? '本次请求'}；后续同步可能改变原始统计。',
                  ),
                  if ((_result!['confidence'] as num) < .8)
                    const Text('低置信度建议：请重点核对结论与数据，置信度不等于正确率。'),
                  for (
                    var i = 0;
                    i < (output!['summaries'] as List).length;
                    i++
                  )
                    _statement(
                      output['summaries'][i] as Map,
                      'summary:$i',
                      '事实摘要 ${i + 1}',
                    ),
                  _statement(
                    output['recommendation'] as Map,
                    'recommendation',
                    '下一步建议',
                  ),
                  const Text('反馈只记录条目和模型版本，不附带自由文字，也不会自动重新生成。'),
                ],
                if (_source == null && !_busy)
                  TextButton(onPressed: _load, child: const Text('重新读取统计')),
              ],
            ),
    );
  }
}

class _EvidenceScreen extends StatefulWidget {
  const _EvidenceScreen({
    required this.evidence,
    required this.ids,
    required this.allowed,
    required this.refresh,
  });
  final ValueNotifier<Map?> evidence;
  final List<String> ids;
  final bool Function() allowed;
  final Future<void> Function() refresh;
  @override
  State<_EvidenceScreen> createState() => _EvidenceScreenState();
}

class _EvidenceScreenState extends State<_EvidenceScreen>
    with WidgetsBindingObserver {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (_checking || !widget.allowed() || widget.evidence.value == null) return;
    setState(() => _checking = true);
    try {
      await widget.refresh();
    } catch (_) {
      if (mounted && widget.allowed()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能核对这份依据，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map?>(
    valueListenable: widget.evidence,
    builder: (context, snapshot, _) => Scaffold(
      appBar: AppBar(
        title: const Text('这条结论的数据依据'),
        actions: [
          if (snapshot != null && widget.allowed())
            IconButton(
              tooltip: '核对依据',
              onPressed: _checking ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: !widget.allowed()
          ? const Center(child: Text('家长授权已到期，请返回后重新验证'))
          : snapshot == null
          ? const Center(child: Text('这份周报的依据已失效，请返回周报。'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _EvidenceBody(snapshot: snapshot, ids: widget.ids),
            ),
    ),
  );
}

class _EvidenceBody extends StatelessWidget {
  const _EvidenceBody({required this.snapshot, required this.ids});
  final Map snapshot;
  final List<String> ids;
  @override
  Widget build(BuildContext context) {
    final tasks = snapshot['tasks'] as Map,
        reviews = snapshot['reviews'] as Map,
        coins = snapshot['coins'] as Map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${snapshot['start_date']} 至 ${snapshot['end_date']} · 按家庭日期汇总'),
        const Text('这是本次生成所用的数据快照，不是实时查询。零样本不表示能力或掌握程度。'),
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  weeklyEvidenceLabels[id]!,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (id == 'tasks') ...[
                  Text(
                    '完成 ${tasks['completed']} / ${tasks['expected']} 项；已保存计时 ${reportDuration(tasks['effective_seconds'] as num)}',
                  ),
                  const Text('按到期日期分组的已生成任务，剔除已批准请假。计时归属于这些任务，不等同于该周实际用时。'),
                ],
                if (id == 'daily') ...[
                  for (final day in snapshot['days'] as List)
                    Text(
                      '${day['day']}：完成 ${day['completed']} / ${day['expected']} 项，计时 ${reportDuration(day['effective_seconds'] as num)}',
                    ),
                  const Text('与到期任务口径一致；历史数值会受后续补签影响。'),
                ],
                if (id == 'activities')
                  Text(
                    '日期范围内实际完成 ${snapshot['activity_count']} 项，按完成时间统计，可能与到期任务数不同。',
                  ),
                if (id == 'reviews')
                  Text(
                    '已判定作答 ${reviews['answered']} 次，正确 ${reviews['correct']} 次；没有作答时不计算正确率。',
                  ),
                if (id == 'due_now')
                  Text(
                    '截至 ${snapshot['as_of_date']}，到期未掌握题 ${snapshot['due_now']} 道。排除归档、已掌握及删除中的题目；不是历史周末状态。',
                  ),
                if (id == 'coins')
                  Text(
                    '收入 ${coins['income']}，已履约消耗 ${coins['spent']}，其他调减 ${coins['adjustment_out']}。按入账时间统计，冻结与退款不计入产消。',
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

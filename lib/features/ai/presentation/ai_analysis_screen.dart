import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/ai_repository.dart';
import 'ai_settings_screen.dart';

const aiReasonLabels = {
  'concept': '概念理解待核对',
  'calculation': '计算过程待核对',
  'reading': '审题过程待核对',
  'method': '解题方法待核对',
  'unknown': '暂无足够信息',
};
const aiDifficultyLabels = {
  'easy': '较容易',
  'medium': '中等',
  'hard': '较难',
  'unknown': '无法判断',
};

class AiAnalysisScreen extends ConsumerStatefulWidget {
  const AiAnalysisScreen({
    required this.familyId,
    required this.childId,
    required this.input,
    super.key,
  });
  final String familyId, childId;
  final Map<String, dynamic> input;
  @override
  ConsumerState<AiAnalysisScreen> createState() => _AiAnalysisScreenState();
}

class _AiAnalysisScreenState extends ConsumerState<AiAnalysisScreen> {
  Map<String, dynamic>? _settings, _draft, _receipt;
  bool _busy = false, _consent = false, _reviewed = false;
  String? _error;
  AiRepository get _repo => ref.read(aiRepositoryProvider);
  Map<String, dynamic> get _input =>
      (_draft?['input'] as Map?)?.cast<String, dynamic>() ?? widget.input;
  bool get _same =>
      _input['kind'] == null &&
      _input['text'] == widget.input['text'] &&
      _input['subject'] == widget.input['subject'];
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || ref.read(activeParentFamilyProvider) != widget.familyId) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '未能确认结果，请检查网络、额度和家长授权，再核对原请求。不会自动再次发送。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final settings = await _repo.context(widget.childId);
    final draft = await _repo.pending(widget.childId);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _draft = draft;
      _receipt = null;
      _reviewed = false;
    });
    if (draft != null) await _inspect();
  });
  Future<void> _inspect() async {
    final receipt = await _repo.resolve(
      widget.childId,
      _draft!['request_id'] as String,
      'inspect',
    );
    if (mounted) setState(() => _receipt = receipt);
  }

  Future<void> _submit() => _run(() async {
    if (_input['kind'] != null ||
        !_consent ||
        _settings?['enabled'] != true ||
        _settings?['available'] != true) {
      return;
    }
    final draft =
        _draft ??
        await _repo.prepare(
          widget.familyId,
          widget.childId,
          widget.input,
          generation: _settings!['generation'] as int,
        );
    if (!mounted) return;
    setState(() => _draft = draft);
    await _inspect();
    if (!mounted ||
        _receipt?['status'] != 'unknown' ||
        ref.read(activeParentFamilyProvider) != widget.familyId) {
      return;
    }
    final receipt = await _repo.resolve(
      widget.childId,
      draft['request_id'] as String,
      'submit',
    );
    if (mounted) setState(() => _receipt = receipt);
  });
  Future<void> _end() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束本次分析'),
        content: const Text(
          '清除本服务保存的本次建议并阻止迟到结果；已经保存到题库的题目会保留。已发送的请求无法撤回，预算占用不会退回。之后如再次发送，会作为新请求计入额度。',
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
      await _repo.dismiss(widget.childId, _draft!['request_id'] as String);
      if (mounted) {
        setState(() {
          _draft = null;
          _receipt = null;
          _consent = false;
          _reviewed = false;
        });
      }
    });
  }

  Future<void> _apply() => _run(() async {
    if (!_reviewed || !_same) return;
    // Recheck server state: another parent may have disabled AI or removed output.
    await _inspect();
    if (!mounted ||
        _receipt?['status'] != 'completed' ||
        _receipt?['result'] == null) {
      return;
    }
    final current = Map<String, dynamic>.from(_receipt!['result'] as Map);
    if ((current['safety_flags'] as List).isNotEmpty) return;
    await _repo.dismiss(widget.childId, _draft!['request_id'] as String);
    if (mounted && ref.read(activeParentFamilyProvider) == widget.familyId) {
      Navigator.pop(context, {'input': _input, 'result': current});
    }
  });
  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final result = (_receipt?['result'] as Map?)?.cast<String, dynamic>();
    final output = result?['structured_output'] as Map?;
    final flags = result?['safety_flags'] as List? ?? [];
    final status = _receipt?['status'];
    final confidence = (result?['confidence'] as num?)?.toDouble() ?? 0;
    final ready =
        _input['kind'] == null &&
        status == 'completed' &&
        output != null &&
        flags.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 分类建议')),
      body: !allowed
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                const Text(
                  '发送前请删除姓名、学校、班级、联系方式等隐私。只发送下方文字、学科及孩子年级；不发送照片、昵称、答案和学习记录。',
                ),
                if (!_same)
                  const Text(
                    '正在恢复之前的请求，与当前编辑内容不同。分类、相似题或周报请返回对应页面核对，或结束原请求后再继续。',
                  ),
                SelectableText(
                  _input['text'] as String? ?? '当前为学习周报请求，请返回周报查看。',
                ),
                if (_settings != null)
                  Text('年级：${_settings!['grade']}（按当前孩子档案）'),
                if (_input['subject'] != null)
                  Text(
                    '学科：${{'math': '数学', 'chinese': '语文', 'english': '英语'}[_input['subject']]}',
                  ),
                const Text('第三方模型可能保留安全审查记录。AI 会出错；错因仅是候选，需要结合作答判断。'),
                if (_settings != null &&
                    (_settings!['enabled'] != true ||
                        _settings!['available'] != true))
                  const Text('当前无法发送：家庭 AI 未启用或服务尚未开放。可继续手工录题。'),
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
                  child: const Text('查看 AI 与隐私设置'),
                ),
                if (_draft == null || status == 'unknown') ...[
                  CheckboxListTile(
                    value: _consent,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _consent = v!),
                    title: const Text('我已去除隐私信息，同意发送这些文字进行本次分析'),
                  ),
                  FilledButton(
                    onPressed:
                        _busy ||
                            _input['kind'] != null ||
                            !_consent ||
                            _settings?['enabled'] != true ||
                            _settings?['available'] != true
                        ? null
                        : _submit,
                    child: const Text('发送本次分析'),
                  ),
                ],
                if (_draft != null) ...[
                  Text(
                    '请求状态：${{'unknown': '尚未提交', 'running': '处理中或结果尚未确认', 'completed': '建议待审核', 'failed': '未获得有效建议', 'cancelled': '已结束', 'discarded': '结果已清除', 'expired': '建议已过期'}[status] ?? '需要核对'}',
                  ),
                  if (status == 'running')
                    const Text('可稍后核对。即使离开页面也不会自动重复发送；长时间无结果可结束本次请求。'),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _run(_inspect),
                    child: const Text('核对原请求'),
                  ),
                ],
                if (flags.isNotEmpty)
                  const Text(
                    '这次内容不适合继续生成普通学习建议，请由家长核对。若涉及受伤、自伤、暴力或欺凌，请让孩子及时向身边可信任的成年人求助。',
                  ),
                if (ready) ...[
                  Text(
                    '建议知识点：${(output['knowledge_points'] as List).join('、')}',
                  ),
                  Text(
                    '参考难度：${aiDifficultyLabels[output['difficulty']]}（仅供审核）',
                  ),
                  Text(
                    '候选错因：${(output['error_reasons'] as List).map((v) => aiReasonLabels[v]).join('、')}',
                  ),
                  Text(
                    '模型置信度：${(confidence * 100).round()}%${confidence < .8 ? ' · 低置信，须逐项核对' : ' · 仍需家长核对'}',
                  ),
                  const Text(
                    '采纳后只填写当前草稿的知识点和候选错因，可能覆盖原有内容。请继续编辑核实，再按保存；答案、奖励和复习状态不会因此改变。',
                  ),
                  CheckboxListTile(
                    value: _reviewed,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _reviewed = v!),
                    title: const Text('我已逐项核对建议，并确认候选错因适用于这道题'),
                  ),
                  FilledButton(
                    onPressed: _busy || !_reviewed || !_same ? null : _apply,
                    child: const Text('采纳到当前草稿'),
                  ),
                ],
                if (_draft != null)
                  TextButton(
                    onPressed: _busy ? null : _end,
                    child: const Text('结束并清除本次建议'),
                  ),
                if (_settings == null)
                  OutlinedButton(
                    onPressed: _busy ? null : _load,
                    child: const Text('重新加载'),
                  ),
              ],
            ),
    );
  }
}

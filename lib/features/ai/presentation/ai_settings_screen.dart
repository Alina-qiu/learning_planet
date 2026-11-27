import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/ai_repository.dart';

class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({required this.familyId, super.key});
  final String familyId;
  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  Map<String, dynamic>? _settings;
  bool _busy = false, _enabled = false;
  int _limit = 100, _budget = 10000, _days = 7;
  String? _error;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  void _assign(Map<String, dynamic> s) {
    _settings = s;
    _enabled = s['enabled'] as bool;
    _limit = s['monthly_limit'] as int;
    _budget = s['budget_cents'] as int;
    _days = s['retention_days'] as int;
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
      if (mounted) setState(() => _error = '未能确认设置。请检查网络或重新验证家长 PIN，再刷新核对。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final s = await ref.read(aiRepositoryProvider).settings(widget.familyId);
    if (mounted) setState(() => _assign(s));
  });
  Future<void> _save() => _run(() async {
    final s = await ref
        .read(aiRepositoryProvider)
        .updateSettings(widget.familyId, _settings!['version'] as int, {
          'enabled': _enabled,
          'monthly_limit': _limit,
          'budget_cents': _budget,
          'retention_days': _days,
        });
    if (mounted) {
      setState(() => _assign(s));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AI 设置已保存')));
    }
  });
  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final manage = _settings?['can_manage'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 与隐私')),
      body: !allowed
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'AI 分析默认关闭。启用后，每次发送仍需家长确认；只分析当次题目文字、学科和年级。图片继续使用本机 OCR。',
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                if (_settings != null) ...[
                  if (_settings!['available'] != true)
                    const Text('AI 服务尚未开放，当前可以继续手工录题和本机识别。'),
                  SwitchListTile(
                    title: const Text('允许 AI 分析'),
                    value: _enabled,
                    onChanged: _busy || (!manage && !_enabled)
                        ? null
                        : (v) => setState(() => _enabled = v),
                  ),
                  const Text('关闭后停止接收新请求，并清除本服务保存的分析正文。已经发出的请求无法撤回，迟到结果会被丢弃。'),
                  DropdownButtonFormField<int>(
                    key: ValueKey('limit-$_limit'),
                    initialValue: _limit,
                    decoration: const InputDecoration(labelText: '每月请求上限'),
                    items:
                        {
                              ...[10, 50, 100, 300, 500],
                              _limit,
                            }
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('$v 次'),
                              ),
                            )
                            .toList(),
                    onChanged: _busy || !manage
                        ? null
                        : (v) => setState(() => _limit = v!),
                  ),
                  DropdownButtonFormField<int>(
                    key: ValueKey('budget-$_budget'),
                    initialValue: _budget,
                    decoration: const InputDecoration(labelText: '每月预估预算'),
                    items:
                        {
                              ...[10000, 20000, 30000],
                              _budget,
                            }
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('¥${v / 100}'),
                              ),
                            )
                            .toList(),
                    onChanged: _busy || !manage
                        ? null
                        : (v) => setState(() => _budget = v!),
                  ),
                  DropdownButtonFormField<int>(
                    key: ValueKey('retention-$_days'),
                    initialValue: _days,
                    decoration: const InputDecoration(labelText: '分析正文最长保留'),
                    items: [1, 7, 30]
                        .map(
                          (v) =>
                              DropdownMenuItem(value: v, child: Text('$v 天')),
                        )
                        .toList(),
                    onChanged: _busy || !manage
                        ? null
                        : (v) => setState(() => _days = v!),
                  ),
                  Text(
                    '本月（UTC）已用 ${_settings!['requests']} 次，预算占用 ¥${(_settings!['reserved_cents'] as num) / 100}。'
                    '每次按预估上限 ¥${(_settings!['reserve_cents'] as num) / 100} 占用，失败或结果未知也保留占用；这不是供应商实际账单。',
                  ),
                  const Text('供应商可能按其隐私政策保留安全审查记录。关闭或删除本应用资料不会自动删除供应商已有记录。'),
                  const Text('仅管理员可启用及调整额度；已授权家长均可关闭。AI 不修改金币、任务完成状态或掌握程度。'),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('保存设置'),
                  ),
                ],
                OutlinedButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('刷新设置'),
                ),
              ],
            ),
    );
  }
}

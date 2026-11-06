import 'package:flutter/material.dart';
import '../domain/reward_limits.dart';
import '../../reports/presentation/configuration_time_scope.dart';

class RewardEditor extends StatefulWidget {
  const RewardEditor({this.initial, super.key});
  final Map<String, dynamic>? initial;
  @override
  State<RewardEditor> createState() => _RewardEditorState();
}

class _RewardEditorState extends State<RewardEditor> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  bool _active = true;
  String _quotaPeriod = 'none';
  @override
  void initState() {
    super.initState();
    for (final key in [
      'title',
      'cost',
      'description',
      'rules',
      'minimum_level',
      'request_days',
      'fulfillment_days',
      'available_from',
      'available_until',
      'stock_total',
      'quota_limit',
    ]) {
      _fields[key] = TextEditingController(
        text:
            widget.initial?[key]?.toString() ??
            const {
              'minimum_level': '1',
              'request_days': '7',
              'fulfillment_days': '30',
            }[key] ??
            '',
      );
    }
    _active = widget.initial?['active'] as bool? ?? true;
    _quotaPeriod = widget.initial?['quota_period'] as String? ?? 'none';
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _save() {
    final visibleValid = _form.currentState!.validate();
    final errors = [
      for (final entry in _fields.entries)
        if (_validate(entry.key, entry.value.text) case final error?) error,
    ];
    if (!visibleValid || errors.isNotEmpty) {
      if (errors.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errors.first)));
      }
      return;
    }
    final result = <String, dynamic>{
      for (final key in _fields.keys) key: _fields[key]!.text.trim(),
      'active': _active,
      'quota_period': _quotaPeriod,
    };
    for (final key in [
      'cost',
      'minimum_level',
      'request_days',
      'fulfillment_days',
    ]) {
      result[key] = int.parse(result[key] as String);
    }
    for (final key in ['available_from', 'available_until']) {
      final raw = result[key] as String;
      result[key] = raw.isEmpty
          ? null
          : DateTime.parse(raw).toUtc().toIso8601String();
    }
    result['stock_total'] = _fields['stock_total']!.text.trim().isEmpty
        ? null
        : int.parse(_fields['stock_total']!.text.trim());
    result['quota_limit'] = _quotaPeriod == 'none'
        ? null
        : int.parse(_fields['quota_limit']!.text.trim());
    final committed =
        (widget.initial?['stock_fulfilled'] as num? ?? 0).toInt() +
        (widget.initial?['stock_reserved'] as num? ?? 0).toInt();
    if (result['stock_total'] != null &&
        (result['stock_total'] as int) < committed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('总库存不能少于已兑现与已预留数量（$committed）')));
      return;
    }
    if (result['available_from'] != null &&
        result['available_until'] != null &&
        DateTime.parse(
          result['available_until'] as String,
        ).isBefore(DateTime.parse(result['available_from'] as String))) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('结束时间不得早于开始时间')));
      return;
    }
    if (widget.initial?['version'] != null) {
      result['expected_version'] = widget.initial!['version'];
    }
    Navigator.pop(context, result);
  }

  String? _validate(String key, String? raw) {
    final value = raw?.trim() ?? '';
    if (key == 'title' && value.isEmpty) return '请输入奖励名称';
    if ((key == 'stock_total' && value.isEmpty) ||
        (key == 'quota_limit' && _quotaPeriod == 'none')) {
      return null;
    }
    final max = const {
      'cost': 1000000,
      'minimum_level': 50,
      'request_days': 30,
      'fulfillment_days': 90,
      'stock_total': 1000000,
      'quota_limit': 1000000,
    }[key];
    if (max != null) {
      final minimum = key == 'stock_total' ? 0 : 1;
      final n = int.tryParse(value);
      if (n == null || n < minimum || n > max) {
        return '${const {'cost': '价格', 'minimum_level': '解锁等级', 'request_days': '审批期限', 'fulfillment_days': '履约期限', 'stock_total': '总库存', 'quota_limit': '限次'}[key]}需为$minimum至$max的整数';
      }
    }
    if (key.startsWith('available_') &&
        value.isNotEmpty &&
        DateTime.tryParse(value) == null) {
      return '开放或结束日期格式无效';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('奖励规则配置')),
    body: Form(
      onChanged: () => ConfigurationTimeScope.activity(context),
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.initial == null)
            Wrap(
              spacing: 8,
              children: [
                for (final preset in const [
                  ('动画片30分钟', 120),
                  ('周末游戏30分钟', 220),
                  ('选择一本书', 500),
                  ('家庭电影', 1200),
                  ('喜欢的餐厅', 1800),
                  ('普通玩具', 3000),
                  ('主题乐园', 8000),
                ])
                  ActionChip(
                    label: Text('${preset.$1} ${preset.$2}金币'),
                    onPressed: () {
                      _fields['title']!.text = preset.$1;
                      _fields['cost']!.text = '${preset.$2}';
                    },
                  ),
              ],
            ),
          for (final field in const {
            'title': '名称',
            'cost': '价格（金币）',
            'description': '说明',
            'rules': '兑现规则 / 可用时间说明',
            'minimum_level': '解锁等级1–50',
            'request_days': '审批期限1–30天',
            'fulfillment_days': '批准后履约期限1–90天',
            'available_from': '开放时间（可选 ISO日期，带时区）',
            'available_until': '结束时间（可选 ISO日期，带时区）',
          }.entries)
            TextFormField(
              controller: _fields[field.key],
              decoration: InputDecoration(labelText: field.value),
              maxLength: field.key == 'title' ? 100 : 1000,
              validator: (raw) => _validate(field.key, raw),
            ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _fields['stock_total'],
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '家庭共享总库存（留空不限）',
              helperText: '含已兑现与已预留；补货时增加总量，0表示暂无库存。',
              helperMaxLines: 3,
            ),
            validator: (raw) => _validate('stock_total', raw),
          ),
          if (widget.initial != null)
            Text(
              '已兑现 ${widget.initial?['stock_fulfilled'] ?? 0} 份 · 已预留 ${widget.initial?['stock_reserved'] ?? 0} 份',
            ),
          DropdownButtonFormField<String>(
            initialValue: _quotaPeriod,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '每个孩子的兑换周期'),
            items: [
              for (final entry in rewardQuotaPeriods.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => setState(() => _quotaPeriod = value!),
          ),
          if (_quotaPeriod != 'none')
            TextFormField(
              controller: _fields['quota_limit'],
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '每个周期最多兑换次数'),
              validator: (raw) => _validate('quota_limit', raw),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '申请即预留库存和次数；拒绝、取消或过期后释放，履约后消耗。周期按家庭时区计算，已批准申请跨周期仍保留。修改规则不撤销已有申请。',
            ),
          ),
          SwitchListTile(
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('上架（下架不影响已有申请）'),
          ),
          FilledButton(onPressed: _save, child: const Text('保存奖励')),
        ],
      ),
    ),
  );
}

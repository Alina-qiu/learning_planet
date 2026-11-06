import 'package:flutter/material.dart';

/// The editor owns these drafts so hiding a rule preserves input, while only
/// active rules are validated and serialized. Controllers never enter storage.
class PlanRewardDraft {
  final key = UniqueKey();
  final threshold = TextEditingController();
  final coins = TextEditingController(text: '0');
  final xp = TextEditingController(text: '0');

  int _number(
    TextEditingController field,
    String label, {
    bool positive = false,
  }) {
    final value = int.tryParse(field.text.trim());
    if (value == null || value < (positive ? 1 : 0)) {
      throw FormatException('$label需填写${positive ? '正' : '非负'}整数');
    }
    return value;
  }

  Map<String, int> stage(int position) => {
    'completed_count': _number(threshold, '阶段 $position 完成次数', positive: true),
    'coins': _number(coins, '阶段 $position 金币'),
    'xp': _number(xp, '阶段 $position XP'),
  };

  Map<String, num> tier(int position) => {
    'minimum_rate':
        _number(threshold, '档位 $position 完成率', positive: true) / 100,
    'coins': _number(coins, '档位 $position 金币'),
    'xp': _number(xp, '档位 $position XP'),
  };

  void dispose() {
    threshold.dispose();
    coins.dispose();
    xp.dispose();
  }
}

class PlanRewardFields extends StatelessWidget {
  const PlanRewardFields({
    required this.drafts,
    required this.tiers,
    required this.basePercent,
    required this.onAdd,
    required this.onRemove,
    super.key,
  });

  final List<PlanRewardDraft> drafts;
  final bool tiers;
  final int? Function() basePercent;
  final VoidCallback onAdd;
  final ValueChanged<PlanRewardDraft> onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        tiers ? '更高终奖档位（可选）' : '阶段奖励（可选）',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text(
        tiers
            ? '计划结束时只发达到的最高档终奖，不与基础终奖或其他档位叠加。'
            : '累计完成指定次数时结算一次阶段奖励；奖励规则在创建后锁定。',
      ),
      for (var index = 0; index < drafts.length; index++)
        _row(context, drafts[index], index + 1),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text(tiers ? '添加终奖档位' : '添加阶段奖励'),
        ),
      ),
      const SizedBox(height: 16),
    ],
  );

  Widget _row(BuildContext context, PlanRewardDraft draft, int position) {
    final name = '${tiers ? '档位' : '阶段'} $position';
    Widget amount(TextEditingController controller, String unit) =>
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: '$name $unit'),
          validator: (text) {
            final value = int.tryParse(text?.trim() ?? '');
            return value == null || value < 0 ? '请输入非负整数' : null;
          },
        );

    return Card(
      key: draft.key,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(name)),
                IconButton(
                  tooltip: '移除$name',
                  onPressed: () => onRemove(draft),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            TextFormField(
              controller: draft.threshold,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '$name ${tiers ? '完成率%' : '完成次数'}',
              ),
              validator: (text) {
                final value = int.tryParse(text?.trim() ?? '');
                if (value == null || value <= 0 || (tiers && value > 100)) {
                  return tiers ? '请输入1至100的整数' : '请输入正整数';
                }
                final base = basePercent();
                if (tiers && base != null && value <= base) {
                  return '需高于基础最低完成率';
                }
                if (drafts.any(
                  (other) =>
                      other != draft &&
                      int.tryParse(other.threshold.text.trim()) == value,
                )) {
                  return tiers ? '完成率不能重复' : '完成次数不能重复';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = MediaQuery.textScalerOf(context).scale(14) > 21
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(width: width, child: amount(draft.coins, '金币')),
                    SizedBox(width: width, child: amount(draft.xp, 'XP')),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

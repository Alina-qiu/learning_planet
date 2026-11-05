import 'package:flutter/material.dart';
import '../domain/learning_report.dart';

const growthMeasures = [
  (key: 'learning', name: '学习', unit: '项', basis: '完成的学习类任务数'),
  (key: 'persistence', name: '坚持', unit: '天', basis: '有任务完成记录的天数'),
  (key: 'focus_seconds', name: '专注', unit: '', basis: '已完成任务的累计计时'),
  (key: 'exploration', name: '探索', unit: '项', basis: '完成的探索类任务数'),
  (key: 'responsibility', name: '责任', unit: '项', basis: '完成的责任类任务数'),
];

class MonthlyGrowthTrends extends StatelessWidget {
  const MonthlyGrowthTrends({required this.report, super.key});
  final LearningReport report;

  @override
  Widget build(BuildContext context) {
    final months = report.growthMonths;
    if (months.isEmpty) return const Text('暂无成长统计。');
    final latest = months.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('这些指标来自记录，不是能力评分。学习、探索和责任按任务生成时的分类计算；坚持和专注包含未分类任务及家长补签。'),
        Text(
          '${(months.first['start_date'] as String).substring(0, 7)} 至 ${(latest['start_date'] as String).substring(0, 7)} · 点击指标查看每月数值',
        ),
        if (latest['partial'] == true)
          Text('本月仅统计至 ${latest['end_date']}；前面的月份为完整月，不宜直接比较总量。'),
        for (final measure in growthMeasures)
          Builder(
            builder: (context) {
              final values = months
                  .map((m) => (m[measure.key] as num).toDouble())
                  .toList();
              final maximum = values.fold<double>(0, (a, b) => a > b ? a : b);
              String display(num value) => measure.key == 'focus_seconds'
                  ? reportDuration(value)
                  : '${value.toInt()} ${measure.unit}';
              return ExpansionTile(
                key: PageStorageKey(measure.key),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${measure.name} · ${display(latest[measure.key] as num)}',
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(measure.basis),
                    const SizedBox(height: 8),
                    Semantics(
                      label: '${measure.name}月度趋势',
                      value: [
                        for (final m in months)
                          '${(m['start_date'] as String).substring(0, 7)}：${display(m[measure.key] as num)}',
                      ].join('；'),
                      child: ExcludeSemantics(
                        child: SizedBox(
                          height: 44,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var i = 0; i < values.length; i++)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                    ),
                                    child: Container(
                                      height: maximum == 0 || values[i] == 0
                                          ? 2
                                          : 42 * values[i] / maximum,
                                      color: i == values.length - 1
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.primaryContainer,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
                children: [
                  for (final month in months)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${(month['start_date'] as String).substring(0, 7)}${month['partial'] == true ? '（截至${month['end_date']}）' : ''}',
                      ),
                      subtitle: Text(display(month[measure.key] as num)),
                    ),
                ],
              );
            },
          ),
        Text(
          '本月另有 ${latest['unclassified']} 项未分类任务完成记录。可在任务配置中为今后任务选择成长分类；旧记录不推测分类。自动错题复习计入学习。',
        ),
        const Text(
          '计时按任务实际完成日期归入月份，可能包含此前日期累积的片段，不代表逐分钟专注检测。每项指标的柱高只在自身六个月内缩放；零值表示没有相关记录。',
        ),
      ],
    );
  }
}

class MonthlyKnowledgeDistribution extends StatelessWidget {
  const MonthlyKnowledgeDistribution({required this.report, super.key});
  final LearningReport report;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '新增题目按该月录入时间及当前学科、知识点统计，包含已归档题目。复测次数按实际作答时间和当次题目快照统计，一道题重复作答会分别计数。',
      ),
      const Text('分布不包含删除中或已删除的题目，因此可能少于上方复测总数；正确率仅代表已记录的复测结果。'),
      if (report.knowledgeSubjects.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('本月没有可展示的题目或复测分类记录。'),
        ),
      for (final subject in report.knowledgeSubjects)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            const {
                  'math': '数学',
                  'chinese': '语文',
                  'english': '英语',
                  'unknown': '未记录学科',
                }[subject['subject']] ??
                '未记录学科',
          ),
          subtitle: Text(
            '新增 ${subject['added']} 题 · 复测 ${subject['answered']} 次 · 正确 ${subject['correct']} 次',
          ),
          children: [
            for (final point
                in (subject['points'] as List).cast<Map<String, dynamic>>())
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  (point['knowledge_point'] as String).isEmpty
                      ? '未标注知识点'
                      : point['knowledge_point'] as String,
                ),
                subtitle: Text(
                  '新增 ${point['added']} 题 · 复测 ${point['answered']} 次 · 正确率 ${reportPercent(point['accuracy'])}',
                ),
              ),
          ],
        ),
    ],
  );
}

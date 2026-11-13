import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/report_repository.dart';
import '../domain/learning_report.dart';
import 'monthly_report_details.dart';
import 'ai_weekly_report_screen.dart';
import 'business_metrics_details.dart';
import '../../tasks/domain/task_growth_category.dart';

class LearningReportScreen extends ConsumerStatefulWidget {
  const LearningReportScreen({
    required this.childId,
    required this.familyId,
    required this.childNickname,
    this.initialPeriod = 'day',
    this.initialEndDate,
    super.key,
  });
  final String childId, familyId, childNickname;
  final String initialPeriod;
  final String? initialEndDate;

  @override
  ConsumerState<LearningReportScreen> createState() =>
      _LearningReportScreenState();
}

class _LearningReportScreenState extends ConsumerState<LearningReportScreen> {
  late String _period = widget.initialPeriod;
  late String? _endDate = widget.initialEndDate;
  ReportScope get _scope => (
    childId: widget.childId,
    familyId: widget.familyId,
    period: _period,
    endDate: _endDate,
  );

  void _move(LearningReport report, int direction) {
    final day = adjacentReportAnchor(report, _period, direction);
    final current = _period == 'month'
        ? day.substring(0, 7) == report.today.substring(0, 7)
        : day.compareTo(report.today) >= 0;
    setState(() => _endDate = current ? null : day);
  }

  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.childNickname}的学习报告')),
      body: !parent
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final period in const {
                        'day': '日报',
                        'week': '周报 · 近7天',
                        'month': '月报',
                      }.entries)
                        ChoiceChip(
                          label: Text(period.value),
                          selected: _period == period.key,
                          onSelected: (_) => setState(() {
                            _period = period.key;
                            _endDate = null;
                          }),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ref
                      .watch(learningReportProvider(_scope))
                      .when(
                        skipLoadingOnRefresh: false,
                        data: _content,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('报告读取失败。请检查网络和家长授权后重试。'),
                                TextButton(
                                  onPressed: () => ref.invalidate(
                                    learningReportProvider(_scope),
                                  ),
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ),
              ],
            ),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  Widget _content(LearningReport report) {
    final suggestion = report.suggestion;
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(learningReportProvider(_scope));
        await ref.read(learningReportProvider(_scope).future);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        children: [
          Text(
            '${report.startDate} 至 ${report.endDate}',
            textAlign: TextAlign.center,
          ),
          Text('按家庭时区 ${report.timezone} 统计', textAlign: TextAlign.center),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                onPressed:
                    adjacentReportAnchor(
                          report,
                          _period,
                          -1,
                        ).compareTo('2000-01-01') <
                        0
                    ? null
                    : () => _move(report, -1),
                child: Text(
                  _period == 'month'
                      ? '上个月'
                      : _period == 'day'
                      ? '前一天'
                      : '前7天',
                ),
              ),
              TextButton(
                onPressed: _endDate == null
                    ? null
                    : () => setState(() => _endDate = null),
                child: const Text('回到今天'),
              ),
              TextButton(
                onPressed: report.endDate == report.today
                    ? null
                    : () => _move(report, 1),
                child: Text(
                  _period == 'month'
                      ? '下个月'
                      : _period == 'day'
                      ? '后一天'
                      : '后7天',
                ),
              ),
            ],
          ),
          _section('任务与有效时长', [
            Text(
              '完成 ${report.tasks['completed']} / ${report.tasks['expected']} 项 · 完成率 ${reportPercent(report.tasks['completion_rate'])}',
            ),
            Text(
              '累计有效时长 ${reportDuration(report.tasks['effective_seconds'] as num)}',
            ),
            const Text(
              '按任务应完成日期汇总已生成实例，剔除批准请假。时长为这些任务已同步的累计计时，不含正在计时的片段；历史完成率会随补签更新。',
            ),
            if (_period == 'week') ...[
              const SizedBox(height: 12),
              _dailyTrend(report),
            ],
            if (_period == 'month')
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('逐日完成情况'),
                children: [_dailyTrend(report)],
              ),
          ]),
          if (_period == 'week')
            OutlinedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => AiWeeklyReportScreen(
                    familyId: widget.familyId,
                    childId: widget.childId,
                    endDate: report.endDate,
                  ),
                ),
              ),
              child: const Text('AI 解读这份周报（家长参考）'),
            ),
          _section('错题复测', [
            Text(
              '作答 ${report.reviews['answered']} 题 · 正确 ${report.reviews['correct']} 题',
            ),
            Text('复测正确率 ${reportPercent(report.reviews['accuracy'])}'),
            Text('截至今天待复习 ${report.dueNow} 题（含积压，不含归档、已掌握及删除中的题目）'),
          ]),
          if (report.configurationTime case final configuration?)
            _section('家长配置用时', [
              Text(configuration.label),
              const Text(
                '本报告期间、整个家庭的任务与规则编辑用时。取消编辑也计入；后台、保存后的等待，以及超过2分钟的无操作时段不计入。',
              ),
              if (configuration.samples > 0)
                Text('包含${configuration.parents}位家长的记录；同一账号的重叠用时已合并。'),
              const Text('仅统计已同步的计时记录，旧版本与缺失记录不补算。'),
              if (configuration.partialWindow)
                const Text('所选时间超出90天保留范围，仅显示仍保留的部分。'),
            ]),
          if (report.familyRetention case final retention?)
            _section('家庭回访', [
              Text(
                retention.cohortDate == null
                    ? '创建首项任务后开始观察。'
                    : '首次任务：${retention.cohortDate} · ${retention.timezone}',
              ),
              for (final day in retention.days)
                Text(
                  '${day.offset == 1 ? '次日' : '第7日'}${day.date == null ? '' : '（${day.date}）'}：${day.label}',
                ),
              const Text(
                '按家庭首次创建的非自动复习任务观察，与所选报告周期无关。前台打开应用记为活跃；观察日后预留7天离线补传。未记录到回访可能包含未同步或已清理的本地记录。',
              ),
            ]),
          if (report.startMetrics case final starts?)
            _section('自主开始', [
              Text(
                '自主开始率：${starts.unknown > 0 || starts.invalidWindows > 0 ? '记录不完整，暂不计算' : reportPercent(starts.rate)}',
              ),
              Text(
                '在时间窗内以孩子模式首次开始 ${starts.autonomous} / ${starts.eligible} 项可执行任务。',
              ),
              Text(
                '家长代开始 ${starts.parentAssisted} 项 · 孩子模式窗外开始 ${starts.outsideWindow} 项 · 未记录开始 ${starts.notStarted} 项',
              ),
              if (starts.unknown > 0)
                Text('另有 ${starts.unknown} 项已开始任务来源未知，不推算为自主开始。'),
              if (starts.futureWindows > 0)
                Text('${starts.futureWindows} 项时间窗尚未开启，暂不计入分母。'),
              if (starts.invalidWindows > 0)
                Text('${starts.invalidWindows} 项时间窗记录无效，请核对安排。'),
              const Text(
                '剔除已批准请假；优先使用任务建议开始至截止时间，未设置时采用家庭当天。开始时间包含下界，不包含截止时刻。',
              ),
              const Text('按首次点击时的设备模式记录，不识别实际操作者；暂停和继续不改写来源，不影响金币或 XP。'),
            ]),
          _section('金币与 XP', [
            Text(
              '金币收入 ${report.coins['income']} · 已履约消耗 ${report.coins['spent']}',
            ),
            Text(
              '人工等其他扣减 ${report.coins['adjustment_out']} · 获得 XP ${report.coins['xp']}',
            ),
            const Text('按入账时间统计；冻结与退款不计入产消，待确认金币在批准入账后统计。'),
          ]),
          if (report.businessMetrics case final metrics?)
            _section('奖励承诺与录入质量', [BusinessMetricsDetails(metrics: metrics)]),
          if (_period == 'month') ...[
            _section('五维成长趋势', [MonthlyGrowthTrends(report: report)]),
            _section('学科与知识点分布', [
              MonthlyKnowledgeDistribution(report: report),
            ]),
          ],
          _section('可以试试', [
            Text(suggestion.text),
            const SizedBox(height: 8),
            Text('依据：${suggestion.basis}'),
          ]),
          _section('这段时间完成的任务', [
            const Text('按实际完成时间列出，可能包含此前到期的任务。'),
            if (report.activities.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('这段时间还没有完成记录。'),
              ),
            for (final activity in report.activities)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${activity['title']}\n${(activity['completed_at'] as String).replaceFirst('T', ' ')} · ${reportDuration(activity['effective_seconds'] as num)}'
                  '\n成长分类：${TaskGrowthCategory.parse(activity['growth_category'] as String?).label}',
                ),
              ),
            if (report.activityCount > report.activities.length)
              Text(
                '共 ${report.activityCount} 项，显示最近 ${report.activities.length} 项；汇总统计包含全部记录。',
              ),
          ]),
        ],
      ),
    );
  }

  Widget _dailyTrend(LearningReport report) => Column(
    children: [
      for (final day in report.days)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${day['day']} · ${day['completed']} / ${day['expected']} 项',
              ),
              LinearProgressIndicator(
                value: (day['expected'] as num) == 0
                    ? 0
                    : (day['completed'] as num) / (day['expected'] as num),
                semanticsLabel: '${day['day']}任务完成率',
              ),
            ],
          ),
        ),
    ],
  );
}

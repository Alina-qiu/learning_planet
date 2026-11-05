import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../../economy/presentation/economy_screen.dart';
import '../../tasks/presentation/task_management_screen.dart';
import '../data/family_overview_repository.dart';
import '../domain/family_overview.dart';
import 'learning_report_screen.dart';

class FamilyOverviewScreen extends ConsumerStatefulWidget {
  const FamilyOverviewScreen({required this.familyId, super.key});
  final String familyId;
  @override
  ConsumerState<FamilyOverviewScreen> createState() =>
      _FamilyOverviewScreenState();
}

class _FamilyOverviewScreenState extends ConsumerState<FamilyOverviewScreen> {
  String? _childId;
  void _refresh() => ref.invalidate(familyOverviewProvider(widget.familyId));
  Future<void> _open(Widget screen) async {
    if (ref.read(activeParentFamilyProvider) != widget.familyId ||
        ref.read(signingOutProvider)) {
      return;
    }
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final allowed =
        ref.watch(activeParentFamilyProvider) == widget.familyId &&
        !ref.watch(signingOutProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('家庭概览'),
        actions: [
          IconButton(
            onPressed: allowed ? _refresh : null,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新家庭概览',
          ),
        ],
      ),
      body: !allowed
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('家长授权已到期，请返回首页重新验证 PIN'),
              ),
            )
          : ref
                .watch(familyOverviewProvider(widget.familyId))
                .when(
                  skipLoadingOnRefresh: false,
                  data: _content,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, __) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('暂时无法读取家庭概览。请检查网络和家长授权后重试。'),
                          FilledButton(
                            onPressed: _refresh,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _content(FamilyOverview report) {
    final selectedId = report.children.any((child) => child.id == _childId)
        ? _childId
        : null;
    final selected = report.children
        .where((child) => selectedId == null || child.id == selectedId)
        .toList();
    final days = report.trend(selected);
    return RefreshIndicator(
      onRefresh: () async {
        _refresh();
        try {
          await ref.read(familyOverviewProvider(widget.familyId).future);
        } catch (_) {
          /* Render the provider error. */
        }
      },
      child: ListView.builder(
        key: PageStorageKey('family-overview:${widget.familyId}:$selectedId'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: selected.length + 1,
        itemBuilder: (context, index) {
          if (index > 0) return _childCard(selected[index - 1]);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                report.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text('家庭日期 ${report.today} · ${report.timezone}'),
              const SizedBox(height: 8),
              const Text('以已同步的任务为准；离线记录同步后可刷新。已批准请假不计入，主动跳过仍计入应完成数。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('全部孩子'),
                    selected: selectedId == null,
                    onSelected: (_) => setState(() => _childId = null),
                  ),
                  for (final child in report.children)
                    ChoiceChip(
                      label: Text(child.nickname),
                      selected: selectedId == child.id,
                      onSelected: (_) => setState(() => _childId = child.id),
                    ),
                ],
              ),
              if (report.children.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('家庭中暂无孩子，可返回家庭设置添加孩子。'),
                )
              else ...[
                const SizedBox(height: 16),
                Text(
                  '今日完成 ${days.last.completed}/${days.last.expected} 项',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  '待审批 ${selected.fold<int>(0, (n, c) => n + c.requested)} · 待履约 ${selected.fold<int>(0, (n, c) => n + c.approved)} · 超额金币待确认 ${selected.fold<int>(0, (n, c) => n + c.pendingAwards)} 笔',
                ),
                const SizedBox(height: 16),
                Text('近七日完成趋势', style: Theme.of(context).textTheme.titleMedium),
                const Text('按任务所属日期统计，补签会更新对应日期。'),
                for (final day in days)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${day.day.substring(5)}${day.day == report.today ? ' 今天' : ''} · ${day.expected == 0 ? '无任务' : '${day.completed}/${day.expected} 项'}',
                        ),
                        if (day.rate != null)
                          LinearProgressIndicator(
                            value: day.rate,
                            semanticsLabel:
                                '${day.day}已完成${day.completed}项，共${day.expected}项任务',
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _childCard(OverviewChild child) => Card(
    key: ValueKey('overview-child:${child.id}'),
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(child.nickname, style: Theme.of(context).textTheme.titleLarge),
          Text(
            '今日 ${child.today.completed}/${child.today.expected} 项 · 近七日 ${child.weekCompleted}/${child.weekExpected} 项',
          ),
          Text('超额金币待确认：${child.pendingAwards} 笔，共 ${child.pendingCoins} 金币'),
          if (child.awaitingExpiry > 0)
            Text('${child.awaitingExpiry} 笔兑换已到期，等待系统取消退款；可打开兑换记录核对。'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: child.requested == 0
                    ? null
                    : () => _economy(child, 1),
                child: Text('待审批 ${child.requested}'),
              ),
              OutlinedButton(
                onPressed: child.approved == 0
                    ? null
                    : () => _economy(child, 1),
                child: Text('待履约 ${child.approved}'),
              ),
              OutlinedButton(
                onPressed: child.pendingAwards == 0
                    ? null
                    : () => _economy(child, 2),
                child: const Text('确认超额金币'),
              ),
              if (child.awaitingExpiry > 0)
                TextButton(
                  onPressed: () => _economy(child, 1),
                  child: const Text('核对到期兑换'),
                ),
              TextButton(
                onPressed: () => _open(
                  TaskManagementScreen(
                    childId: child.id,
                    childNickname: child.nickname,
                    familyId: widget.familyId,
                    isParentMode: true,
                  ),
                ),
                child: const Text('查看任务'),
              ),
              TextButton(
                onPressed: () => _open(
                  LearningReportScreen(
                    childId: child.id,
                    familyId: widget.familyId,
                    childNickname: child.nickname,
                    initialPeriod: 'week',
                  ),
                ),
                child: const Text('查看周报'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _economy(OverviewChild child, int tab) => _open(
    EconomyScreen(
      childId: child.id,
      familyId: widget.familyId,
      initialTab: tab,
    ),
  );
}

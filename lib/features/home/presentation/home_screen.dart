import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/domain/family.dart';
import '../../auth_family/presentation/child_profile_fields.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/domain/task.dart';
import '../../tasks/domain/task_item.dart';
import '../../tasks/presentation/task_presentation.dart';
import '../../tasks/presentation/task_sync_banner.dart';
import '../../wrong_questions/presentation/review_hub_screen.dart';
import '../../wrong_questions/presentation/review_session_screen.dart';
import '../../economy/presentation/economy_screen.dart';
import '../../economy/domain/xp_progress.dart';
import '../../reports/presentation/learning_report_screen.dart';
import '../../reports/presentation/family_overview_screen.dart';
import '../../growth/data/growth_repository.dart';
import '../../growth/presentation/growth_screen.dart';
import '../../growth/presentation/growth_portrait.dart';
import '../../growth/presentation/task_feedback.dart';
import '../../growth/presentation/feedback_settings_screen.dart';
import '../../growth/data/feedback_preferences.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({
    required this.childNickname,
    required this.children,
    required this.selectedChildId,
    required this.onChildSelected,
    required this.onManageFamily,
    required this.onManageTasks,
    required this.isParentMode,
    required this.onParentMode,
    required this.onSignOut,
    this.onGettingStarted,
    super.key,
  });
  final String childNickname;
  final List<ChildProfile> children;
  final String selectedChildId;
  final ValueChanged<String> onChildSelected;
  final VoidCallback onManageFamily;
  final VoidCallback onManageTasks;
  final bool isParentMode;
  final VoidCallback onParentMode;
  final Future<void> Function() onSignOut;
  final VoidCallback? onGettingStarted;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(tasksProvider(selectedChildId));
    ref.invalidate(walletProvider(selectedChildId));
    ref.invalidate(familyTodayProvider(selectedChildId));
    ref.invalidate(growthProvider(selectedChildId));
    await Future.wait([
      ref.read(tasksProvider(selectedChildId).future),
      ref.read(walletProvider(selectedChildId).future),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(feedbackPreferencesProvider);
    final tasks = ref.watch(tasksProvider(selectedChildId));
    final wallet = ref.watch(walletProvider(selectedChildId));
    final familyToday = ref.watch(familyTodayProvider(selectedChildId));
    final growth = ref.watch(growthProvider(selectedChildId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('冒险大厅'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '切换孩子',
            onSelected: onChildSelected,
            itemBuilder: (_) => [
              for (final child in children)
                PopupMenuItem(value: child.id, child: Text(child.nickname)),
            ],
            icon: const Icon(Icons.switch_account_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'manage') onManageFamily();
              if (value == 'tasks') onManageTasks();
              if (value == 'parent') onParentMode();
              if (value == 'logout') onSignOut();
              if (value == 'onboarding') onGettingStarted?.call();
              if (value == 'feedback') {
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => const FeedbackSettingsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'parent',
                child: Text(isParentMode ? '退出家长模式' : '进入家长模式'),
              ),
              const PopupMenuItem(value: 'manage', child: Text('家庭与孩子')),
              const PopupMenuItem(value: 'tasks', child: Text('任务管理')),
              const PopupMenuItem(value: 'feedback', child: Text('声音与动画')),
              if (onGettingStarted != null)
                const PopupMenuItem(value: 'onboarding', child: Text('首次使用指引')),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
          if (isParentMode) const Chip(label: Text('家长模式')),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => _refresh(ref),
          child: CustomScrollView(
            key: PageStorageKey('home:$selectedChildId'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList.list(
                  children: [
                    TaskSyncBanner(childId: selectedChildId),
                    Row(
                      children: [
                        if (growth.valueOrNull case final data?)
                          GrowthPortrait(data: data, size: 72)
                        else
                          ChildAvatar(
                            avatarKey: children
                                .firstWhere(
                                  (child) => child.id == selectedChildId,
                                )
                                .avatarKey,
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                childNickname,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              TaskAdventureView(
                                childId: selectedChildId,
                                compact: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (onGettingStarted != null &&
                        children
                                .firstWhere(
                                  (child) => child.id == selectedChildId,
                                )
                                .onboardingCompletedAt ==
                            null)
                      TextButton.icon(
                        onPressed: onGettingStarted,
                        icon: const Icon(Icons.flag_outlined),
                        label: const Text('首次使用 · 继续设置'),
                      ),
                    const SizedBox(height: 16),
                    wallet.when(
                      data: (value) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '金币 ${value.coins} · 冻结 ${value.frozen} · XP ${value.xp}',
                          ),
                        ),
                      ),
                      loading: () => const LinearProgressIndicator(),
                      error: (_, __) => const Text('钱包读取失败，请下拉重试'),
                    ),
                    const SizedBox(height: 20),
                    wallet.when(
                      data: (value) => Text(
                        'Lv.${XpProgress(value.xp).level} · XP用于成长，金币用于兑换',
                      ),
                      loading: () => const SizedBox.shrink(),
                      error: (_, _) => const SizedBox.shrink(),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(
                        growth.maybeWhen(
                          data: (data) =>
                              '我的角色与成长${data['offline'] == true ? '\n上次记录：' : ' · '}连续 ${data['streak']} 天',
                          orElse: () => '我的角色与成长',
                        ),
                      ),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => GrowthScreen(
                            childId: selectedChildId,
                            familyId: children
                                .firstWhere(
                                  (child) => child.id == selectedChildId,
                                )
                                .familyId,
                            nickname: childNickname,
                          ),
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.card_giftcard),
                      label: const Text('奖励商城与金币 XP'),
                      onPressed: () async {
                        final familyId = children
                            .firstWhere((child) => child.id == selectedChildId)
                            .familyId;
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => EconomyScreen(
                              childId: selectedChildId,
                              familyId: familyId,
                            ),
                          ),
                        );
                        if (context.mounted) {
                          ref.invalidate(walletProvider(selectedChildId));
                        }
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.school_outlined),
                      label: const Text('错题本与拼音复习'),
                      onPressed: () async {
                        final familyId = children
                            .firstWhere((child) => child.id == selectedChildId)
                            .familyId;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ReviewHubScreen(
                              childId: selectedChildId,
                              familyId: familyId,
                            ),
                          ),
                        );
                        if (context.mounted) {
                          ref.invalidate(tasksProvider(selectedChildId));
                          ref.invalidate(walletProvider(selectedChildId));
                        }
                      },
                    ),
                    if (isParentMode)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.family_restroom_outlined),
                        label: const Text('家庭概览与待处理事项'),
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => FamilyOverviewScreen(
                              familyId: children
                                  .firstWhere(
                                    (child) => child.id == selectedChildId,
                                  )
                                  .familyId,
                            ),
                          ),
                        ),
                      ),
                    if (isParentMode)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.insights_outlined),
                        label: const Text('学习报告'),
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => LearningReportScreen(
                              childId: selectedChildId,
                              familyId: children
                                  .firstWhere(
                                    (child) => child.id == selectedChildId,
                                  )
                                  .familyId,
                              childNickname: childNickname,
                            ),
                          ),
                        ),
                      ),
                    Text('今日任务', style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                sliver: tasks.when(
                  data: (items) {
                    if (familyToday.hasError) {
                      return SliverToBoxAdapter(
                        child: Text('家庭日期读取失败：${familyToday.error}'),
                      );
                    }
                    final value = familyToday.value;
                    if (value == null) {
                      return const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      );
                    }
                    final today = DateUtils.dateOnly(value);
                    final visible = items
                        .where(
                          (task) =>
                              !DateUtils.dateOnly(
                                task.dueDate,
                              ).isAfter(today) &&
                              (!task.isTerminal ||
                                  DateUtils.isSameDay(task.dueDate, today)),
                        )
                        .toList();
                    if (visible.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('暂无到期任务'),
                        ),
                      );
                    }
                    final ordered = TaskItem.ordered(visible);
                    final indices = {
                      for (var i = 0; i < ordered.length; i++)
                        'home-task:$selectedChildId:${ordered[i].id}': i,
                    };
                    return SliverList.builder(
                      itemCount: ordered.length,
                      findChildIndexCallback: (key) =>
                          key is ValueKey<String> ? indices[key.value] : null,
                      itemBuilder: (context, index) {
                        final task = ordered[index];
                        final review =
                            task.sourceType == 'automatic_wrong_review';
                        final record = review && task.isTerminal;
                        return Card(
                          key: ValueKey(
                            'home-task:$selectedChildId:${task.id}',
                          ),
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            title: TaskHeading(task: task),
                            subtitle: Text(
                              task.status == TaskStatus.abandoned
                                  ? '已放弃 · 保留有效时长，不扣已有奖励'
                                  : review
                                  ? '${record
                                        ? task.status == TaskStatus.completed
                                              ? '已完成 · '
                                              : '已跳过 · '
                                        : ''}自动错题/拼音复习 · 全部作答后按结果发奖${task.expectedMinutes == null ? '' : '\n目标 ${task.expectedMinutes} 分钟'}'
                                  : '+${task.coinReward} 金币 · +${task.xpReward} XP',
                            ),
                            trailing: FilledButton.tonal(
                              onPressed: task.isTerminal && !review
                                  ? null
                                  : !review
                                  ? onManageTasks
                                  : () async {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => ReviewSessionScreen(
                                            taskId: task.id,
                                            childId: selectedChildId,
                                            familyId: children
                                                .firstWhere(
                                                  (c) =>
                                                      c.id == selectedChildId,
                                                )
                                                .familyId,
                                          ),
                                        ),
                                      );
                                      if (context.mounted) {
                                        ref.invalidate(
                                          tasksProvider(selectedChildId),
                                        );
                                        ref.invalidate(
                                          walletProvider(selectedChildId),
                                        );
                                      }
                                    },
                              child: Text(
                                record
                                    ? '查看记录'
                                    : task.status == TaskStatus.abandoned
                                    ? '已放弃'
                                    : task.status == TaskStatus.skipped
                                    ? '已跳过'
                                    : task.status == TaskStatus.completed
                                    ? '已完成'
                                    : task.sourceType ==
                                          'automatic_wrong_review'
                                    ? '去复习'
                                    : '查看任务',
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                  loading: () => const SliverToBoxAdapter(
                    child: LinearProgressIndicator(),
                  ),
                  error: (_, __) =>
                      const SliverToBoxAdapter(child: Text('任务读取失败，请下拉重试')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/domain/family.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/domain/task.dart';

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

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(tasksProvider(selectedChildId));
    ref.invalidate(walletProvider(selectedChildId));
    ref.invalidate(familyTodayProvider(selectedChildId));
    await Future.wait([
      ref.read(tasksProvider(selectedChildId).future),
      ref.read(walletProvider(selectedChildId).future),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider(selectedChildId));
    final wallet = ref.watch(walletProvider(selectedChildId));
    final familyToday = ref.watch(familyTodayProvider(selectedChildId));
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
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'parent',
                child: Text(isParentMode ? '退出家长模式' : '进入家长模式'),
              ),
              const PopupMenuItem(value: 'manage', child: Text('家庭与孩子')),
              const PopupMenuItem(value: 'tasks', child: Text('任务管理')),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
          if (isParentMode) const Chip(label: Text('家长模式')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              childNickname,
              style: Theme.of(context).textTheme.headlineSmall,
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
            Text('今日任务', style: Theme.of(context).textTheme.titleLarge),
            tasks.when(
              data: (items) {
                if (familyToday.hasError) {
                  return Text('家庭日期读取失败：${familyToday.error}');
                }
                final value = familyToday.value;
                if (value == null) return const LinearProgressIndicator();
                final today = DateUtils.dateOnly(value);
                final visible = items
                    .where(
                      (task) =>
                          !DateUtils.dateOnly(task.dueDate).isAfter(today) &&
                          (task.status != TaskStatus.completed ||
                              DateUtils.isSameDay(task.dueDate, today)),
                    )
                    .toList();
                if (visible.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无到期任务'),
                  );
                }
                return Column(
                  children: [
                    for (final task in visible)
                      Card(
                        child: ListTile(
                          title: Text(task.title),
                          subtitle: Text(
                            '+${task.coinReward} 金币 · +${task.xpReward} XP',
                          ),
                          trailing: FilledButton.tonal(
                            onPressed: onManageTasks,
                            child: Text(
                              task.status == TaskStatus.completed
                                  ? '已完成'
                                  : '查看任务',
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
              loading: () => const LinearProgressIndicator(),
              error: (_, __) => const Text('任务读取失败，请下拉重试'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../auth_family/domain/family.dart';
import '../../tasks/domain/task.dart';

class HomeScreen extends StatefulWidget {
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

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  var coins = 860;
  late List<LearningTask> tasks = [
    const LearningTask(
      id: 'math',
      title: '口算 20 分钟',
      subtitle: '已完成',
      coinReward: 30,
      xpReward: 20,
      source: TaskSource.parentTemplate,
      status: TaskStatus.completed,
    ),
    const LearningTask(
      id: 'reading',
      title: '自主阅读 20 分钟',
      subtitle: '20:00 前完成',
      coinReward: 25,
      xpReward: 20,
      source: TaskSource.parentTemplate,
    ),
    const LearningTask(
      id: 'daily-review',
      title: '今日错题复习',
      subtitle: '系统自动生成 · 3 题',
      coinReward: 50,
      xpReward: 45,
      source: TaskSource.automaticWrongQuestionReview,
    ),
  ];

  void _complete(LearningTask task) {
    if (task.status == TaskStatus.completed) return;
    setState(() {
      tasks = tasks
          .map(
            (item) => item.id == task.id
                ? item.copyWith(status: TaskStatus.completed)
                : item,
          )
          .toList();
      coins += task.coinReward;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('完成任务 +${task.coinReward} 金币 +${task.xpReward} XP'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('冒险大厅'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '切换孩子',
            initialValue: widget.selectedChildId,
            onSelected: widget.onChildSelected,
            itemBuilder: (context) => [
              for (final child in widget.children)
                PopupMenuItem(value: child.id, child: Text(child.nickname)),
            ],
            icon: const Icon(Icons.switch_account_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'manage') widget.onManageFamily();
              if (value == 'tasks') widget.onManageTasks();
              if (value == 'parent') widget.onParentMode();
              if (value == 'logout') widget.onSignOut();
            },
            itemBuilder: (context) => [
              if (!widget.isParentMode)
                const PopupMenuItem(
                  value: 'parent',
                  child: Text('进入家长模式'),
                ),
              const PopupMenuItem(value: 'manage', child: Text('家庭与孩子')),
              const PopupMenuItem(value: 'tasks', child: Text('任务管理')),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
          if (widget.isParentMode)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Chip(label: Text('家长模式')),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: const Color(0xFF6657E8),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.childNickname} · Lv. 12',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(value: .68),
                  const SizedBox(height: 12),
                  Text(
                    '🪙 $coins    🔥 连续 8 天',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('今日任务', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          ...tasks.map(
            (task) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(
                      task.source == TaskSource.automaticWrongQuestionReview
                          ? '🧠'
                          : '✓',
                    ),
                  ),
                  title: Text(task.title),
                  subtitle: Text('${task.subtitle} · +${task.coinReward} 金币'),
                  trailing: FilledButton.tonal(
                    onPressed: task.status == TaskStatus.completed
                        ? null
                        : () => _complete(task),
                    child: Text(
                      task.status == TaskStatus.completed
                          ? '已完成'
                          : task.source ==
                                  TaskSource.automaticWrongQuestionReview
                              ? '复习'
                              : '开始',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        destinations: [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            label: '错题',
          ),
          NavigationDestination(icon: Icon(Icons.task_alt), label: '任务'),
          NavigationDestination(icon: Icon(Icons.redeem_outlined), label: '奖励'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }
}

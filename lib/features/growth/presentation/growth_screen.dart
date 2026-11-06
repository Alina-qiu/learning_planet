import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../../economy/domain/xp_progress.dart';
import '../data/growth_repository.dart';
import 'learning_event_screen.dart';
import 'growth_portrait.dart';
import 'task_feedback.dart';
import 'feedback_settings_screen.dart';
export 'growth_portrait.dart' show avatarLabels;

const growthKindLabels = {'badge': '徽章', 'outfit': '装扮', 'pet': '伙伴'};

class GrowthScreen extends ConsumerStatefulWidget {
  const GrowthScreen({
    required this.childId,
    required this.familyId,
    required this.nickname,
    super.key,
  });
  final String childId, familyId, nickname;
  @override
  ConsumerState<GrowthScreen> createState() => _GrowthScreenState();
}

class _GrowthScreenState extends ConsumerState<GrowthScreen> {
  bool _busy = false;
  String? _error;
  Future<void> _equip(String slot, String? selection) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(growthRepositoryProvider)
          .equip(widget.childId, slot, selection);
    } catch (_) {
      if (mounted) setState(() => _error = '更换尚未确认，请检查网络后重试或刷新。不会消耗金币或 XP。');
    } finally {
      if (mounted) {
        ref.invalidate(growthProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的角色与成长'),
        actions: [
          IconButton(
            tooltip: '声音与动画',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const FeedbackSettingsScreen()),
            ),
          ),
        ],
      ),
      body: ref
          .watch(growthProvider(widget.childId))
          .when(
            data: (data) => _content(data, parent),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('成长记录暂时无法读取，请联网后重试。'),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(growthProvider(widget.childId)),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _content(Map<String, dynamic> data, bool parent) {
    final xp = XpProgress((data['xp'] as num).toInt());
    final appearance = data['appearance'] as Map<String, dynamic>;
    final assets = (data['assets'] as List).cast<Map<String, dynamic>>();
    final milestones = (data['milestones'] as List).cast<num>();
    String titleFor(String? key) =>
        assets
            .where((a) => a['key'] == key)
            .map((a) => a['title'] as String)
            .firstOrNull ??
        '未选择';
    final avatar = appearance['avatar'] as String;
    final offline = data['offline'] == true;
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(growthProvider(widget.childId));
        await ref.read(growthProvider(widget.childId).future);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (offline)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '离线成长记录 · ${DateTime.parse(data['fetched_at'] as String).toLocal().toString().substring(0, 16)}\n'
                '显示上次同步的角色和已解锁物品，联网后刷新。更换装扮需联网确认。',
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  GrowthPortrait(data: data, size: 160),
                  const SizedBox(height: 12),
                  Text(
                    widget.nickname,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text('Lv.${xp.level} · ${data['xp']} XP'),
                  LinearProgressIndicator(
                    value: xp.fraction,
                    semanticsLabel: '当前等级经验进度',
                  ),
                  Text(
                    xp.level == 50
                        ? '已达到最高等级，成长记录会继续保留'
                        : '本级 ${xp.earnedInLevel} / ${xp.nextRequired} XP',
                  ),
                  if (appearance['badge'] != null)
                    Text('徽章：${titleFor(appearance['badge'])}'),
                  if (appearance['outfit'] != null)
                    Text('装扮：${titleFor(appearance['outfit'])}'),
                  if (appearance['pet'] != null)
                    Text('伙伴：${titleFor(appearance['pet'])}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TaskAdventureView(childId: widget.childId),
          Text(
            '${offline ? '上次记录' : ''}连续完成 ${data['streak']} 天',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            offline
                ? '记录日期：${data['today']}。离线完成的任务在同步确认后更新成长记录。'
                : data['checkin_today'] == true
                ? '今天已经留下成长记录'
                : '今天完成一项任务，就能留下成长记录',
          ),
          const Text(
            '按已完成任务的应完成日期计算，家长补签可补齐记录。漏一天也不会扣除金币、XP或已解锁物品。离线任务同步确认后更新。',
          ),
          for (final milestone in const [
            (3, '30 金币'),
            (7, '坚持徽章 + 50 XP'),
            (30, '坚持装扮 + 150 XP'),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                milestones.contains(milestone.$1)
                    ? Icons.check_circle
                    : Icons.flag_outlined,
              ),
              title: Text('连续 ${milestone.$1} 天 · ${milestone.$2}'),
              subtitle: Text(
                milestones.contains(milestone.$1) ? '已达成，首次奖励已结算' : '首次达成时自动结算',
              ),
            ),
          const Text('金币奖励受每日软上限约束，超额部分等待家长确认。'),
          const SizedBox(height: 16),
          Text('选择角色', style: Theme.of(context).textTheme.titleLarge),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in avatarLabels.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: avatar == entry.key,
                  onSelected: _busy || offline
                      ? null
                      : (_) => _equip('avatar', entry.key),
                ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final kind in growthKindLabels.entries) ...[
            const SizedBox(height: 16),
            Text(kind.value, style: Theme.of(context).textTheme.titleLarge),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('不佩戴'),
                  selected: appearance[kind.key] == null,
                  onSelected: _busy || offline
                      ? null
                      : (_) => _equip(kind.key, null),
                ),
                for (final asset in assets.where((a) => a['kind'] == kind.key))
                  ChoiceChip(
                    label: Text(
                      '${asset['title']}${asset['unlocked'] == true
                          ? ''
                          : asset['minimum_level'] != null
                          ? ' · Lv.${asset['minimum_level']}解锁'
                          : asset['key'] == 'streak7'
                          ? ' · 连续7天解锁'
                          : ' · 连续30天解锁'}',
                    ),
                    avatar: Icon(
                      asset['unlocked'] == true
                          ? Icons.auto_awesome
                          : Icons.lock_outline,
                      size: 18,
                    ),
                    selected: appearance[kind.key] == asset['key'],
                    onSelected: _busy || offline || asset['unlocked'] != true
                        ? null
                        : (_) => _equip(kind.key, asset['key'] as String),
                  ),
              ],
            ),
          ],
          if (parent && !offline)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.verified_outlined),
                label: const Text('家长成长奖励'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => LearningEventScreen(
                      childId: widget.childId,
                      familyId: widget.familyId,
                      today: data['today'] as String,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

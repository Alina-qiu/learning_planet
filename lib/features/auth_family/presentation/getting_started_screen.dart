import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/family_providers.dart';
import '../data/onboarding_repository.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/schedule_repository.dart';
import '../../tasks/domain/schedule_config.dart';
import '../../tasks/domain/task_reward_presets.dart';
import '../../tasks/presentation/schedule_management_screen.dart';
import '../../growth/data/growth_repository.dart';
import '../../growth/presentation/growth_screen.dart';
import '../../economy/data/economy_repository.dart';
import 'parent_mode_prompt.dart';
import '../../reports/presentation/configuration_time_scope.dart';

const starterRewards = {
  'cartoon': ('动画片30分钟', 120),
  'game': ('周末游戏30分钟', 220),
  'book': ('选择一本书', 500),
  'movie': ('家庭电影', 1200),
  'restaurant': ('喜欢的餐厅', 1800),
  'toy': ('普通玩具', 3000),
  'park': ('主题乐园或短途旅行', 8000),
};

class GettingStartedScreen extends ConsumerStatefulWidget {
  const GettingStartedScreen({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;
  @override
  ConsumerState<GettingStartedScreen> createState() =>
      _GettingStartedScreenState();
}

class _GettingStartedScreenState extends ConsumerState<GettingStartedScreen> {
  Widget _timed(ConfigurationKind kind, Widget child) => ConfigurationTimeScope(
    childId: widget.childId,
    familyId: widget.familyId,
    kind: kind,
    child: child,
  );
  bool _busy = false, _understood = false;
  String? _error, _avatar, _pet;
  Future<void> _run(Future<void> Function(OnboardingRepository) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(ref.read(onboardingRepositoryProvider));
      if (!mounted) return;
      ref.invalidate(onboardingProvider(widget.childId));
      ref.invalidate(familiesProvider);
      ref.invalidate(growthProvider(widget.childId));
      ref.invalidate(tasksProvider(widget.childId));
      ref.invalidate(schedulesProvider(widget.childId));
      ref.invalidate(
        economyDataProvider((
          childId: widget.childId,
          familyId: widget.familyId,
        )),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '操作尚未确认：$error。可刷新查看进度或重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _parent() async {
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      await enterParentMode(context, ref, widget.familyId);
    }
    return mounted && ref.read(activeParentFamilyProvider) == widget.familyId;
  }

  Future<void> _rules(Map<String, dynamic> data) => _run((repository) async {
    if (!await _parent() || !mounted) return;
    final config = await Navigator.of(context).push<StarterRulesConfig>(
      MaterialPageRoute(
        builder: (_) =>
            _timed(ConfigurationKind.rules, StarterRulesEditor(data: data)),
      ),
    );
    if (config == null || !mounted) return;
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长授权已到期，请重新验证');
    }
    await repository.configure(
      widget.childId,
      config.preset,
      config.limit,
      config.rewards,
    );
  });
  Future<void> _firstTask(Map<String, dynamic> data) =>
      _run((repository) async {
        if (!await _parent() || !mounted) return;
        final child = data['child'] as Map;
        final preset =
            taskRewardPresets[child['starter_task_preset']] ??
            taskRewardPresets['study20']!;
        final config = await Navigator.of(context).push<ScheduleConfig>(
          MaterialPageRoute(
            builder: (_) => _timed(
              ConfigurationKind.task,
              ScheduleEditor(
                today: DateTime.parse(data['today'] as String),
                defaults: preset.defaults,
              ),
            ),
          ),
        );
        if (config == null || !mounted) return;
        if (ref.read(activeParentFamilyProvider) != widget.familyId) {
          throw StateError('家长授权已到期，请重新验证');
        }
        await repository.firstTask(widget.childId, config);
      });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('首次使用指引'),
      actions: [
        IconButton(
          tooltip: '刷新引导进度',
          onPressed: _busy
              ? null
              : () => ref.invalidate(onboardingProvider(widget.childId)),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ref
        .watch(onboardingProvider(widget.childId))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('引导进度暂时无法读取：$error'),
                FilledButton(
                  onPressed: () =>
                      ref.invalidate(onboardingProvider(widget.childId)),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          data: (data) {
            final child = data['child'] as Map<String, dynamic>;
            final appearance = data['appearance'] as Map<String, dynamic>;
            final pets = (data['pets'] as List).cast<Map<String, dynamic>>();
            final step = child['guide_step'] as int;
            final rules = child['starter_rules_at'] != null;
            final task = data['has_task'] == true;
            final complete = child['onboarding_completed_at'] != null;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${child['nickname']}，欢迎来到学习星球',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text('设置会保存，可以先返回大厅，下次从这里继续。引导不会增加或消耗金币、XP。'),
                if (_busy) const Text('正在处理…'),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(rules ? '家长规则已确认' : '家长准备：积分与奖励'),
                        Text(
                          '每日金币软上限 ${data['daily_limit']} · 已上架 ${data['active_rewards']} 项奖励',
                        ),
                        const Text(
                          '默认积分模板会填入新任务，创建时仍可调整。超出软上限的金币待家长确认，XP照常获得。',
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _rules(data),
                          child: Text(rules ? '查看或调整初始规则' : '家长设置积分与奖励'),
                        ),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          step == 3 ? '三步引导已完成' : '孩子引导 · 第 ${step + 1} / 3 步',
                        ),
                        if (step == 0) ...[
                          const Text('选择你的角色。以后可以在“我的角色”里更换。'),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final entry in avatarLabels.entries)
                                ChoiceChip(
                                  label: Text(entry.value),
                                  selected:
                                      (_avatar ?? appearance['avatar']) ==
                                      entry.key,
                                  onSelected: _busy
                                      ? null
                                      : (_) =>
                                            setState(() => _avatar = entry.key),
                                ),
                            ],
                          ),
                        ],
                        if (step == 1) ...[
                          const Text('选择一位学习伙伴，一起开始。伙伴只是成长装扮，不影响学习奖励。'),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final pet in pets)
                                ChoiceChip(
                                  label: Text(pet['title'] as String),
                                  selected:
                                      (_pet ?? appearance['pet']) == pet['key'],
                                  onSelected: _busy
                                      ? null
                                      : (_) => setState(
                                          () => _pet = pet['key'] as String,
                                        ),
                                ),
                            ],
                          ),
                        ],
                        if (step == 2) ...[
                          const Text(
                            '1. 先开始任务，休息时可以暂停。错题复习要逐题作答。\n2. 完成后由服务器确认金币和XP；断网时先保存在本机。\n3. 金币可以申请家庭奖励，需要家长批准和兑现。XP用于成长，晚开始或放弃不会扣已有奖励。',
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _understood,
                            onChanged: _busy
                                ? null
                                : (value) =>
                                      setState(() => _understood = value!),
                            title: const Text('我知道怎样开始和兑换奖励了'),
                          ),
                        ],
                        if (step < 3)
                          FilledButton(
                            onPressed:
                                _busy ||
                                    (step == 2 && !_understood) ||
                                    (step == 1 &&
                                        (_pet ?? appearance['pet']) == null)
                                ? null
                                : () => _run((repository) async {
                                    await repository.advance(
                                      widget.childId,
                                      step,
                                      step == 0
                                          ? (_avatar ??
                                                appearance['avatar'] as String)
                                          : step == 1
                                          ? (_pet ??
                                                appearance['pet'] as String)
                                          : null,
                                    );
                                    _avatar = null;
                                    _pet = null;
                                  }),
                            child: Text(
                              step == 0
                                  ? '确认角色，下一步'
                                  : step == 1
                                  ? '确认伙伴，下一步'
                                  : '完成三步引导',
                            ),
                          ),
                        if (step == 3)
                          TextButton(
                            onPressed: () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => GrowthScreen(
                                  childId: widget.childId,
                                  familyId: widget.familyId,
                                  nickname: child['nickname'] as String,
                                ),
                              ),
                            ),
                            child: const Text('查看我的角色与伙伴'),
                          ),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(task ? '首个任务已创建' : '家长准备：创建第一个任务'),
                        const Text('从家庭今天开始，保存后生成真实任务；创建和引导都不会直接发奖。'),
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : task
                              ? () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => ScheduleManagementScreen(
                                      childId: widget.childId,
                                      familyId: widget.familyId,
                                    ),
                                  ),
                                )
                              : () => _firstTask(data),
                          child: Text(task ? '查看任务配置' : '创建第一个任务'),
                        ),
                      ],
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: _busy || !rules || step != 3 || !task
                      ? null
                      : () => _run((repository) async {
                          await repository.finish(widget.childId);
                          if (!mounted || !context.mounted) return;
                          ref.invalidate(familiesProvider);
                          Navigator.pop(context);
                        }),
                  child: Text(complete ? '返回冒险大厅' : '设置完成，开始冒险'),
                ),
              ],
            );
          },
        ),
  );
}

class StarterRulesConfig {
  const StarterRulesConfig(this.preset, this.limit, this.rewards);
  final String preset;
  final int limit;
  final List<String> rewards;
}

class StarterRulesEditor extends StatefulWidget {
  const StarterRulesEditor({required this.data, super.key});
  final Map<String, dynamic> data;
  @override
  State<StarterRulesEditor> createState() => _StarterRulesEditorState();
}

class _StarterRulesEditorState extends State<StarterRulesEditor> {
  final _form = GlobalKey<FormState>();
  late String _preset =
      (widget.data['child'] as Map)['starter_task_preset'] as String;
  late final _limit = TextEditingController(
    text: '${widget.data['daily_limit']}',
  );
  late final Set<String> _rewards = widget.data['active_rewards'] == 0
      ? {'cartoon', 'book'}
      : {};
  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('初始积分与家庭奖励')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        onChanged: () => ConfigurationTimeScope.activity(context),
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _preset,
              decoration: const InputDecoration(labelText: '默认任务积分模板'),
              items: [
                for (final entry in taskRewardPresets.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value.label),
                  ),
              ],
              onChanged: (value) => setState(() => _preset = value!),
            ),
            TextFormField(
              controller: _limit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '每日金币软上限（0–10000）',
                helperText: '默认150；超过部分需家长确认，XP不受影响。',
                helperMaxLines: 2,
              ),
              validator: (raw) {
                final value = int.tryParse(raw ?? '');
                return value == null || value < 0 || value > 10000
                    ? '请输入0至10000的整数'
                    : null;
              },
            ),
            const SizedBox(height: 20),
            const Text('选择要加入商城的家庭奖励'),
            const Text('已存在的初始奖励不会重复创建或覆盖你修改过的价格、库存。之后可在商城修改规则。'),
            for (final entry in starterRewards.entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _rewards.contains(entry.key),
                onChanged: (value) => setState(
                  () => value!
                      ? _rewards.add(entry.key)
                      : _rewards.remove(entry.key),
                ),
                title: Text('${entry.value.$1} · ${entry.value.$2}金币'),
              ),
            FilledButton(
              onPressed: () {
                if (!_form.currentState!.validate()) return;
                if (_rewards.isEmpty && widget.data['active_rewards'] == 0) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('请至少选择一项奖励')));
                  return;
                }
                Navigator.pop(
                  context,
                  StarterRulesConfig(
                    _preset,
                    int.parse(_limit.text),
                    _rewards.toList(),
                  ),
                );
              },
              child: const Text('确认保存初始规则'),
            ),
          ],
        ),
      ),
    ),
  );
}

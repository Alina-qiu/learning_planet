import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../application/task_providers.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_config.dart';
import '../domain/task_priority.dart';
import '../domain/task_growth_category.dart';
import '../domain/task_reward_presets.dart';
import 'reminder_settings_dialog.dart';
import 'plan_reward_fields.dart';
import '../data/notification_scheduler.dart';
import '../../reports/presentation/configuration_time_scope.dart';

Map<String, dynamic>? planFor(Map<String, dynamic> row) {
  final value = row['long_plans'];
  if (value is Map<String, dynamic>) return value;
  if (value is List && value.isNotEmpty) {
    return value.first as Map<String, dynamic>;
  }
  return null;
}

class ScheduleManagementScreen extends ConsumerStatefulWidget {
  const ScheduleManagementScreen({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;
  @override
  ConsumerState<ScheduleManagementScreen> createState() =>
      _ScheduleManagementScreenState();
}

class _ScheduleManagementScreenState
    extends ConsumerState<ScheduleManagementScreen> {
  Widget _timed(ConfigurationKind kind, WidgetBuilder builder) =>
      ConfigurationTimeScope(
        childId: widget.childId,
        familyId: widget.familyId,
        kind: kind,
        child: Builder(builder: builder),
      );
  bool _busy = false, _settingsOpen = false;
  int? _operationParentRevision;
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId &&
      (_operationParentRevision == null ||
          ref.read(parentAuthorizationRevisionProvider) ==
              _operationParentRevision);
  Future<void> _run(
    Future<void> Function() operation, {
    bool parent = true,
    bool reminderChange = false,
  }) async {
    if (_busy) return;
    if (parent && !_authorized) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请重新验证家长 PIN')));
      return;
    }
    setState(() => _busy = true);
    _operationParentRevision = parent
        ? ref.read(parentAuthorizationRevisionProvider)
        : null;
    try {
      await operation();
      if (!mounted) return;
      ref.invalidate(schedulesProvider(widget.childId));
      ref.invalidate(remindersProvider(widget.childId));
      ref.invalidate(tasksProvider(widget.childId));
      ref.invalidate(walletProvider(widget.childId));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              reminderChange && isNetworkFailure(error)
                  ? '标记结果尚未确认，请联网后刷新提醒核对。'
                  : '操作失败：$error',
            ),
          ),
        );
      }
    } finally {
      _operationParentRevision = null;
      if (mounted) {
        if (parent) ref.invalidate(schedulesProvider(widget.childId));
        if (reminderChange) ref.invalidate(remindersProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    await _run(() async {
      final repository = ref.read(scheduleRepositoryProvider);
      final today = await repository.today(widget.childId);
      if (!mounted) return;
      if (!_authorized) throw StateError('家长授权已到期');
      final config = await Navigator.of(context).push<ScheduleConfig>(
        MaterialPageRoute(
          builder: (_) => _timed(
            ConfigurationKind.task,
            (context) => ScheduleEditor(
              today: today,
              initial: row,
              defaults:
                  taskRewardPresets[ref
                              .read(familiesProvider)
                              .valueOrNull
                              ?.expand((family) => family.children)
                              .where((child) => child.id == widget.childId)
                              .firstOrNull
                              ?.starterTaskPreset ??
                          'study20']!
                      .defaults,
            ),
          ),
        ),
      );
      if (config == null || !mounted) return;
      if (!_authorized) throw StateError('家长授权已到期');
      await repository.save(
        widget.childId,
        config,
        templateId: row?['id'] as String?,
      );
    });
  }

  Future<void> _leave(Map<String, dynamic> plan) async {
    await _run(() async {
      final today = await ref
          .read(scheduleRepositoryProvider)
          .today(widget.childId);
      if (!mounted) return;
      final date = await showDatePicker(
        context: context,
        initialDate: today,
        firstDate: today,
        lastDate: today.add(const Duration(days: 366)),
        builder: (_, child) => _timed(ConfigurationKind.task, (_) => child!),
      );
      if (date == null || !mounted) return;
      var reason = '';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _timed(
          ConfigurationKind.task,
          (context) => AlertDialog(
            title: const Text('批准请假'),
            content: TextField(
              onChanged: (v) {
                reason = v;
                ConfigurationTimeScope.activity(context);
              },
              decoration: const InputDecoration(labelText: '请假原因（必填）'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('批准'),
              ),
            ],
          ),
        ),
      );
      if (confirmed == true && reason.trim().isNotEmpty && mounted) {
        if (!_authorized) throw StateError('家长授权已到期');
        await ref
            .read(scheduleRepositoryProvider)
            .approveLeave(
              widget.childId,
              plan['id'] as String,
              date,
              reason.trim(),
            );
      }
    });
  }

  Future<void> _settings() async {
    if (_busy || _settingsOpen || !_authorized) return;
    _settingsOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => ReminderSettingsDialog(
          childId: widget.childId,
          familyId: widget.familyId,
        ),
      );
    } finally {
      _settingsOpen = false;
      if (mounted) ref.invalidate(remindersProvider(widget.childId));
    }
  }

  @override
  Widget build(BuildContext _) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final schedules = ref.watch(schedulesProvider(widget.childId));
    final snapshot = schedules.valueOrNull;
    final editable =
        authorized &&
        !schedules.isLoading &&
        !schedules.hasError &&
        snapshot != null &&
        !snapshot.offline &&
        snapshot.familyId == widget.familyId;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('计划与提醒'),
          actions: [
            IconButton(
              tooltip: '刷新计划',
              onPressed: _busy
                  ? null
                  : () => ref.invalidate(schedulesProvider(widget.childId)),
              icon: const Icon(Icons.refresh),
            ),
            if (authorized)
              IconButton(
                tooltip: '提醒设置',
                onPressed: _busy ? null : _settings,
                icon: const Icon(Icons.notifications_outlined),
              ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '模板与计划'),
              Tab(text: '提醒'),
            ],
          ),
        ),
        floatingActionButton: editable
            ? FloatingActionButton.extended(
                onPressed: _busy ? null : _edit,
                icon: const Icon(Icons.add),
                label: const Text('配置任务'),
              )
            : null,
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (ref.watch(notificationErrorProvider) case final error?)
              Padding(padding: const EdgeInsets.all(8), child: Text(error)),
            if (!authorized && snapshot?.offline != true)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('当前为只读模式，编辑需返回首页验证家长 PIN'),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  schedules.when(
                    skipLoadingOnRefresh: false,
                    data: (snapshot) {
                      if (snapshot.familyId != widget.familyId) {
                        return const Center(child: Text('计划所属家庭已变化，请重新打开。'));
                      }
                      final rows = snapshot.items;
                      return Column(
                        children: [
                          if (snapshot.offline)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                '离线查看 · ${snapshot.fetchedAt.toLocal().toString().substring(0, 16)}（本机时区）\n进度可能已变化。修改、请假或结算请联网刷新。',
                              ),
                            ),
                          Expanded(
                            child: rows.isEmpty
                                ? const Center(child: Text('还没有周期模板或长期计划'))
                                : RefreshIndicator(
                                    onRefresh: () async {
                                      ref.invalidate(
                                        schedulesProvider(widget.childId),
                                      );
                                      await ref.read(
                                        schedulesProvider(
                                          widget.childId,
                                        ).future,
                                      );
                                    },
                                    child: ListView.builder(
                                      padding: const EdgeInsets.all(16),
                                      itemCount: rows.length + 1,
                                      itemBuilder: (context, index) {
                                        if (index == rows.length) {
                                          return const SizedBox(height: 80);
                                        }
                                        final row = rows[index];
                                        return Card(
                                          key: ValueKey(
                                            'schedule:${row['id']}',
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  row['title'] as String,
                                                  style: Theme.of(
                                                    context,
                                                  ).textTheme.titleMedium,
                                                ),
                                                Text(
                                                  '${const {'daily': '每天', 'once': '一次性', 'weekly': '每周', 'custom': '指定日期'}[row['recurrence']] ?? '周期任务'} · ${row['starts_on']} 至 ${row['ends_on']}',
                                                ),
                                                Text(
                                                  '${row['start_time']}–${row['due_time']} · +${row['coin_reward']} 金币 / +${row['xp_reward']} XP',
                                                ),
                                                Text(
                                                  '${TaskPriority.parse(row['task_priority'] as String?).label}'
                                                  '${row['expected_minutes'] == null ? '' : ' · 目标 ${row['expected_minutes']} 分钟'}',
                                                ),
                                                Text(
                                                  '成长分类：${TaskGrowthCategory.parse(row['growth_category'] as String?).label}',
                                                ),
                                                if (planFor(row)
                                                    case final plan?) ...[
                                                  Text(
                                                    '长期计划 · 达标 ${((plan['minimum_rate'] as num) * 100).round()}% · 终奖 ${plan['bonus_coins']} 金币 / ${plan['bonus_xp']} XP',
                                                  ),
                                                  Text(
                                                    '已批准请假：${(plan['plan_leaves'] as List? ?? []).length} 天',
                                                  ),
                                                  if (plan['progress']
                                                      case final Map progress)
                                                    Text(
                                                      '已完成 ${progress['completed']} / 应完成 ${progress['expected']}，完成率 ${((progress['rate'] as num) * 100).toStringAsFixed(1)}%',
                                                    ),
                                                  for (final stage
                                                      in plan['plan_stage_rewards']
                                                              as List? ??
                                                          [])
                                                    Text(
                                                      '阶段 ${stage['completed_count']} 次：${stage['coins']} 金币 / ${stage['xp']} XP · ${stage['awarded_at'] == null ? '待达成' : '已发放'}',
                                                    ),
                                                  for (final tier
                                                      in plan['plan_bonus_tiers']
                                                              as List? ??
                                                          [])
                                                    Text(
                                                      '终奖 ${((tier['minimum_rate'] as num) * 100).round()}%：${tier['coins']} 金币 / ${tier['xp']} XP（仅最高档）',
                                                    ),
                                                  if (plan['settled_at'] !=
                                                      null)
                                                    Text(
                                                      '已结算：${((plan['achieved_rate'] as num) * 100).toStringAsFixed(1)}%',
                                                    ),
                                                  if (editable &&
                                                      plan['settled_at'] ==
                                                          null)
                                                    Wrap(
                                                      children: [
                                                        TextButton(
                                                          onPressed: _busy
                                                              ? null
                                                              : () => _leave(
                                                                  plan,
                                                                ),
                                                          child: const Text(
                                                            '批准请假',
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed: _busy
                                                              ? null
                                                              : () => _run(() async {
                                                                  final rate = await ref
                                                                      .read(
                                                                        scheduleRepositoryProvider,
                                                                      )
                                                                      .settle(
                                                                        widget
                                                                            .childId,
                                                                        plan['id']
                                                                            as String,
                                                                      );
                                                                  if (context
                                                                      .mounted) {
                                                                    ScaffoldMessenger.of(
                                                                      context,
                                                                    ).showSnackBar(
                                                                      SnackBar(
                                                                        content:
                                                                            Text(
                                                                              '已结算，完成率 ${(rate * 100).toStringAsFixed(1)}%',
                                                                            ),
                                                                      ),
                                                                    );
                                                                  }
                                                                }),
                                                          child: const Text(
                                                            '到期结算',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                ] else if (editable)
                                                  Wrap(
                                                    children: [
                                                      TextButton(
                                                        onPressed: _busy
                                                            ? null
                                                            : () => _edit(row),
                                                        child: const Text(
                                                          '编辑后续模板',
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: _busy
                                                            ? null
                                                            : () => _run(
                                                                () => ref
                                                                    .read(
                                                                      scheduleRepositoryProvider,
                                                                    )
                                                                    .setActive(
                                                                      widget
                                                                          .childId,
                                                                      row['id']
                                                                          as String,
                                                                      !(row['active']
                                                                          as bool),
                                                                    ),
                                                              ),
                                                        child: Text(
                                                          row['active'] == true
                                                              ? '停用'
                                                              : '启用',
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, __) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '计划读取失败，请检查网络和访问权限后重试。首次查看或修改结果未确认时，需要先联网读取。',
                            ),
                            FilledButton(
                              onPressed: () => ref.invalidate(
                                schedulesProvider(widget.childId),
                              ),
                              child: const Text('重新读取计划'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ref
                      .watch(remindersProvider(widget.childId))
                      .when(
                        data: (rows) => RefreshIndicator(
                          onRefresh: () async {
                            ref.invalidate(remindersProvider(widget.childId));
                            await ref.read(
                              remindersProvider(widget.childId).future,
                            );
                          },
                          child: ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              const Text(
                                '开始前 10 分钟、开始时、截止前 15 分钟。Android/iOS 在提醒设置中授权系统通知。保留最近 60 条，打开应用时刷新。',
                              ),
                              if (rows.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('暂无待处理提醒'),
                                ),
                              for (final row in rows)
                                Card(
                                  child: ListTile(
                                    leading: const Icon(
                                      Icons.notifications_active_outlined,
                                    ),
                                    title: Text(row['titles'] as String),
                                    subtitle: Text(
                                      row['remind_local'] as String,
                                    ),
                                    trailing: IconButton(
                                      tooltip: '标记已读',
                                      onPressed: _busy
                                          ? null
                                          : () => _run(
                                              () => ref
                                                  .read(
                                                    scheduleRepositoryProvider,
                                                  )
                                                  .acknowledge(
                                                    widget.childId,
                                                    row['reminder_key']
                                                        as String,
                                                  ),
                                              parent: false,
                                              reminderChange: true,
                                            ),
                                      icon: const Icon(Icons.done),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => Center(child: Text('提醒读取失败：$e')),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScheduleEditor extends StatefulWidget {
  const ScheduleEditor({
    required this.today,
    this.initial,
    this.defaults,
    super.key,
  });
  final DateTime today;
  final Map<String, dynamic>? initial;
  final Map<String, dynamic>? defaults;
  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  final _form = GlobalKey<FormState>();
  late DateTime _start, _end;
  late ScheduleRecurrence _recurrence;
  late TaskPriority _priority;
  late TaskGrowthCategory _growthCategory;
  late final Map<String, TextEditingController> _fields;
  late Set<int> _weekdays;
  bool _plan = false;
  final _stages = <PlanRewardDraft>[];
  final _tiers = <PlanRewardDraft>[];
  bool get _activePlan =>
      widget.initial == null && _plan && _recurrence != ScheduleRecurrence.once;
  @override
  void initState() {
    super.initState();
    final row = widget.initial ?? widget.defaults;
    _priority = TaskPriority.parse(row?['task_priority'] as String?);
    _growthCategory = TaskGrowthCategory.parse(
      row?['growth_category'] as String?,
    );
    final rule = row?['recurrence_rule'] as Map<String, dynamic>? ?? {};
    _start = row?['starts_on'] == null
        ? widget.today
        : DateTime.parse(row!['starts_on'] as String);
    _end = row?['ends_on'] == null
        ? _start.add(const Duration(days: 30))
        : DateTime.parse(row!['ends_on'] as String);
    _recurrence = ScheduleRecurrence.values.byName(
      row?['recurrence'] as String? ?? 'daily',
    );
    _weekdays = ((rule['weekdays'] as List?) ?? [1, 2, 3, 4, 5])
        .cast<int>()
        .toSet();
    _fields = {
      'title': TextEditingController(text: row?['title'] as String? ?? ''),
      'start': TextEditingController(
        text: (row?['start_time'] as String? ?? '16:00').substring(0, 5),
      ),
      'due': TextEditingController(
        text: (row?['due_time'] as String? ?? '20:00').substring(0, 5),
      ),
      'coins': TextEditingController(text: '${row?['coin_reward'] ?? 20}'),
      'xp': TextEditingController(text: '${row?['xp_reward'] ?? 20}'),
      'min': TextEditingController(
        text: '${((row?['minimum_seconds'] as int? ?? 0) / 60).ceil()}',
      ),
      'expected': TextEditingController(
        text: '${row?['expected_minutes'] ?? 20}',
      ),
      'dates': TextEditingController(
        text: ((rule['dates'] as List?) ?? []).join(','),
      ),
      'rate': TextEditingController(text: '80'),
      'bonusCoins': TextEditingController(text: '100'),
      'bonusXp': TextEditingController(text: '100'),
    };
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final draft in [..._stages, ..._tiers]) {
      draft.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, {bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: _fields[key],
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      validator: (v) => (v == null || (v.trim().isEmpty && key != 'dates'))
          ? '请填写此项'
          : number && (int.tryParse(v) == null || int.parse(v) < 0)
          ? '请输入非负整数'
          : null,
    ),
  );
  Future<void> _pick(bool start) async {
    ConfigurationTimeScope.activity(context);
    final date = await showDatePicker(
      context: context,
      initialDate: start ? _start : _end,
      firstDate: widget.initial == null ? widget.today : _start,
      lastDate: widget.today.add(const Duration(days: 366)),
      builder: (_, child) => Listener(
        onPointerDown: (_) => ConfigurationTimeScope.activity(context),
        child: child,
      ),
    );
    if (!mounted) return;
    ConfigurationTimeScope.activity(context);
    if (date != null) {
      setState(() {
        if (start) {
          _start = date;
          if (_end.isBefore(date)) _end = date;
        } else {
          _end = date;
        }
      });
    }
  }

  Widget _rewardFields(List<PlanRewardDraft> drafts, {required bool tiers}) =>
      PlanRewardFields(
        drafts: drafts,
        tiers: tiers,
        basePercent: () => int.tryParse(_fields['rate']!.text.trim()),
        onAdd: () {
          ConfigurationTimeScope.activity(context);
          setState(() => drafts.add(PlanRewardDraft()));
        },
        onRemove: (draft) {
          ConfigurationTimeScope.activity(context);
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => drafts.remove(draft));
          WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
        },
      );

  void _save() {
    if (!_form.currentState!.validate()) return;
    try {
      final config = ScheduleConfig(
        title: _fields['title']!.text,
        startsOn: _start,
        endsOn: _recurrence == ScheduleRecurrence.once ? _start : _end,
        recurrence: _recurrence,
        startTime: _fields['start']!.text,
        dueTime: _fields['due']!.text,
        weekdays: _weekdays.toList(),
        customDates: _recurrence != ScheduleRecurrence.custom
            ? const []
            : _fields['dates']!.text
                  .split(',')
                  .where((v) => v.trim().isNotEmpty)
                  .map((v) => parseScheduleDate(v.trim()))
                  .toList(),
        coins: int.parse(_fields['coins']!.text),
        xp: int.parse(_fields['xp']!.text),
        minimumMinutes: int.parse(_fields['min']!.text),
        expectedMinutes: int.parse(_fields['expected']!.text),
        priority: _priority,
        growthCategory: _growthCategory,
        longPlan: _activePlan,
        minimumRate: _activePlan ? int.parse(_fields['rate']!.text) / 100 : .8,
        bonusCoins: _activePlan ? int.parse(_fields['bonusCoins']!.text) : 100,
        bonusXp: _activePlan ? int.parse(_fields['bonusXp']!.text) : 100,
        stages: [
          if (_activePlan)
            for (var i = 0; i < _stages.length; i++) _stages[i].stage(i + 1),
        ],
        tiers: [
          if (_activePlan)
            for (var i = 0; i < _tiers.length; i++) _tiers[i].tier(i + 1),
        ],
      );
      config.toJson();
      Navigator.pop(context, config);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is FormatException ? e.message : '请检查配置后重试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.initial == null ? '新建任务配置' : '编辑后续模板')),
    body: SafeArea(
      child: Form(
        onChanged: () => ConfigurationTimeScope.activity(context),
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _field('title', '任务名称'),
            DropdownButtonFormField<ScheduleRecurrence>(
              isExpanded: true,
              initialValue: _recurrence,
              decoration: const InputDecoration(labelText: '重复方式'),
              items: [
                for (final rec in ScheduleRecurrence.values)
                  DropdownMenuItem(
                    value: rec,
                    child: Text(switch (rec) {
                      ScheduleRecurrence.once => '一次性',
                      ScheduleRecurrence.daily => '每天',
                      ScheduleRecurrence.weekly => '每周',
                      ScheduleRecurrence.custom => '自定义日期',
                    }),
                  ),
              ],
              onChanged: (v) => setState(() => _recurrence = v!),
            ),
            Wrap(
              children: [
                TextButton(
                  onPressed: () => _pick(true),
                  child: Text('开始：${scheduleDate(_start)}'),
                ),
                if (_recurrence != ScheduleRecurrence.once)
                  TextButton(
                    onPressed: () => _pick(false),
                    child: Text('结束：${scheduleDate(_end)}'),
                  ),
              ],
            ),
            if (_recurrence == ScheduleRecurrence.weekly)
              const Text('未选择的星期为休息日。'),
            if (_recurrence == ScheduleRecurrence.weekly)
              Wrap(
                spacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(
                        '周${['一', '二', '三', '四', '五', '六', '日'][d - 1]}',
                      ),
                      selected: _weekdays.contains(d),
                      onSelected: (v) => setState(() {
                        if (v) {
                          _weekdays.add(d);
                        } else {
                          _weekdays.remove(d);
                        }
                      }),
                    ),
                ],
              ),
            if (_recurrence == ScheduleRecurrence.custom)
              _field('dates', '日期（YYYY-MM-DD，逗号分隔）'),
            DropdownButtonFormField<TaskPriority>(
              isExpanded: true,
              initialValue: _priority,
              decoration: const InputDecoration(labelText: '任务类别'),
              items: [
                for (final priority in TaskPriority.values)
                  DropdownMenuItem(
                    value: priority,
                    child: Text(priority.label),
                  ),
              ],
              onChanged: (value) => setState(() => _priority = value!),
            ),
            const Text('类别只影响排序和显示，不改变奖励，也不作为扣分依据。'),
            DropdownButtonFormField<TaskGrowthCategory>(
              isExpanded: true,
              initialValue: _growthCategory,
              decoration: const InputDecoration(labelText: '成长统计分类'),
              items: [
                for (final category in TaskGrowthCategory.values)
                  DropdownMenuItem(
                    value: category,
                    child: Text(category.label),
                  ),
              ],
              onChanged: (value) => setState(() => _growthCategory = value!),
            ),
            const Text(
              '可按内容选择学习、探索或责任，无法确定时保留未分类。完成天数和计时会单独计入坚持、专注；这些指标不改变奖励。修改只影响以后生成的任务。',
            ),
            const Text('以下时间按家庭时区，不按设备时区。'),
            _field('start', '开始时间 HH:mm'),
            _field('due', '截止时间 HH:mm'),
            _field('coins', '单次金币', number: true),
            _field('xp', '单次 XP', number: true),
            _field('min', '最低有效时长（分钟，0 表示无需计时）', number: true),
            _field('expected', '目标时长（分钟）', number: true),
            if (widget.initial == null &&
                _recurrence != ScheduleRecurrence.once)
              SwitchListTile(
                title: const Text('设为长期计划'),
                value: _plan,
                onChanged: (v) => setState(() => _plan = v),
              ),
            if (_activePlan) ...[
              const Text('请假日不计入分母。到期达标后只发放一次终奖，规则创建后锁定。'),
              _field('rate', '最低完成率 %', number: true),
              _field('bonusCoins', '终奖金币', number: true),
              _field('bonusXp', '终奖 XP', number: true),
              _rewardFields(_stages, tiers: false),
              _rewardFields(_tiers, tiers: true),
            ],
            FilledButton(onPressed: _save, child: const Text('保存配置')),
          ],
        ),
      ),
    ),
  );
}

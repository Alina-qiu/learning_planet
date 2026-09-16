import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../application/task_providers.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_config.dart';
import '../data/notification_scheduler.dart';

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
  bool _busy = false;
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId;
  Future<void> _run(
    Future<void> Function() operation, {
    bool parent = true,
  }) async {
    if (_busy) return;
    if (parent && !_authorized) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请重新验证家长 PIN')));
      return;
    }
    setState(() => _busy = true);
    try {
      await operation();
      if (!mounted) return;
      ref.invalidate(schedulesProvider(widget.childId));
      ref.invalidate(remindersProvider(widget.childId));
      ref.invalidate(tasksProvider(widget.childId));
      ref.invalidate(walletProvider(widget.childId));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    await _run(() async {
      final repository = ref.read(scheduleRepositoryProvider);
      final today = await repository.today(widget.childId);
      if (!mounted) return;
      final config = await Navigator.of(context).push<ScheduleConfig>(
        MaterialPageRoute(
          builder: (_) => ScheduleEditor(today: today, initial: row),
        ),
      );
      if (config == null) return;
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
      );
      if (date == null || !mounted) return;
      var reason = '';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('批准请假'),
          content: TextField(
            onChanged: (v) => reason = v,
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
      );
      if (confirmed == true && reason.trim().isNotEmpty) {
        await ref
            .read(scheduleRepositoryProvider)
            .approveLeave(plan['id'] as String, date, reason.trim());
      }
    });
  }

  Future<void> _settings() async {
    await _run(() async {
      final repository = ref.read(scheduleRepositoryProvider);
      final current = await repository.reminderSettings(widget.childId);
      if (!mounted) return;
      var enabled = current['enabled'] as bool;
      var start = (current['quiet_start'] as String).substring(0, 5);
      var end = (current['quiet_end'] as String).substring(0, 5);
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('提醒与静默时段'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('启用提醒'),
                  value: enabled,
                  onChanged: (v) => update(() => enabled = v),
                ),
                TextFormField(
                  initialValue: start,
                  onChanged: (v) => start = v,
                  decoration: const InputDecoration(labelText: '静默开始 HH:mm'),
                ),
                TextFormField(
                  initialValue: end,
                  onChanged: (v) => end = v,
                  decoration: const InputDecoration(labelText: '静默结束 HH:mm'),
                ),
                const Text('按家庭时区；相同时间的提醒合并。相同起止时间表示不静默。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (result == true) {
        await repository.saveReminderSettings(
          widget.childId,
          enabled,
          start,
          end,
        );
        if (enabled) {
          final granted = await ref
              .read(notificationSchedulerProvider)
              .requestPermission();
          if (mounted && !granted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('系统通知未授权或此平台不支持；应用内提醒仍可使用')),
            );
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext _) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('周期模板、长期计划与提醒'),
          actions: [
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
        floatingActionButton: authorized
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
            if (!authorized)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('当前为只读模式，编辑需返回首页验证家长 PIN'),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  ref
                      .watch(schedulesProvider(widget.childId))
                      .when(
                        data: (rows) => rows.isEmpty
                            ? const Center(child: Text('还没有周期模板或长期计划'))
                            : RefreshIndicator(
                                onRefresh: () async {
                                  ref.invalidate(
                                    schedulesProvider(widget.childId),
                                  );
                                  await ref.read(
                                    schedulesProvider(widget.childId).future,
                                  );
                                },
                                child: ListView(
                                  padding: const EdgeInsets.all(16),
                                  children: [
                                    for (final row in rows)
                                      Card(
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
                                                '${row['recurrence']} · ${row['starts_on']} 至 ${row['ends_on']}',
                                              ),
                                              Text(
                                                '${row['start_time']}–${row['due_time']} · +${row['coin_reward']} 金币 / +${row['xp_reward']} XP',
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
                                                if (plan['settled_at'] != null)
                                                  Text(
                                                    '已结算：${((plan['achieved_rate'] as num) * 100).toStringAsFixed(1)}%',
                                                  ),
                                                if (authorized &&
                                                    plan['settled_at'] == null)
                                                  Wrap(
                                                    children: [
                                                      TextButton(
                                                        onPressed: _busy
                                                            ? null
                                                            : () =>
                                                                  _leave(plan),
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
                                                                      plan['id']
                                                                          as String,
                                                                    );
                                                                if (mounted) {
                                                                  ScaffoldMessenger.of(
                                                                    context,
                                                                  ).showSnackBar(
                                                                    SnackBar(
                                                                      content: Text(
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
                                              ] else if (authorized)
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
                                      ),
                                    const SizedBox(height: 80),
                                  ],
                                ),
                              ),
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => Center(child: Text('模板读取失败：$e')),
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
  const ScheduleEditor({required this.today, this.initial, super.key});
  final DateTime today;
  final Map<String, dynamic>? initial;
  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  final _form = GlobalKey<FormState>();
  late DateTime _start, _end;
  late ScheduleRecurrence _recurrence;
  late final Map<String, TextEditingController> _fields;
  late Set<int> _weekdays;
  bool _plan = false;
  @override
  void initState() {
    super.initState();
    final row = widget.initial;
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
      'dates': TextEditingController(
        text: ((rule['dates'] as List?) ?? []).join(','),
      ),
      'rate': TextEditingController(text: '80'),
      'bonusCoins': TextEditingController(text: '100'),
      'bonusXp': TextEditingController(text: '100'),
      'stages': TextEditingController(),
      'tiers': TextEditingController(),
    };
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, {bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: _fields[key],
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      validator: (v) =>
          (v == null ||
              (v.trim().isEmpty && !['dates', 'stages', 'tiers'].contains(key)))
          ? '请填写此项'
          : number && (int.tryParse(v) == null || int.parse(v) < 0)
          ? '请输入非负整数'
          : null,
    ),
  );
  Future<void> _pick(bool start) async {
    final date = await showDatePicker(
      context: context,
      initialDate: start ? _start : _end,
      firstDate: widget.initial == null ? widget.today : _start,
      lastDate: widget.today.add(const Duration(days: 366)),
    );
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
        customDates: _fields['dates']!.text
            .split(',')
            .where((v) => v.trim().isNotEmpty)
            .map((v) => parseScheduleDate(v.trim()))
            .toList(),
        coins: int.parse(_fields['coins']!.text),
        xp: int.parse(_fields['xp']!.text),
        minimumMinutes: int.parse(_fields['min']!.text),
        longPlan: _plan && _recurrence != ScheduleRecurrence.once,
        minimumRate: int.parse(_fields['rate']!.text) / 100,
        bonusCoins: int.parse(_fields['bonusCoins']!.text),
        bonusXp: int.parse(_fields['bonusXp']!.text),
        stages: !_plan
            ? const []
            : _fields['stages']!.text
                  .split(',')
                  .where((v) => v.trim().isNotEmpty)
                  .map((v) {
                    final parts = v.trim().split(':').map(int.parse).toList();
                    if (parts.length != 3) {
                      throw const FormatException('阶段格式：次数:金币:XP');
                    }
                    return {
                      'completed_count': parts[0],
                      'coins': parts[1],
                      'xp': parts[2],
                    };
                  })
                  .toList(),
        tiers: !_plan
            ? const []
            : _fields['tiers']!.text
                  .split(',')
                  .where((v) => v.trim().isNotEmpty)
                  .map((v) {
                    final parts = v.trim().split(':').map(int.parse).toList();
                    if (parts.length != 3) {
                      throw const FormatException('档位格式：完成率%:金币:XP');
                    }
                    return <String, num>{
                      'minimum_rate': parts[0] / 100,
                      'coins': parts[1],
                      'xp': parts[2],
                    };
                  })
                  .toList(),
      );
      config.toJson();
      Navigator.pop(context, config);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.initial == null ? '新建任务配置' : '编辑后续模板')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _field('title', '任务名称'),
          DropdownButtonFormField<ScheduleRecurrence>(
            initialValue: _recurrence,
            decoration: const InputDecoration(labelText: '重复方式'),
            items: [
              for (final rec in ScheduleRecurrence.values)
                DropdownMenuItem(
                  value: rec,
                  child: Text(switch (rec) {
                    ScheduleRecurrence.once => '一次性',
                    ScheduleRecurrence.daily => '每天',
                    ScheduleRecurrence.weekly => '每周（未选择的星期为休息日）',
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
          const Text('以下时间按家庭时区，不按设备时区。'),
          _field('start', '开始时间 HH:mm'),
          _field('due', '截止时间 HH:mm'),
          _field('coins', '单次金币', number: true),
          _field('xp', '单次 XP', number: true),
          _field('min', '最低有效时长（分钟，0 表示无需计时）', number: true),
          if (widget.initial == null && _recurrence != ScheduleRecurrence.once)
            SwitchListTile(
              title: const Text('设为长期计划'),
              value: _plan,
              onChanged: (v) => setState(() => _plan = v),
            ),
          if (_plan) ...[
            const Text('请假日不计入分母。到期达标后只发放一次终奖，规则创建后锁定。'),
            _field('rate', '最低完成率 %', number: true),
            _field('bonusCoins', '终奖金币', number: true),
            _field('bonusXp', '终奖 XP', number: true),
            _field('stages', '阶段奖励（可选）：次数:金币:XP，逗号分隔'),
            _field('tiers', '更高终奖档位（可选）：完成率%:金币:XP'),
          ],
          FilledButton(onPressed: _save, child: const Text('保存配置')),
        ],
      ),
    ),
  );
}

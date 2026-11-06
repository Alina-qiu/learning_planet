import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../economy/data/economy_repository.dart';
import '../data/growth_repository.dart';

class LearningEventScreen extends ConsumerStatefulWidget {
  const LearningEventScreen({
    required this.childId,
    required this.familyId,
    required this.today,
    super.key,
  });
  final String childId, familyId, today;
  @override
  ConsumerState<LearningEventScreen> createState() =>
      _LearningEventScreenState();
}

class _LearningEventScreenState extends ConsumerState<LearningEventScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(), _reason = TextEditingController();
  final _date = TextEditingController(),
      _minutes = TextEditingController(text: '0');
  final _coins = TextEditingController(text: '30'),
      _xp = TextEditingController(text: '20');
  final _scoreCoins = TextEditingController(text: '50'),
      _scoreXp = TextEditingController(text: '30');
  final _improvementCoins = TextEditingController(text: '100'),
      _improvementXp = TextEditingController(text: '50');
  String _kind = 'challenge';
  bool _busy = false;
  String? _message, _commandId;
  Map<String, dynamic>? _pending;

  @override
  void initState() {
    super.initState();
    _date.text = widget.today;
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _reason,
      _date,
      _minutes,
      _coins,
      _xp,
      _scoreCoins,
      _scoreXp,
      _improvementCoins,
      _improvementXp,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _authorize() {
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长授权已到期，请返回首页验证 PIN');
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_pending == null && !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      _authorize();
      if (_pending == null) {
        final config = <String, dynamic>{
          'kind': _kind,
          'reference': _title.text.trim(),
        };
        String summary;
        if (_kind == 'challenge') {
          config['minimum_seconds'] = int.parse(_minutes.text) * 60;
          summary =
              '创建一项今天的挑战，最低有效时长 ${_minutes.text} 分钟。完成后获得30金币、25XP；当天最多一项。';
        } else {
          config.addAll({'date': _date.text, 'reason': _reason.text.trim()});
          if (_kind == 'praise') {
            config.addAll({
              'coins': int.parse(_coins.text),
              'xp': int.parse(_xp.text),
            });
            summary = '记录表扬并结算 ${_coins.text} 金币、${_xp.text} XP。';
          } else {
            final score = (
              int.parse(_scoreCoins.text),
              int.parse(_scoreXp.text),
            );
            final improvement = (
              int.parse(_improvementCoins.text),
              int.parse(_improvementXp.text),
            );
            if (!_examRange(score) ||
                !_examRange(improvement) ||
                (score.$1 == 0 && improvement.$1 == 0)) {
              throw StateError('每个考试档位填50至200金币、30至100XP；不用的档位均填0，至少启用一档');
            }
            config.addAll({
              'score_coins': score.$1,
              'score_xp': score.$2,
              'improvement_coins': improvement.$1,
              'improvement_xp': improvement.$2,
            });
            final selected =
                score.$1 > improvement.$1 ||
                    (score.$1 == improvement.$1 && score.$2 > improvement.$2)
                ? score
                : improvement;
            summary = '两档只选一档：结算 ${selected.$1} 金币、${selected.$2} XP，不叠加。';
          }
        }
        final approved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认成长奖励'),
            content: Text(
              '${config['reference']}\n$summary\n金币超出当日软上限的部分等待确认，XP正常结算。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认提交'),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
        _authorize();
        _pending = config;
        _commandId = const Uuid().v4();
      }
      final repository = ref.read(growthRepositoryProvider);
      final config = _pending!;
      if (config['kind'] == 'challenge') {
        await repository.challenge(
          widget.childId,
          _commandId!,
          config['reference'] as String,
          config['minimum_seconds'] as int,
        );
      } else {
        await repository.award(widget.childId, _commandId!, config);
      }
      if (!mounted) return;
      final challenge = config['kind'] == 'challenge';
      _pending = null;
      _commandId = null;
      setState(
        () => _message = challenge
            ? '挑战已创建，请返回任务中心开始。'
            : '奖励已确认，请在金币账本查看到账或待确认金额。',
      );
      ref.invalidate(learningEventsProvider(widget.childId));
      ref.invalidate(economyDataProvider);
      final tasks = ref.read(taskRepositoryProvider);
      if (tasks is OfflineTaskRepository) {
        try {
          await tasks.synchronize(widget.childId);
        } catch (_) {
          if (mounted) {
            setState(
              () => _message = '${_message ?? '提交已确认。'} 本机数据刷新暂未完成，请联网后刷新。',
            );
          }
        }
      }
      if (!mounted) return;
      ref.invalidate(tasksProvider(widget.childId));
      ref.invalidate(walletProvider(widget.childId));
      ref.invalidate(growthProvider(widget.childId));
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(() {
          if ([
            'P0001',
            '42501',
            '23505',
            '22007',
            '22008',
          ].contains(error.code)) {
            _pending = null;
            _commandId = null;
          }
          _message = error.code == '23505'
              ? '同一孩子、日期、名称的事件已经记录，请查看下方记录。'
              : '提交失败：${error.message}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = _pending == null
              ? '$error'
              : '结果尚未确认，请重试同一请求，或返回后查看任务和奖励记录。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _examRange((int, int) pair) =>
      pair == (0, 0) ||
      (pair.$1 >= 50 && pair.$1 <= 200 && pair.$2 >= 30 && pair.$2 <= 100);
  Widget _number(
    String label,
    TextEditingController controller,
    int min,
    int max,
  ) => TextFormField(
    controller: controller,
    enabled: !_busy && _pending == null,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
    validator: (value) {
      final number = int.tryParse(value ?? '');
      return number == null || number < min || number > max
          ? '请输入$min至$max的整数'
          : null;
    },
  );
  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(title: const Text('家长成长奖励')),
      body: !parent
          ? const Center(child: Text('家长授权已到期，请返回首页验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _kind,
                        decoration: const InputDecoration(labelText: '奖励类型'),
                        items: const [
                          DropdownMenuItem(
                            value: 'challenge',
                            child: Text('今日主动挑战'),
                          ),
                          DropdownMenuItem(
                            value: 'praise',
                            child: Text('老师表扬'),
                          ),
                          DropdownMenuItem(value: 'exam', child: Text('考试进步')),
                        ],
                        onChanged: _busy || _pending != null
                            ? null
                            : (value) => setState(() {
                                _kind = value!;
                                _message = null;
                              }),
                      ),
                      TextFormField(
                        controller: _title,
                        enabled: !_busy && _pending == null,
                        maxLength: 120,
                        decoration: InputDecoration(
                          labelText: _kind == 'challenge'
                              ? '挑战名称'
                              : '事件名称（同一次考试请使用同一名称）',
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请填写名称' : null,
                      ),
                      if (_kind == 'challenge') ...[
                        _number('最低有效时长（分钟）', _minutes, 0, 120),
                        const Text('每个孩子按家庭当天最多一项。创建时不发奖，完成后结算30金币、25XP。'),
                      ] else ...[
                        TextFormField(
                          controller: _date,
                          enabled: !_busy && _pending == null,
                          decoration: const InputDecoration(
                            labelText: '事件日期 YYYY-MM-DD',
                          ),
                          validator: (v) {
                            final parsed = DateTime.tryParse('${v}T00:00:00Z');
                            return v == null ||
                                    !RegExp(
                                      r'^\d{4}-\d{2}-\d{2}$',
                                    ).hasMatch(v) ||
                                    parsed == null ||
                                    parsed.toIso8601String().substring(0, 10) !=
                                        v ||
                                    v.compareTo('2000-01-01') < 0
                                ? '请填写有效日期'
                                : null;
                          },
                        ),
                        TextFormField(
                          controller: _reason,
                          enabled: !_busy && _pending == null,
                          maxLength: 500,
                          decoration: const InputDecoration(
                            labelText: '家长确认说明',
                          ),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? '请填写确认说明' : null,
                        ),
                        if (_kind == 'praise') ...[
                          _number('表扬金币', _coins, 30, 100),
                          _number('表扬 XP', _xp, 20, 50),
                        ] else ...[
                          const Text('只选择金币较高的一档；金币相同时选XP较高的一档。不使用的档位均填0。'),
                          _number('绝对分档金币', _scoreCoins, 0, 200),
                          _number('绝对分档 XP', _scoreXp, 0, 100),
                          _number('进步档金币', _improvementCoins, 0, 200),
                          _number('进步档 XP', _improvementXp, 0, 100),
                        ],
                      ],
                      const SizedBox(height: 16),
                      if (_message != null)
                        Text(_message!, key: const Key('event-message')),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: Text(
                          _busy
                              ? '正在提交…'
                              : _pending == null
                              ? '核对并提交'
                              : '重试同一请求',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    const Expanded(child: Text('最近50条表扬与考试记录')),
                    IconButton(
                      tooltip: '刷新奖励记录',
                      onPressed: () => ref.invalidate(
                        learningEventsProvider(widget.childId),
                      ),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                ref
                    .watch(learningEventsProvider(widget.childId))
                    .when(
                      data: (events) => Column(
                        children: [
                          if (events.isEmpty) const Text('还没有表扬或考试奖励记录'),
                          for (final event in events)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(event['reference'] as String),
                              subtitle: Text(
                                '${event['event_date']} · ${event['kind'] == 'praise' ? '老师表扬' : '考试奖励'}\n奖励 ${event['coin_reward']} 金币 / ${event['xp_reward']} XP（含可能待确认的金币）\n${(event['payload'] as Map)['reason']}',
                              ),
                            ),
                        ],
                      ),
                      loading: () => const LinearProgressIndicator(),
                      error: (_, _) => const Text('奖励记录暂时无法读取，请点击刷新。'),
                    ),
              ],
            ),
    );
  }
}

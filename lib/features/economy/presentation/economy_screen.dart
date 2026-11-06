import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../data/economy_repository.dart';
import '../data/economy_commands.dart';
import 'economy_pending_command.dart';
import '../domain/xp_progress.dart';
import '../domain/reward_limits.dart';
import 'reward_editor.dart';
import '../../reports/presentation/configuration_time_scope.dart';
import 'economy_text.dart';
import 'wallet_adjustment_screen.dart';

const redemptionLabels = {
  'requested': '待审批',
  'approved': '待履约',
  'rejected': '已拒绝',
  'fulfilled': '已兑现',
  'cancelled': '已取消',
  'expired': '已过期退款',
};

class EconomyScreen extends ConsumerStatefulWidget {
  const EconomyScreen({
    required this.childId,
    required this.familyId,
    this.initialTab = 0,
    super.key,
  });
  final String childId, familyId;
  final int initialTab;
  @override
  ConsumerState<EconomyScreen> createState() => _EconomyScreenState();
}

class _EconomyScreenState extends ConsumerState<EconomyScreen> {
  bool _busy = false;
  bool _accessDenied = false;
  int _pageEpoch = 0;
  Map<String, dynamic>? _baseData;
  bool get _offline => _baseData?['offline'] == true;
  EconomyTime get _time =>
      EconomyTime(_baseData?['family_timezone'] as String?);
  final _rows = <String, List<Map<String, dynamic>>>{};
  final _cursors = <String, Map<String, dynamic>?>{};
  final _pageDays = <String, String>{};
  final _loadingPages = <String>{}, _pageErrors = <String>{};
  final _requests = <String, String>{};
  final _requestSnapshots = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? _adjustment;
  ({String childId, String familyId}) get _scope =>
      (childId: widget.childId, familyId: widget.familyId);
  void _refresh() {
    setState(() {
      _pageEpoch++;
      _baseData = null;
      _loadingPages.clear();
      _pageErrors.clear();
      _accessDenied = false;
    });
    ref.invalidate(pendingEconomyCommandProvider(_scope));
    ref.invalidate(economyDataProvider(_scope));
    ref.invalidate(walletProvider(widget.childId));
  }

  void _bindPages(Map<String, dynamic> data) {
    if (identical(_baseData, data)) return;
    _baseData = data;
    _pageEpoch++;
    _loadingPages.clear();
    _pageErrors.clear();
    for (final section in ['rewards', 'redemptions', 'pending', 'ledger']) {
      _rows[section] = (data[section] as List)
          .cast<Map<String, dynamic>>()
          .toList();
      _cursors[section] = ((data['cursors'] as Map?)?[section] as Map?)
          ?.cast<String, dynamic>();
      _pageDays[section] =
          (data['page_days'] as Map?)?[section] as String? ?? '';
    }
  }

  Future<void> _more(String section) async {
    final repository = ref.read(economyRepositoryProvider),
        cursor = _cursors[section];
    if (_busy ||
        _offline ||
        _loadingPages.contains(section) ||
        cursor == null ||
        repository is! PagedEconomyRepository) {
      return;
    }
    final epoch = _pageEpoch;
    setState(() {
      _loadingPages.add(section);
      _pageErrors.remove(section);
    });
    bool current() =>
        mounted &&
        epoch == _pageEpoch &&
        identical(repository, ref.read(economyRepositoryProvider));
    try {
      final page = await repository.page(
        widget.childId,
        widget.familyId,
        section,
        after: cursor,
      );
      if (!current()) return;
      if (section == 'rewards' && page.familyToday != _pageDays[section]) {
        throw const FormatException('兑换日期已变化，请刷新');
      }
      final ids = _rows[section]!.map((r) => r['id']).toSet();
      if (page.items.any((r) => !ids.add(r['id']))) {
        throw const FormatException('记录重复，请刷新');
      }
      setState(() {
        _rows[section]!.addAll(page.items);
        _cursors[section] = page.nextCursor;
      });
    } catch (error) {
      if (!current()) return;
      if (error is StateError ||
          error is PostgrestException && error.code == '42501') {
        setState(() {
          _accessDenied = true;
          _rows.clear();
          _cursors.clear();
        });
        ref.invalidate(economyDataProvider(_scope));
      } else {
        setState(() => _pageErrors.add(section));
      }
    } finally {
      if (current()) setState(() => _loadingPages.remove(section));
    }
  }

  Widget _moreButton(String section) {
    if (_cursors[section] == null) return const SizedBox.shrink();
    final label = const {
      'rewards': '奖励',
      'redemptions': '兑换记录',
      'pending': '待确认金币',
      'ledger': '账本',
    }[section]!;
    if (_offline) return Text('联网刷新后可继续查看$label。');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text('已加载 ${_rows[section]!.length} 条$label，按最新时间排列'),
          if (_pageErrors.contains(section))
            const Text('继续读取未成功，已显示的记录仍保留。可重试或刷新页面。'),
          OutlinedButton(
            key: ValueKey('more:$section'),
            onPressed: _busy || _loadingPages.contains(section)
                ? null
                : () => _more(section),
            child: Text(
              '${_pageErrors.contains(section) ? '重试加载' : '继续查看'}$label',
            ),
          ),
          if (_loadingPages.contains(section)) const LinearProgressIndicator(),
        ],
      ),
    );
  }

  Widget _lazyList(String section, List<Widget Function()> rows) {
    final content = <Widget Function()>[
      if (!_offline)
        () => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_time.label),
        ),
      if (_offline)
        () => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '离线仅供查看 · 上次读取 ${_time.format(_baseData!['fetched_at'])}\n${_time.label}\n'
            '每类最多保留最近50条。余额、库存和申请状态可能已变化，请联网刷新后操作。',
          ),
        ),
      ...rows,
    ];
    return ListView.builder(
      key: PageStorageKey('economy:${widget.childId}:$section'),
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: content.length,
      itemBuilder: (context, index) => content[index](),
    );
  }

  void _parent() {
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长授权已到期，请返回首页重新验证 PIN');
    }
  }

  Future<void> _run(Future<void> Function(EconomyRepository) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _pageEpoch++;
      _loadingPages.clear();
    });
    try {
      await action(ref.read(economyRepositoryProvider));
      if (!mounted) return;
      final tasks = ref.read(taskRepositoryProvider);
      if (tasks is OfflineTaskRepository) {
        await tasks.synchronize(widget.childId);
      }
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作未完成，请查看待确认请求或刷新核对后重试。')),
        );
      }
    } finally {
      if (mounted) ref.invalidate(pendingEconomyCommandProvider(_scope));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _reason(String title) async {
    String value = '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          maxLength: 500,
          onChanged: (v) => value = v,
          decoration: const InputDecoration(labelText: '必填原因 / 履约说明'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  Future<void> _edit([Map<String, dynamic>? row]) => _run((repository) async {
    _parent();
    final config = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ConfigurationTimeScope(
          childId: widget.childId,
          familyId: widget.familyId,
          kind: ConfigurationKind.rules,
          child: RewardEditor(initial: row),
        ),
      ),
    );
    if (config == null || !mounted) return;
    _parent();
    await repository.saveReward(
      widget.familyId,
      config,
      rewardId: row?['id'] as String?,
    );
  });
  Future<void> _request(Map<String, dynamic> row) => _run((repository) async {
    final durable = ref.read(economyCommandsProvider);
    final scope = durable?.capture(widget.familyId);
    final id = row['id'] as String;
    final original = _requestSnapshots[id] ?? row;
    final retry = _requests.containsKey(id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('${retry ? '重试申请' : '申请'} ${original['title']}'),
        content: Text(
          '${retry ? '上次结果尚未确认，将查询或重试同一申请。若已受理，不会再次冻结金币或预留库存。\n' : ''}'
          '冻结 ${original['cost']} 金币。\n${original['rules']}\n${rewardCapacityDescription(original)}\n申请即预留1份库存和1次额度。审批期限 ${original['request_days']}天；批准后${original['fulfillment_days']}天内履约。拒绝、取消或过期退回金币与预留额度，XP不会被消耗。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认申请'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (durable != null) {
      await durable.check(widget.childId, widget.familyId, scope!);
      final request = await durable.prepare(widget.childId, widget.familyId, {
        'kind': 'redeem',
        'reward_id': id,
        'version': original['version'],
      }, original);
      ref.invalidate(pendingEconomyCommandProvider(_scope));
      await durable.resolve(
        widget.childId,
        widget.familyId,
        request.requestId,
        'submit',
      );
      return;
    }
    final key = _requests.putIfAbsent(id, () => const Uuid().v4());
    _requestSnapshots.putIfAbsent(id, () => Map.of(row));
    try {
      await repository.request(
        widget.childId,
        id,
        key,
        (original['version'] as num).toInt(),
      );
    } on PostgrestException catch (error) {
      // A definite SQL rejection rolls back the request. Keep uncertain network
      // outcomes bound to their original UUID, price and version for retry.
      if (!isNetworkFailure(error)) {
        _requests.remove(id);
        _requestSnapshots.remove(id);
        _refresh();
      }
      rethrow;
    }
    _requests.remove(id);
    _requestSnapshots.remove(id);
  });
  Future<void> _transition(String id, String operation) => _run((
    repository,
  ) async {
    String reason = '孩子取消申请';
    if (operation != 'cancel') {
      _parent();
      final value = await _reason(
        '确认 ${const {'approve': '批准申请', 'reject': '拒绝申请', 'fulfill': '已履约'}[operation]}',
      );
      if (value == null || !mounted) return;
      reason = value;
      _parent();
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('取消申请并退回冻结金币？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认取消'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await repository.transition(id, operation, reason);
  });
  Future<void> _decide(String id, bool approve) => _run((repository) async {
    _parent();
    final reason = await _reason(approve ? '确认发放超额金币' : '拒绝超额金币');
    if (reason == null || !mounted) return;
    _parent();
    await repository.decide(id, approve, reason);
  });
  Future<void> _limit(int current) => _run((repository) async {
    _parent();
    String value = '$current';
    final limit = await showDialog<int>(
      context: context,
      builder: (_) => ConfigurationTimeScope(
        childId: widget.childId,
        familyId: widget.familyId,
        kind: ConfigurationKind.rules,
        child: Builder(
          builder: (context) => AlertDialog(
            title: const Text('每日金币软上限'),
            content: TextFormField(
              initialValue: value,
              keyboardType: TextInputType.number,
              onChanged: (v) {
                value = v;
                ConfigurationTimeScope.activity(context);
              },
              decoration: const InputDecoration(
                labelText: '0–10000，超额需确认，XP照常获得',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final n = int.tryParse(value);
                  if (n != null && n >= 0 && n <= 10000) {
                    Navigator.pop(context, n);
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
    if (limit == null || !mounted) return;
    _parent();
    await repository.limit(widget.childId, limit);
  });
  Future<void> _adjust() => _run((repository) async {
    _parent();
    final durable = ref.read(economyCommandsProvider);
    final scope = durable?.capture(widget.familyId, parent: true);
    if (_adjustment == null) {
      final form = GlobalKey<FormState>();
      String coins = '0', xp = '0', reason = '';
      final command = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('家长调账'),
          content: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: coins,
                    decoration: const InputDecoration(
                      labelText: '金币变化（允许负数，只扣可用余额）',
                    ),
                    onChanged: (v) => coins = v,
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n.abs() > 10000
                          ? '请输入-10000至10000的整数'
                          : null;
                    },
                  ),
                  TextFormField(
                    initialValue: xp,
                    decoration: const InputDecoration(labelText: '增加XP（不可扣减）'),
                    onChanged: (v) => xp = v,
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 0 || n > 10000
                          ? '请输入0至10000的整数'
                          : null;
                    },
                  ),
                  TextFormField(
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: '原因'),
                    onChanged: (v) => reason = v,
                    validator: (v) =>
                        (v?.trim().isEmpty ?? true) ? '请输入原因' : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, <String, dynamic>{
                    'coins': int.parse(coins),
                    'xp_amount': int.parse(xp),
                    'reason': reason.trim(),
                    'command_id': const Uuid().v4(),
                  });
                }
              },
              child: const Text('提交调账'),
            ),
          ],
        ),
      );
      if (command == null || !mounted) return;
      if ((command['coins'] as int).abs() > 500) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text('高额调账再次确认'),
            content: Text('本次变更 ${command['coins']} 金币，请确认原因和金额。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认高额调账'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        command['large_amount_confirmed'] = true;
      }
      _adjustment = command;
    }
    _parent();
    if (durable != null) {
      await durable.check(widget.childId, widget.familyId, scope!);
      final command = {..._adjustment!, 'kind': 'adjust'}..remove('command_id');
      final request = await durable.prepare(
        widget.childId,
        widget.familyId,
        command,
        {},
      );
      _adjustment = null;
      ref.invalidate(pendingEconomyCommandProvider(_scope));
      await durable.resolve(
        widget.childId,
        widget.familyId,
        request.requestId,
        'submit',
      );
      return;
    }
    await repository.adjust(widget.childId, _adjustment!);
    _adjustment = null;
  });
  Future<void> _recover(EconomyCommand request, String operation) =>
      _run((_) async {
        final repository = ref.read(economyCommandsProvider)!;
        final scope = repository.capture(
          widget.familyId,
          parent: request.kind == 'adjust',
        );
        if (operation == 'submit' || operation == 'cancel') {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: Text(operation == 'submit' ? '重试原请求？' : '停止未执行请求？'),
              content: Text(
                operation == 'submit'
                    ? '使用已保存的原金额、规则和请求编号。若已受理，不会再次冻结金币或调账。'
                    : '只停止尚未执行的请求。已受理的兑换或调账不会撤回；兑换取消请在兑换记录中操作。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('返回'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确认'),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
        }
        await repository.check(widget.childId, widget.familyId, scope);
        if (operation == 'acknowledge') {
          await repository.acknowledge(
            widget.childId,
            widget.familyId,
            request.requestId,
          );
        } else {
          await repository.resolve(
            widget.childId,
            widget.familyId,
            request.requestId,
            operation,
          );
        }
      });
  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final durable = ref.watch(economyCommandsProvider);
    final pending = ref.watch(pendingEconomyCommandProvider(_scope));
    final blocked =
        durable != null &&
        (pending.isLoading || pending.hasError || pending.valueOrNull != null);
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('金币 XP 与奖励兑换'),
          actions: [
            IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新钱包与申请',
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '奖励商城'),
              Tab(text: '兑换记录'),
              Tab(text: '金币与XP账本'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (durable != null)
              pending.when(
                data: (request) => request == null
                    ? const SizedBox.shrink()
                    : EconomyPendingCommand(
                        request: request,
                        busy: _busy,
                        parent: parent,
                        onAction: (action) => _recover(request, action),
                      ),
                loading: () => const LinearProgressIndicator(),
                error: (_, __) => Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    children: [
                      const Text('本机待确认请求暂时无法读取，请重试。'),
                      TextButton(
                        onPressed: _busy ? null : _refresh,
                        child: const Text('重新读取请求'),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ref
                  .watch(economyDataProvider(_scope))
                  .when(
                    skipLoadingOnRefresh: false,
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              isNetworkFailure(error)
                                  ? '暂时无法连接服务，且本机没有可用的奖励记录。请联网后重试。'
                                  : '奖励记录暂时无法读取，请刷新或重新登录。',
                            ),
                          ),
                          FilledButton(
                            onPressed: _refresh,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                    data: (data) {
                      if (_accessDenied) {
                        return const Center(
                          child: Text('该孩子的数据暂不可访问，请重新登录或刷新核对权限。'),
                        );
                      }
                      _bindPages(data);
                      final readOnly = _busy || _offline;
                      final overview = data['overview'] as Map<String, dynamic>;
                      final progress = XpProgress(
                        (overview['xp'] as num).toInt(),
                      );
                      final rewards = _rows['rewards']!;
                      final redemptions = _rows['redemptions']!;
                      return Column(
                        children: [
                          if (_busy)
                            const Padding(
                              padding: EdgeInsets.all(8),
                              child: Text('操作处理中，请完成确认或等待结果…'),
                            ),
                          ListTile(
                            title: Text(
                              '${_offline ? '离线上次记录：' : ''}可用 ${overview['coin_balance']} · 冻结 ${overview['frozen_balance']} · 待确认 ${overview['pending_coins']} 金币',
                            ),
                            subtitle: Text(
                              'Lv.${progress.level} · XP ${progress.total} · ${progress.level == 50 ? '最高等级' : '本级 ${progress.earnedInLevel}/${progress.nextRequired}'}\n金币用于兑换，XP只用于成长，永不兑换或扣减。',
                            ),
                          ),
                          LinearProgressIndicator(value: progress.fraction),
                          if (overview['reconciled'] != true)
                            const Text('钱包与账本不一致，请联系家长核查，勿继续兑换。'),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _lazyList('rewards', [
                                  if (parent)
                                    () => FilledButton.icon(
                                      onPressed: readOnly
                                          ? null
                                          : () => _edit(),
                                      icon: const Icon(Icons.add),
                                      label: const Text('新增奖励'),
                                    ),
                                  for (final row in rewards.where(
                                    (r) => parent || r['active'] == true,
                                  ))
                                    () => Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${row['title']} · ${row['cost']}金币${row['active'] == true ? '' : '（已下架）'}',
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              '${row['description'] ?? ''}\n${row['rules'] ?? ''}\nLv.${row['minimum_level']}解锁；可用 ${_time.format(row['available_from'], empty: '现在')} 至 ${_time.format(row['available_until'], empty: '不限')}\n${rewardCapacityDescription(row)}',
                                            ),
                                            if (row['blocked_reason'] != null)
                                              Text(
                                                row['blocked_reason'] as String,
                                              ),
                                            const SizedBox(height: 8),
                                            Wrap(
                                              children: [
                                                if (parent)
                                                  IconButton(
                                                    onPressed: readOnly
                                                        ? null
                                                        : () => _edit(row),
                                                    icon: const Icon(
                                                      Icons.edit,
                                                    ),
                                                    tooltip: '编辑奖励',
                                                  ),
                                                FilledButton.tonal(
                                                  onPressed:
                                                      readOnly ||
                                                          blocked ||
                                                          (!_requests
                                                                  .containsKey(
                                                                    row['id'],
                                                                  ) &&
                                                              (row['active'] !=
                                                                      true ||
                                                                  row['can_request'] ==
                                                                      false)) ||
                                                          overview['reconciled'] !=
                                                              true
                                                      ? null
                                                      : () => _request(row),
                                                  child: Text(
                                                    _requests.containsKey(
                                                          row['id'],
                                                        )
                                                        ? '重试申请'
                                                        : '申请',
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (rewards.isEmpty)
                                    () => const Text('暂无奖励，请家长验证PIN后创建。'),
                                  () => _moreButton('rewards'),
                                ]),
                                _lazyList('redemptions', [
                                  for (final row in redemptions)
                                    () => Card(
                                      child: Column(
                                        children: [
                                          ListTile(
                                            title: Text(
                                              '${row['reward_title'] ?? '历史奖励'} · ${redemptionLabels[row['status']] ?? row['status']}',
                                            ),
                                            subtitle: Text(
                                              '冻结金额快照 ${row['frozen_amount']}金币\n${row['reward_rules'] ?? ''}'
                                              '${row['reward_limits'] is Map && (row['reward_limits'] as Map).isNotEmpty ? '\n申请时：${rewardQuotaDescription((row['reward_limits'] as Map).cast<String, dynamic>())}' : ''}'
                                              '\n到期 ${_time.format(row['expires_at'])}\n${row['decision_reason'] ?? ''}',
                                            ),
                                          ),
                                          Wrap(
                                            children: [
                                              if (row['status'] == 'requested')
                                                TextButton(
                                                  onPressed: readOnly
                                                      ? null
                                                      : () => _transition(
                                                          row['id'] as String,
                                                          'cancel',
                                                        ),
                                                  child: const Text('取消申请'),
                                                ),
                                              if (parent &&
                                                  row['status'] ==
                                                      'requested') ...[
                                                TextButton(
                                                  onPressed: readOnly
                                                      ? null
                                                      : () => _transition(
                                                          row['id'] as String,
                                                          'approve',
                                                        ),
                                                  child: const Text('批准'),
                                                ),
                                                TextButton(
                                                  onPressed: readOnly
                                                      ? null
                                                      : () => _transition(
                                                          row['id'] as String,
                                                          'reject',
                                                        ),
                                                  child: const Text('拒绝并退款'),
                                                ),
                                              ],
                                              if (parent &&
                                                  row['status'] == 'approved')
                                                TextButton(
                                                  onPressed: readOnly
                                                      ? null
                                                      : () => _transition(
                                                          row['id'] as String,
                                                          'fulfill',
                                                        ),
                                                  child: const Text('确认已履约'),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (redemptions.isEmpty)
                                    () => const Text('暂无兑换记录。'),
                                  () => _moreButton('redemptions'),
                                ]),
                                _lazyList('ledger', [
                                  () => Text(
                                    '本月收入 ${overview['month_income']} · 已履约消耗 ${overview['month_spent']}金币',
                                  ),
                                  () => Text(
                                    '每日软上限 ${overview['daily_soft_limit']}，超额金币待家长确认，XP照常获得。',
                                  ),
                                  if (parent)
                                    () => Wrap(
                                      children: [
                                        TextButton(
                                          onPressed: readOnly || blocked
                                              ? null
                                              : _adjust,
                                          child: Text(
                                            _adjustment == null
                                                ? '家长调账'
                                                : '重试同一笔调账',
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: readOnly
                                              ? null
                                              : () => _limit(
                                                  (overview['daily_soft_limit']
                                                          as num)
                                                      .toInt(),
                                                ),
                                          child: const Text('配置软上限'),
                                        ),
                                        TextButton(
                                          onPressed: readOnly
                                              ? null
                                              : () => _run((repository) async {
                                                  _parent();
                                                  await repository.reconcile(
                                                    widget.childId,
                                                  );
                                                }),
                                          child: const Text('按账本重算钱包'),
                                        ),
                                      ],
                                    ),
                                  for (final row in _rows['pending']!.where(
                                    (r) => r['status'] == 'pending',
                                  ))
                                    () => Card(
                                      child: ListTile(
                                        title: Text(
                                          '${row['amount']}金币待确认 · ${economySourceLabel(row['source_type'])}',
                                        ),
                                        subtitle: Text(
                                          _time.format(row['created_at']),
                                        ),
                                        trailing: !parent
                                            ? null
                                            : Wrap(
                                                children: [
                                                  IconButton(
                                                    onPressed: readOnly
                                                        ? null
                                                        : () => _decide(
                                                            row['id'] as String,
                                                            true,
                                                          ),
                                                    icon: const Icon(
                                                      Icons.check,
                                                    ),
                                                    tooltip: '确认发放',
                                                  ),
                                                  IconButton(
                                                    onPressed: readOnly
                                                        ? null
                                                        : () => _decide(
                                                            row['id'] as String,
                                                            false,
                                                          ),
                                                    icon: const Icon(
                                                      Icons.close,
                                                    ),
                                                    tooltip: '拒绝超额',
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                                  () => _moreButton('pending'),
                                  for (final row in _rows['ledger']!)
                                    () => ListTile(
                                      title: Text(ledgerChangeLabel(row)),
                                      subtitle: Text(
                                        '${economySourceLabel(row['source_type'])} · ${_time.format(row['created_at'])}'
                                        '${row['source_type'] == 'parent_adjustment' ? '\n${parent && !_offline ? '点击查看操作人和原因' : '联网并验证家长PIN后可查看调账明细'}' : ''}',
                                      ),
                                      onTap:
                                          row['source_type'] ==
                                                  'parent_adjustment' &&
                                              parent &&
                                              !_offline
                                          ? () => Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    WalletAdjustmentScreen(
                                                      scope: (
                                                        child: widget.childId,
                                                        family: widget.familyId,
                                                        entryId:
                                                            row['id'] as String,
                                                      ),
                                                    ),
                                              ),
                                            )
                                          : null,
                                    ),
                                  () => _moreButton('ledger'),
                                ]),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

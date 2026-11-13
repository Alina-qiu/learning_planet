import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../application/family_providers.dart';
import '../application/family_time_providers.dart';
import '../data/family_time_repository.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/schedule_repository.dart';

const familyTimezoneLabels = <String, String>{
  'Asia/Shanghai': '北京、上海（中国）',
  'Asia/Hong_Kong': '香港',
  'Asia/Taipei': '台北',
  'Asia/Tokyo': '东京',
  'Asia/Singapore': '新加坡',
  'Europe/London': '伦敦',
  'America/New_York': '纽约',
  'America/Los_Angeles': '洛杉矶',
  'Australia/Sydney': '悉尼',
  'UTC': '协调世界时',
};
String familyTimezoneLabel(String zone) => familyTimezoneLabels[zone] ?? zone;

class FamilyTimeScreen extends ConsumerStatefulWidget {
  const FamilyTimeScreen({required this.familyId, super.key});
  final String familyId;
  @override
  ConsumerState<FamilyTimeScreen> createState() => _FamilyTimeScreenState();
}

class _FamilyTimeScreenState extends ConsumerState<FamilyTimeScreen> {
  FamilyTimeSettings? _settings;
  String? _selected, _error;
  bool _busy = true, _uncertain = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  bool current(int generation) =>
      mounted &&
      generation == _generation &&
      ref.read(activeParentFamilyProvider) == widget.familyId;
  FamilyTimeRepository repository() =>
      ref.read(familyTimeRepositoryProvider) ??
      (throw StateError('当前环境尚未连接服务'));
  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      final loaded = await repository().load(widget.familyId);
      if (!current(generation)) return;
      setState(() {
        _settings = loaded;
        _selected = loaded.timezone;
        _error = null;
        _uncertain = false;
      });
    } catch (error) {
      if (current(generation)) setState(() => _error = '读取家庭时区失败：$error');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void invalidate(FamilyTimeSettings settings) {
    ref.invalidate(familiesProvider);
    for (final child in settings.children) {
      ref.invalidate(tasksProvider(child));
      ref.invalidate(familyTodayProvider(child));
      ref.invalidate(walletProvider(child));
      ref.invalidate(schedulesProvider(child));
      ref.invalidate(remindersProvider(child));
    }
  }

  Future<void> _save() async {
    final before = _settings, selection = _selected;
    if (_busy || before == null || selection == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await repository().save(before, selection);
      if (!mounted || !current(generation)) return;
      invalidate(saved);
      setState(() {
        _settings = saved;
        _selected = saved.timezone;
        _uncertain = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('家庭时区已保存')));
    } catch (error) {
      if (current(generation)) {
        invalidate(before);
        setState(() {
          _uncertain = true;
          _error = '保存结果尚未确认，请刷新核对或重试原设置。$error';
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _choose() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _TimezonePicker(current: _selected),
    );
    if (mounted && !_busy && !_uncertain && selected != null) {
      setState(() => _selected = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId,
        settings = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('家庭时区')),
      body: !authorized
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text('仅家庭管理员可以修改。任务日期、学习报告及每日金币上限以家庭时区为准，手机时区变化不会自动修改它。'),
                const SizedBox(height: 16),
                if (_busy) const LinearProgressIndicator(),
                if (settings != null) ...[
                  Text('当前：${familyTimezoneLabel(settings.timezone)}'),
                  Text(settings.timezone),
                  Text('家庭今天：${settings.today}'),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _busy || _uncertain ? null : _choose,
                    icon: const Icon(Icons.public),
                    label: Text('选择时区：${familyTimezoneLabel(_selected!)}'),
                  ),
                  if (_selected != settings.timezone) Text('将改为：$_selected'),
                  const SizedBox(height: 16),
                  const Text(
                    '已生成的任务时间和复习到期时间保持原值；后续任务按新时区生成。切回已有日期不会重复建任务，也不会补建中间日期。修改会记录操作者和前后时区。',
                  ),
                  const SizedBox(height: 12),
                  const Text('保存期间会暂停本机提醒，联网更新后按新时区恢复。其他离线设备需联网刷新后才能更新本地提醒。'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        _busy || (!_uncertain && _selected == settings.timezone)
                        ? null
                        : _save,
                    child: Text(_uncertain ? '重试原设置' : '保存时区'),
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_error!),
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: Text(_uncertain ? '刷新核对' : '刷新家庭时区'),
                ),
              ],
            ),
    );
  }
}

class _TimezonePicker extends StatefulWidget {
  const _TimezonePicker({this.current});
  final String? current;
  @override
  State<_TimezonePicker> createState() => _TimezonePickerState();
}

class _TimezonePickerState extends State<_TimezonePicker> {
  late final List<String> zones;
  String query = '';
  @override
  void initState() {
    super.initState();
    tzdata.initializeTimeZones();
    final rest = tz.timeZoneDatabase.locations.keys.toList()..sort();
    zones = <String>{
      if (widget.current != null) widget.current!,
      ...familyTimezoneLabels.keys,
      ...rest,
    }.toList();
  }

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase(),
        visible = zones
            .where(
              (zone) => '$zone ${familyTimezoneLabel(zone)}'
                  .toLowerCase()
                  .contains(needle),
            )
            .toList();
    return AlertDialog(
      scrollable: true,
      title: const Text('选择家庭时区'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                labelText: '搜索城市或时区',
                hintText: '例如：纽约、Asia/Shanghai',
              ),
            ),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * .35,
              child: visible.isEmpty
                  ? const Center(child: Text('没有匹配的时区'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final zone = visible[index];
                        return ListTile(
                          title: Text(familyTimezoneLabel(zone)),
                          subtitle: Text(zone),
                          onTap: () => Navigator.pop(context, zone),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

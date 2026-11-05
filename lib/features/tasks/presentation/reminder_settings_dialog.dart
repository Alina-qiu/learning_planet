import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../../notifications/data/parent_notification_device.dart';
import '../../reports/presentation/configuration_time_scope.dart';
import '../data/notification_scheduler.dart';
import '../data/schedule_repository.dart';

class ReminderSettingsDialog extends ConsumerStatefulWidget {
  const ReminderSettingsDialog({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;

  @override
  ConsumerState<ReminderSettingsDialog> createState() =>
      _ReminderSettingsDialogState();
}

class _ReminderSettingsDialogState
    extends ConsumerState<ReminderSettingsDialog> {
  final _form = GlobalKey<FormState>();
  final _start = TextEditingController(), _end = TextEditingController();
  bool _enabled = true, _loaded = false, _busy = false;
  bool _unknown = false, _saved = false, _needsSync = false;
  String? _message;

  bool get _authorized =>
      mounted &&
      ref.read(activeParentFamilyProvider) == widget.familyId &&
      (ref.read(selectedChildIdProvider) == null ||
          ref.read(selectedChildIdProvider) == widget.childId);

  void _check() {
    if (!_authorized) throw StateError('孩子或家长授权已变化，请重新验证家长 PIN');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      _check();
      final value = await ref
          .read(scheduleRepositoryProvider)
          .reminderSettings(widget.childId);
      _check();
      _enabled = value['enabled'] as bool;
      _start.text = (value['quiet_start'] as String).substring(0, 5);
      _end.text = (value['quiet_end'] as String).substring(0, 5);
      _loaded = true;
      final reconciling = _unknown;
      _unknown = false;
      _saved = reconciling;
      if (reconciling) {
        _needsSync = true;
        _message = '已读取服务器当前设置，请核对开关和静默时间。';
      }
    } catch (error) {
      if (mounted) _message = '读取失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    _check();
    final modeRevision = ref.read(parentNotificationDeviceRevisionProvider);
    final device = ref.read(parentNotificationDeviceProvider);
    Future<bool> childMode() async {
      _check();
      final parent = await device?.isParentMode(widget.familyId) ?? false;
      _check();
      if (ref.read(parentNotificationDeviceRevisionProvider) != modeRevision) {
        throw StateError('本机提醒模式已变化，请重新同步');
      }
      return !parent;
    }

    if (!await childMode()) {
      _needsSync = false;
      _message = '设置已确认。此设备继续接收家长消息。';
      return;
    }
    final scheduler = ref.read(notificationSchedulerProvider);
    if (_enabled && !await scheduler.requestPermission()) {
      throw StateError('系统通知未授权或此平台不支持；应用内提醒仍可使用');
    }
    _check();
    final rows = await ref
        .read(scheduleRepositoryProvider)
        .loadReminders(widget.childId);
    if (!await childMode()) {
      _needsSync = false;
      _message = '设置已确认。此设备继续接收家长消息。';
      return;
    }
    await scheduler.setScope(widget.childId);
    _check();
    await scheduler.synchronize(widget.childId, rows);
    _check();
    _needsSync = false;
    _message = '设置已确认，本机提醒已更新。';
  }

  Future<void> _save() async {
    if (_busy || _unknown || !_loaded || !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      _check();
      await ref
          .read(scheduleRepositoryProvider)
          .saveReminderSettings(
            widget.childId,
            _enabled,
            _start.text.trim(),
            _end.text.trim(),
            canConfigure: () => _authorized,
          );
      if (!mounted) return;
      _saved = true;
      _needsSync = true;
      try {
        await _sync();
      } catch (error) {
        if (mounted) _message = '设置已保存，本机提醒尚未更新：$error';
      }
    } catch (error) {
      if (mounted) {
        _unknown = isNetworkFailure(error);
        _message = _unknown ? '保存结果尚未确认。请联网后重新读取设置，再决定是否修改。' : '未能保存：$error';
      }
    } finally {
      if (mounted) {
        ref.invalidate(remindersProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _retrySync() async {
    setState(() => _busy = true);
    try {
      await _sync();
    } catch (error) {
      if (mounted) _message = '设置已确认，本机提醒尚未更新：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edited(BuildContext context) {
    ConfigurationTimeScope.activity(context);
    setState(() {
      _saved = false;
      _needsSync = false;
      _message = null;
    });
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(activeParentFamilyProvider);
    ref.watch(selectedChildIdProvider);
    final editable = _authorized && _loaded && !_busy && !_unknown;
    String? validateTime(String? value) =>
        RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value?.trim() ?? '')
        ? null
        : '请输入 HH:mm，例如 21:00';
    Widget dialog(BuildContext context) => PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('提醒与静默时段'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_loaded) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用提醒'),
                      value: _enabled,
                      onChanged: editable
                          ? (value) {
                              _enabled = value;
                              _edited(context);
                            }
                          : null,
                    ),
                    TextFormField(
                      controller: _start,
                      enabled: editable,
                      validator: validateTime,
                      onChanged: (_) => _edited(context),
                      decoration: const InputDecoration(
                        labelText: '静默开始 HH:mm',
                      ),
                    ),
                    TextFormField(
                      controller: _end,
                      enabled: editable,
                      validator: validateTime,
                      onChanged: (_) => _edited(context),
                      decoration: const InputDecoration(
                        labelText: '静默结束 HH:mm',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('按家庭时区；相同时间的提醒合并。相同起止时间表示不静默。'),
                  ],
                  if (!_authorized) const Text('请重新验证家长 PIN，或返回当前孩子的设置。'),
                  if (_message != null) Text(_message!),
                  if (_needsSync)
                    TextButton(
                      onPressed: _busy || !_authorized ? null : _retrySync,
                      child: const Text('重试本机提醒'),
                    ),
                  TextButton(
                    onPressed: _busy || !_authorized ? null : _load,
                    child: const Text('重新读取设置'),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(_saved ? '完成' : '关闭'),
          ),
          FilledButton(
            onPressed: editable && !_saved ? _save : null,
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return editable && !_saved
        ? ConfigurationTimeScope(
            childId: widget.childId,
            familyId: widget.familyId,
            kind: ConfigurationKind.rules,
            child: Builder(builder: dialog),
          )
        : dialog(context);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../../notifications/data/parent_notification_device.dart';
import '../../tasks/data/notification_scheduler.dart';
import '../../tasks/data/schedule_repository.dart';
import '../data/review_reminder_repository.dart';
import '../domain/review_reminder.dart';

class ReviewReminderDialog extends ConsumerStatefulWidget {
  const ReviewReminderDialog({
    required this.childId,
    required this.familyId,
    required this.taskId,
    super.key,
  });
  final String childId, familyId, taskId;
  @override
  ConsumerState<ReviewReminderDialog> createState() =>
      _ReviewReminderDialogState();
}

class _ReviewReminderDialogState extends ConsumerState<ReviewReminderDialog> {
  ReviewReminder? _state;
  ({String id, int minutes, int revision})? _pending;
  bool _busy = true, _needsSync = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _current =>
      mounted &&
      (ref.read(selectedChildIdProvider) == null ||
          ref.read(selectedChildIdProvider) == widget.childId);
  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await ref
          .read(reviewReminderRepositoryProvider)
          .load(widget.taskId);
      if (!_current) return;
      setState(() {
        _state = state;
        _pending = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '读取失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkDevice() async {
    if (!_current) throw StateError('当前孩子已变化');
    final device = ref.read(parentNotificationDeviceProvider);
    if (device != null && await device.isParentMode(widget.familyId)) {
      throw StateError('此设备接收家长提醒，请先在家长消息中切换为孩子任务提醒');
    }
    if (!_current) throw StateError('当前孩子已变化');
  }

  Future<void> _sync() async {
    await _checkDevice();
    final scheduler = ref.read(notificationSchedulerProvider);
    final rows = await ref
        .read(scheduleRepositoryProvider)
        .loadReminders(widget.childId);
    await _checkDevice();
    await scheduler.setScope(widget.childId);
    if (!_current) return;
    await scheduler.synchronize(widget.childId, rows);
    if (_state?.at != null &&
        !rows
            .where(
              (row) =>
                  DateTime.tryParse(
                    row['remind_at'] as String? ?? '',
                  )?.isAfter(DateTime.now()) ==
                  true,
            )
            .take(60)
            .any(
              (row) => (row['tasks'] as List? ?? []).any(
                (task) => task is Map && task['task_id'] == widget.taskId,
              ),
            )) {
      throw StateError('预约当前无法在本机排程，请重新核对任务、提醒设置或待发数量');
    }
    if (mounted) setState(() => _needsSync = false);
  }

  Future<void> _submit(int minutes) async {
    if (_busy || !_current || _state == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (minutes > 0) {
        await _checkDevice();
        if (!await ref
            .read(notificationSchedulerProvider)
            .requestPermission()) {
          throw StateError('未取得系统通知权限，请授权后重试');
        }
        await _checkDevice();
      }
      if (!_current) return;
      _pending ??= (
        id: const Uuid().v4(),
        minutes: minutes,
        revision: _state!.revision,
      );
      final request = _pending!;
      final state = await ref.read(scheduleRepositoryProvider).changeReminders(
        widget.childId,
        () async {
          await _checkDevice();
          await ref.read(notificationSchedulerProvider).setScope(null);
          if (!_current) throw StateError('当前孩子已变化');
          return ref
              .read(reviewReminderRepositoryProvider)
              .set(
                widget.taskId,
                request.minutes,
                request.revision,
                request.id,
              );
        },
      );
      if (!_current) return;
      setState(() {
        _state = state;
        _pending = null;
        _needsSync = true;
      });
      ref.invalidate(remindersProvider(widget.childId));
      try {
        await _sync();
      } catch (error) {
        if (mounted) setState(() => _error = '预约已保存，本机提醒同步失败：$error');
      }
    } catch (error) {
      if (!isNetworkFailure(error)) _pending = null;
      if (mounted) {
        setState(
          () =>
              _error = _pending == null ? '未能设置：$error' : '结果尚未确认，请重试原请求或重新核对。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retrySync() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sync();
    } catch (error) {
      if (mounted) setState(() => _error = '本机提醒同步失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('稍后提醒我复习'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('为今天的复习队列预约一次提醒。题目和复测日期保持不变，仍可随时开始。'),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_state case final state?) ...[
              Text(
                state.at == null
                    ? '当前没有未来预约'
                    : '已预约：${state.local ?? state.at!.toLocal()}',
              ),
              if (!state.allowed)
                const Text('这次复习已结束，不能再预约提醒。')
              else if (!state.enabled)
                const Text('家长已关闭任务提醒。')
              else
                Wrap(
                  spacing: 8,
                  children: [
                    for (final minutes in [15, 30, 60])
                      OutlinedButton(
                        onPressed: _busy || _pending != null
                            ? null
                            : () => _submit(minutes),
                        child: Text('约 $minutes 分钟后'),
                      ),
                  ],
                ),
              if (state.at != null)
                TextButton(
                  onPressed: _busy || _pending != null
                      ? null
                      : () => _submit(0),
                  child: const Text('取消这次预约'),
                ),
            ],
            if (_error != null) Text(_error!, semanticsLabel: _error),
            if (_pending != null)
              TextButton(
                onPressed: _busy ? null : () => _submit(_pending!.minutes),
                child: const Text('重试原请求'),
              ),
            if (_needsSync)
              TextButton(
                onPressed: _busy ? null : _retrySync,
                child: const Text('重试本机提醒'),
              ),
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('重新核对'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

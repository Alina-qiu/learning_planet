import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../application/task_providers.dart';
import '../domain/schedule_config.dart';
import 'offline_task_repository.dart';
import 'notification_scheduler.dart';
import '../../../core/offline/network_failure.dart';
import '../domain/task_reminders.dart';
import '../domain/schedule_snapshot.dart';
import 'schedule_snapshots.dart';

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) {
    throw StateError('开发环境尚未配置 Supabase。');
  }
  final scheduler = ref.watch(notificationSchedulerProvider);
  return ScheduleRepository(
    client,
    offline: tasks is OfflineTaskRepository ? tasks : null,
    beforeReminderChange: scheduler is TaskReminderCancellation
        ? (scheduler as TaskReminderCancellation).cancelTaskReminders
        : null,
  );
});
final schedulesProvider = FutureProvider.autoDispose
    .family<ScheduleSnapshot, String>(
      (ref, childId) =>
          ref.watch(scheduleRepositoryProvider).loadSchedules(childId),
    );
final remindersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, childId) =>
          ref.watch(scheduleRepositoryProvider).loadReminders(childId),
    );

class ScheduleRepository {
  ScheduleRepository(this.client, {this.offline, this.beforeReminderChange})
    : snapshots = ScheduleSnapshots(
        client,
        store: offline?.store,
        accountId: offline?.accountId,
      );
  final SupabaseClient client;
  final ScheduleSnapshots snapshots;
  final OfflineTaskRepository? offline;
  final Future<void> Function(String childId)? beforeReminderChange;
  final _changingReminders = <String>{};
  final _memoryReminderVersions = <String, int>{};
  Future<int> _reminderVersion(String? owner, String childId) async {
    if (offline == null || owner == null) {
      return _memoryReminderVersions['$owner:$childId'] ?? 0;
    }
    return (await offline!.store.read(
              owner,
              'reminder-version:$childId',
            ))?['value']
            as int? ??
        0;
  }

  /// Fence in-flight loads and remove old cached plans even when the write reply
  /// is lost. The next online load reconciles the authoritative appointment.
  Future<T> changeReminders<T>(
    String childId,
    Future<T> Function() action,
  ) async {
    final owner = offline?.accountId() ?? client.auth.currentUser?.id;
    final privacy = offline?.store.privacyGeneration;
    final key = '$owner:$childId';
    if (owner == null || !_changingReminders.add(key)) {
      throw StateError('提醒正在更新或账号已退出');
    }
    void check() {
      if ((offline?.accountId() ?? client.auth.currentUser?.id) != owner ||
          offline?.store.privacyGeneration != privacy) {
        throw StateError('提醒账号或孩子数据已变化');
      }
    }

    Future<void> retire() async {
      check();
      final store = offline?.store;
      if (store == null) {
        _memoryReminderVersions[key] = (_memoryReminderVersions[key] ?? 0) + 1;
      } else {
        await store.transaction(() async {
          final next = await _reminderVersion(owner, childId) + 1;
          check();
          await store.write(owner, 'reminder-version:$childId', {
            'value': next,
          });
          await store.remove(owner, 'reminders:$childId');
          check();
        });
      }
    }

    try {
      await retire();
      try {
        await beforeReminderChange?.call(childId);
        check();
        final result = await action();
        check();
        return result;
      } finally {
        await retire();
      }
    } finally {
      _changingReminders.remove(key);
    }
  }

  Future<DateTime> today(String childId) async => DateTime.parse(
    await client.rpc<String>(
      'family_today',
      params: {'target_child_id': childId},
    ),
  );
  Future<ScheduleSnapshot> loadSchedules(String childId) =>
      snapshots.load(childId);

  Future<void> save(
    String childId,
    ScheduleConfig config, {
    String? templateId,
  }) => snapshots.change(childId, () async {
    await client.rpc<dynamic>(
      'save_task_schedule',
      params: {
        'target_child_id': childId,
        'config': config.toJson(),
        'target_template_id': templateId,
      },
    );
  });

  Future<void> setActive(String childId, String id, bool active) =>
      snapshots.change(
        childId,
        () => client.rpc<void>(
          'set_schedule_active',
          params: {'target_template_id': id, 'enabled': active},
        ),
      );
  Future<void> approveLeave(
    String childId,
    String id,
    DateTime day,
    String reason,
  ) => snapshots.change(
    childId,
    () => client.rpc<void>(
      'approve_plan_leave',
      params: {
        'target_plan_id': id,
        'day': scheduleDate(day),
        'leave_reason': reason,
      },
    ),
  );
  Future<double> settle(String childId, String id) =>
      snapshots.change(childId, () async {
        final value = await client.rpc<dynamic>(
          'settle_long_plan',
          params: {'target_plan_id': id},
        );
        return (value as num).toDouble();
      });

  Future<List<Map<String, dynamic>>> loadReminders(String childId) async {
    final owner = offline?.accountId() ?? client.auth.currentUser?.id;
    final store = offline?.store;
    final generation = store?.privacyGeneration;
    final version = await _reminderVersion(owner, childId);
    void check() {
      if ((offline?.accountId() ?? client.auth.currentUser?.id) != owner ||
          store?.privacyGeneration != generation ||
          _changingReminders.contains('$owner:$childId')) {
        throw StateError('账号或孩子数据已变化，请刷新提醒');
      }
    }

    Future<void> checkVersion() async {
      check();
      if (version != await _reminderVersion(owner, childId)) {
        throw StateError('提醒已更新，请重新加载');
      }
      check();
    }

    await checkVersion();

    List<Map<String, dynamic>> rows;
    try {
      final values = await client
          .rpc<List<dynamic>>(
            'load_task_reminders',
            params: {'target_child_id': childId},
          )
          .timeout(const Duration(seconds: 10));
      await checkVersion();
      rows = values.cast<Map<String, dynamic>>();
      if (store != null && owner != null) {
        await store.transaction(() async {
          await checkVersion();
          await store.write(owner, 'reminders:$childId', {
            'items': rows,
            'version': version,
          });
        });
      }
    } catch (error) {
      await checkVersion();
      if (error is PostgrestException &&
          error.code == '42501' &&
          store != null &&
          owner != null) {
        await store.remove(owner, 'reminders:$childId');
      }
      if (!isNetworkFailure(error) || store == null || owner == null) rethrow;
      final cached = await store.read(owner, 'reminders:$childId');
      if (cached == null || (cached['version'] ?? 0) != version) rethrow;
      rows = (cached['items'] as List).cast<Map<String, dynamic>>();
    }
    final projected = await offline?.loadTasks(childId);
    await checkVersion();
    return projected == null ? rows : filterTaskReminders(rows, projected);
  }

  Future<Map<String, dynamic>> reminderSettings(String childId) async {
    final owner = offline?.accountId() ?? client.auth.currentUser?.id;
    final privacy = offline?.store.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    final result = await client
        .from('reminder_settings')
        .select()
        .eq('child_id', childId)
        .maybeSingle()
        .timeout(const Duration(seconds: 10));
    if ((offline?.accountId() ?? client.auth.currentUser?.id) != owner ||
        offline?.store.privacyGeneration != privacy) {
      throw StateError('提醒账号或孩子数据已变化');
    }
    return result ??
        {'enabled': true, 'quiet_start': '21:00', 'quiet_end': '07:00'};
  }

  Future<void> saveReminderSettings(
    String childId,
    bool enabled,
    String start,
    String end, {
    bool Function()? canConfigure,
  }) async {
    final pattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
    if (!pattern.hasMatch(start) || !pattern.hasMatch(end)) {
      throw const FormatException('静默时间格式为 HH:mm');
    }
    if (canConfigure != null && !canConfigure()) {
      throw StateError('请重新验证家长 PIN');
    }
    await changeReminders(childId, () async {
      if (canConfigure != null && !canConfigure()) {
        throw StateError('请重新验证家长 PIN');
      }
      await client
          .from('reminder_settings')
          .upsert({
            'child_id': childId,
            'enabled': enabled,
            'quiet_start': start,
            'quiet_end': end,
          })
          .timeout(const Duration(seconds: 10));
    });
  }

  Future<void> acknowledge(String childId, String key) async {
    await changeReminders(childId, () async {
      await client
          .from('reminder_receipts')
          .upsert({'child_id': childId, 'reminder_key': key})
          .timeout(const Duration(seconds: 10));
    });
  }
}

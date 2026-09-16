import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../application/task_providers.dart';
import '../domain/schedule_config.dart';
import 'task_repository.dart';

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  if (tasks is! SupabaseTaskRepository) {
    throw StateError('开发环境尚未配置 Supabase。');
  }
  return ScheduleRepository(tasks.client);
});
final schedulesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, childId) =>
          ref.watch(scheduleRepositoryProvider).loadSchedules(childId),
    );
final remindersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, childId) =>
          ref.watch(scheduleRepositoryProvider).loadReminders(childId),
    );

class ScheduleRepository {
  ScheduleRepository(this.client);
  final SupabaseClient client;
  Future<DateTime> today(String childId) async => DateTime.parse(
    await client.rpc<String>(
      'family_today',
      params: {'target_child_id': childId},
    ),
  );
  Future<List<Map<String, dynamic>>> loadSchedules(String childId) async {
    final rows = await client
        .from('task_templates')
        .select(
          '*, long_plans(*, plan_leaves(*), plan_stage_rewards(*), plan_bonus_tiers(*))',
        )
        .eq('child_id', childId)
        .order('created_at', ascending: false);
    for (final row in rows) {
      final value = row['long_plans'];
      final plan = value is Map<String, dynamic>
          ? value
          : value is List && value.isNotEmpty
          ? value.first as Map<String, dynamic>
          : null;
      if (plan != null) {
        final progress = await client.rpc<List<dynamic>>(
          'long_plan_progress',
          params: {'target_plan_id': plan['id']},
        );
        plan['progress'] = progress.single;
      }
    }
    return rows;
  }

  Future<void> save(
    String childId,
    ScheduleConfig config, {
    String? templateId,
  }) async {
    await client.rpc<dynamic>(
      'save_task_schedule',
      params: {
        'target_child_id': childId,
        'config': config.toJson(),
        'target_template_id': templateId,
      },
    );
  }

  Future<void> setActive(String id, bool active) => client.rpc<void>(
    'set_schedule_active',
    params: {'target_template_id': id, 'enabled': active},
  );
  Future<void> approveLeave(String id, DateTime day, String reason) =>
      client.rpc<void>(
        'approve_plan_leave',
        params: {
          'target_plan_id': id,
          'day': scheduleDate(day),
          'leave_reason': reason,
        },
      );
  Future<double> settle(String id) async {
    final value = await client.rpc<dynamic>(
      'settle_long_plan',
      params: {'target_plan_id': id},
    );
    return (value as num).toDouble();
  }

  Future<List<Map<String, dynamic>>> loadReminders(String childId) async {
    final values = await client.rpc<List<dynamic>>(
      'load_task_reminders',
      params: {'target_child_id': childId},
    );
    return values.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> reminderSettings(String childId) async =>
      await client
          .from('reminder_settings')
          .select()
          .eq('child_id', childId)
          .maybeSingle() ??
      {'enabled': true, 'quiet_start': '21:00', 'quiet_end': '07:00'};
  Future<void> saveReminderSettings(
    String childId,
    bool enabled,
    String start,
    String end,
  ) async {
    final pattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
    if (!pattern.hasMatch(start) || !pattern.hasMatch(end)) {
      throw const FormatException('静默时间格式为 HH:mm');
    }
    await client.from('reminder_settings').upsert({
      'child_id': childId,
      'enabled': enabled,
      'quiet_start': start,
      'quiet_end': end,
    });
  }

  Future<void> acknowledge(String childId, String key) async {
    await client.from('reminder_receipts').upsert({
      'child_id': childId,
      'reminder_key': key,
    });
  }
}

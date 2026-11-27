import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../domain/review_reminder.dart';

abstract interface class ReviewReminderRepository {
  Future<ReviewReminder> load(String taskId);
  Future<ReviewReminder> set(
    String taskId,
    int minutes,
    int revision,
    String commandId,
  );
}

final reviewReminderRepositoryProvider = Provider<ReviewReminderRepository>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) throw StateError('开发环境尚未配置 Supabase。');
  return SupabaseReviewReminderRepository(
    client,
    privacyGeneration: tasks is OfflineTaskRepository
        ? () => tasks.store.privacyGeneration
        : null,
  );
});

class SupabaseReviewReminderRepository implements ReviewReminderRepository {
  SupabaseReviewReminderRepository(this.client, {this.privacyGeneration});
  final SupabaseClient client;
  final int Function()? privacyGeneration;
  Future<ReviewReminder> _call(String name, Map<String, Object> params) async {
    final owner = client.auth.currentUser?.id,
        privacy = privacyGeneration?.call();
    if (owner == null) throw StateError('请先登录');
    final row = await client
        .rpc<Map<String, dynamic>>(name, params: params)
        .timeout(const Duration(seconds: 10));
    if (owner != client.auth.currentUser?.id ||
        privacy != privacyGeneration?.call()) {
      throw StateError('账号或孩子数据已变化，请重新打开复习');
    }
    return ReviewReminder.fromJson(row);
  }

  @override
  Future<ReviewReminder> load(String taskId) =>
      _call('review_reminder_state', {'target_task_id': taskId});
  @override
  Future<ReviewReminder> set(
    String taskId,
    int minutes,
    int revision,
    String commandId,
  ) {
    if (!const {0, 15, 30, 60}.contains(minutes) ||
        revision < 0 ||
        commandId.isEmpty) {
      throw ArgumentError('无效的复习提醒请求');
    }
    return _call('set_review_reminder', {
      'target_task_id': taskId,
      'delay_minutes': minutes,
      'expected_revision': revision,
      'command_id': commandId,
    });
  }
}

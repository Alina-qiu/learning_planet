import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class AiWeeklyReportRepository {
  Future<Map<String, dynamic>> context(String childId, String endDate);
  Future<void> feedback(String childId, String requestId, String itemKey);
}

final aiWeeklyReportRepositoryProvider = Provider<AiWeeklyReportRepository>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (tasks is! OfflineTaskRepository || client == null) {
    throw StateError('请先登录');
  }
  return SupabaseAiWeeklyReportRepository(client, tasks.store);
});

class SupabaseAiWeeklyReportRepository implements AiWeeklyReportRepository {
  SupabaseAiWeeklyReportRepository(this.client, this.store);
  final SupabaseClient client;
  final OfflineStore store;
  Future<Map<String, dynamic>> _rpc(
    String child,
    String name,
    Map<String, dynamic> params,
  ) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final generation = store.reviewGeneration(owner);
    Future<void> guard() async {
      if (client.auth.currentUser?.id != owner ||
          store.reviewGeneration(owner) != generation ||
          await store.accountDeletionJob(owner) != null ||
          await store.isChildDeleted(child)) {
        throw StateError('资料或登录状态已变化');
      }
      if (client.auth.currentUser?.id != owner ||
          store.reviewGeneration(owner) != generation) {
        throw StateError('资料已清理');
      }
    }

    await guard();
    final result = await client
        .rpc<Map<String, dynamic>>(name, params: params)
        .timeout(const Duration(seconds: 15));
    await guard();
    return result;
  }

  @override
  Future<Map<String, dynamic>> context(String childId, String endDate) async {
    final result = await _rpc(childId, 'weekly_report_ai_context', {
      'target_child_id': childId,
      'anchor_date': endDate,
    });
    if (result['child_id'] != childId ||
        (result['input'] as Map?)?['end_date'] != endDate) {
      throw StateError('报告范围不匹配');
    }
    return result;
  }

  @override
  Future<void> feedback(
    String childId,
    String requestId,
    String itemKey,
  ) async {
    final receipt = await _rpc(childId, 'feedback_ai_report', {
      'target_child_id': childId,
      'request_id': requestId,
      'item_key': itemKey,
    });
    if (receipt['request_id'] != requestId || receipt['item_key'] != itemKey) {
      throw StateError('反馈回执不匹配');
    }
  }
}

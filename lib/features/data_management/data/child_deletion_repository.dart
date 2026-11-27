import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class ChildDeletionRepository {
  Future<Map<String, dynamic>> preview(String childId);
  Future<void> request(
    String childId,
    String requestId,
    Map<String, dynamic> counts,
  );
  Future<void> retry(String jobId);
  Future<List<Map<String, dynamic>>> history(String familyId);
}

final childDeletionRepositoryProvider = Provider<ChildDeletionRepository>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseChildDeletionRepository(
    client,
    forgetChild: tasks is OfflineTaskRepository ? tasks.forgetChild : null,
  );
});
final childDeletionHistoryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, familyId) {
      if (ref.watch(activeParentFamilyProvider) != familyId) {
        throw StateError('请验证家长 PIN');
      }
      return ref.watch(childDeletionRepositoryProvider).history(familyId);
    });

class SupabaseChildDeletionRepository implements ChildDeletionRepository {
  SupabaseChildDeletionRepository(this.client, {this.forgetChild});
  final SupabaseClient client;
  final Future<void> Function(String childId)? forgetChild;
  Future<T> _read<T>(String rpc, Map<String, dynamic> params) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final result = await client
        .rpc<T>(rpc, params: params)
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    return result;
  }

  @override
  Future<Map<String, dynamic>> preview(String childId) =>
      _read('preview_child_deletion', {'target_child_id': childId});
  @override
  Future<void> request(
    String childId,
    String requestId,
    Map<String, dynamic> counts,
  ) async {
    final result = await _read<String>('request_child_deletion', {
      'target_child_id': childId,
      'request_id': requestId,
      'expected_counts': counts,
      'confirmation': '永久删除孩子',
    });
    if (result != requestId) throw StateError('删除回执不匹配，请查询记录');
    await forgetChild?.call(childId);
  }

  @override
  Future<List<Map<String, dynamic>>> history(String familyId) async =>
      (await _read<List<dynamic>>('child_deletion_history', {
        'target_family_id': familyId,
      })).cast<Map<String, dynamic>>();
  @override
  Future<void> retry(String jobId) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final response = await client.functions
        .invoke('permanent-cleanup', body: {'job_id': jobId})
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    final data = response.data as Map?;
    if (!const {200, 202}.contains(response.status) ||
        data?['job_id'] != jobId ||
        !const {'running', 'completed'}.contains(data?['status'])) {
      throw StateError('文件清理未确认，请稍后重试');
    }
  }
}

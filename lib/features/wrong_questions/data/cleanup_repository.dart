import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../../core/offline/offline_media_store.dart';

abstract interface class CleanupRepository {
  Future<Map<String, dynamic>> preview(
    String child,
    String scope,
    List<String> ids,
  );
  Future<void> request(
    String child,
    String scope,
    List<String> ids,
    String key,
    String confirmation,
  );
  Future<void> retry(String jobId);
  Future<List<Map<String, dynamic>>> jobs(String child);
}

final cleanupRepositoryProvider = Provider<CleanupRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseCleanupRepository(
    client,
    clearReviewCache: (child, scope, ids, drafts) async {
      if (tasks is OfflineTaskRepository) {
        final owner = tasks.accountId();
        if (owner != null) {
          await tasks.store.removeReviewCache(
            owner,
            childId: child,
            questionIds: ids.toSet(),
            discardCommands: scope == 'questions',
          );
          for (final id in drafts) {
            await tasks.store.discardImageDraft(owner, id);
          }
        }
      }
    },
  );
});
final cleanupJobsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, child) => ref.watch(cleanupRepositoryProvider).jobs(child),
    );

class SupabaseCleanupRepository implements CleanupRepository {
  SupabaseCleanupRepository(this.client, {this.clearReviewCache});
  final SupabaseClient client;
  final Future<void> Function(
    String child,
    String scope,
    List<String> ids,
    List<String> drafts,
  )?
  clearReviewCache;
  @override
  Future<Map<String, dynamic>> preview(
    String child,
    String scope,
    List<String> ids,
  ) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final result = await client
        .rpc<Map<String, dynamic>>(
          'preview_question_cleanup',
          params: {'target_child_id': child, 'operation': scope, 'ids': ids},
        )
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    return result;
  }

  @override
  Future<void> request(
    String child,
    String scope,
    List<String> ids,
    String key,
    String confirmation,
  ) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final frozenIds = List<String>.unmodifiable(ids);
    await clearReviewCache?.call(child, scope, frozenIds, const []);
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    final receipt = await client
        .rpc<String>(
          'request_question_cleanup',
          params: {
            'target_child_id': child,
            'operation': scope,
            'ids': frozenIds,
            'request_id': key,
            'confirmation': confirmation,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    if (receipt != key) throw StateError('清理回执不匹配，请查询原申请');
    await retry(key);
  }

  @override
  Future<void> retry(String jobId) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    if (clearReviewCache != null) {
      final job = await client
          .from('cleanup_jobs')
          .select('child_id,scope,question_ids,draft_ids')
          .eq('id', jobId)
          .single()
          .timeout(const Duration(seconds: 15));
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      await clearReviewCache!(
        job['child_id'] as String,
        job['scope'] as String,
        (job['question_ids'] as List).cast<String>(),
        (job['draft_ids'] as List).cast<String>(),
      );
    }
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    final response = await client.functions
        .invoke('permanent-cleanup', body: {'job_id': jobId})
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    final data = response.data as Map?;
    if (!const {200, 202}.contains(response.status) ||
        data?['job_id'] != jobId ||
        !const {'running', 'completed'}.contains(data?['status'])) {
      throw StateError('真实文件清理未完成，请在清理记录中重试相同任务');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> jobs(String child) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final result = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += 500) {
      final page = await client
          .from('cleanup_jobs')
          .select('id,scope,status,attempts,error_code,created_at,completed_at')
          .eq('child_id', child)
          .order('created_at', ascending: false)
          .order('id')
          .range(offset, offset + 499)
          .timeout(const Duration(seconds: 15));
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      result.addAll(page);
      if (page.length < 500) return result;
    }
  }
}

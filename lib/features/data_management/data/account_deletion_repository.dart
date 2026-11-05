import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class AccountDeletionRepository {
  Future<List<Map<String, dynamic>>> context();
  Future<Map<String, dynamic>> preview();
  Future<void> request(String id, Map<String, dynamic> scope);
  Future<Map<String, dynamic>?> status();
  Future<void> retry();
}

final accountDeletionRepositoryProvider = Provider<AccountDeletionRepository?>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  return client == null
      ? null
      : SupabaseAccountDeletionRepository(
          client,
          offline: tasks is OfflineTaskRepository ? tasks : null,
        );
});
final accountDeletionStatusProvider = FutureProvider<Map<String, dynamic>?>((
  ref,
) {
  ref.watch(authSessionProvider);
  return ref.watch(accountDeletionRepositoryProvider)?.status();
});

class SupabaseAccountDeletionRepository implements AccountDeletionRepository {
  SupabaseAccountDeletionRepository(this.client, {this.offline});
  final SupabaseClient client;
  final OfflineTaskRepository? offline;

  Future<T> _rpc<T>(String name, [Map<String, dynamic>? params]) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final value = await client
        .rpc<T>(name, params: params)
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    return value;
  }

  @override
  Future<List<Map<String, dynamic>>> context() async =>
      (await _rpc<List<dynamic>>(
        'account_deletion_context',
      )).cast<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> preview() => _rpc('preview_account_deletion');
  @override
  Future<void> request(String id, Map<String, dynamic> scope) async {
    final owner = client.auth.currentUser?.id;
    final result = await _rpc<String>('request_account_deletion', {
      'request_id': id,
      'expected_scope': scope,
      'confirmation': '永久注销我的账号',
    });
    if (result != id || owner == null) throw StateError('注销回执不匹配，请查询原申请');
    await offline?.forgetAccount(owner, id);
    for (final child
        in (scope['child_ids'] as List? ?? const []).cast<String>()) {
      await offline?.forgetChild(child);
    }
  }

  @override
  Future<Map<String, dynamic>?> status() async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) return null;
    final local = await offline?.store.accountDeletionJob(owner);
    Map<String, dynamic>? result;
    try {
      result = await _rpc<Map<String, dynamic>?>('account_deletion_status');
    } catch (error) {
      if (!isNetworkFailure(error)) rethrow;
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      return local == null
          ? null
          : {'id': local, 'status': 'unknown', 'offline': true};
    }
    if (result != null) {
      await offline?.forgetAccount(owner, result['id'] as String);
    }
    return result ??
        (local == null ? null : {'id': local, 'status': 'unknown'});
  }

  @override
  Future<void> retry() async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final response = await client.functions
        .invoke('account-deletion', body: {})
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    if (!const {200, 202}.contains(response.status) ||
        !const {
          'accepted',
          'completed',
        }.contains((response.data as Map?)?['status'])) {
      throw StateError('注销处理未确认，请稍后查询');
    }
  }
}

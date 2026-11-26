import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/domain/parent_authorization_clock.dart';
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
  ref.watch(authAccountIdProvider);
  final repository = ref.watch(accountDeletionRepositoryProvider);
  if (repository is! SupabaseAccountDeletionRepository) {
    return repository?.status();
  }
  final entry = ref.read(familyEntryRefreshProvider);
  final awaitingFirstFamilyRead = !ref.exists(familiesProvider);
  var active = true;
  ref.onDispose(() {
    active = false;
    entry.clearFailure();
  });
  return repository.status(
    onRefreshFailure: (session, error) {
      if (active && awaitingFirstFamilyRead && !ref.exists(familiesProvider)) {
        entry.record(session, error);
      }
    },
    onOnlineClear: (owner) {
      if (active && entry.needsFamilyRefresh(owner)) {
        ref.invalidate(familiesProvider);
      }
    },
  );
});

class SupabaseAccountDeletionRepository implements AccountDeletionRepository {
  SupabaseAccountDeletionRepository(this.client, {this.offline});
  final SupabaseClient client;
  final OfflineTaskRepository? offline;
  ({Session session, Future<Map<String, dynamic>?> result})? _entryRead;

  void prepareEntryCheck() {
    final session = client.auth.currentSession;
    if (session == null) return;
    final result = _rpc<Map<String, dynamic>?>('account_deletion_status');
    // The UI will handle errors through status(), including retryable refresh
    // failures. A session replaced before then must discard its pending result.
    result.ignore();
    _entryRead = (session: session, result: result);
  }

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
  Future<List<Map<String, dynamic>>> context() async {
    final started = ParentAuthorizationClock.device.now();
    final rows = (await _rpc<List<dynamic>>(
      'account_deletion_context',
    )).cast<Map<String, dynamic>>();
    return [
      for (final row in rows)
        {
          ...row,
          if (row['authorized'] == true && row['authorized_until'] != null)
            'authorization_deadline': ParentAuthorizationClock.deadline(
              started,
              row,
            ),
        },
    ];
  }

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
  Future<Map<String, dynamic>?> status({
    void Function(Session, AuthRetryableFetchException)? onRefreshFailure,
    void Function(String)? onOnlineClear,
  }) async {
    final session = client.auth.currentSession;
    final prepared = _entryRead;
    _entryRead = null;
    final owner = session?.user.id;
    if (owner == null) return null;
    Map<String, dynamic>? result;
    Object? networkError;
    try {
      result = await (prepared != null && identical(session, prepared.session)
          ? prepared.result
          : _rpc<Map<String, dynamic>?>('account_deletion_status'));
    } catch (error) {
      if (!isNetworkFailure(error)) rethrow;
      networkError = error;
    }
    void checkOwner() {
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    }

    checkOwner();
    if (result != null) {
      await offline?.forgetAccount(owner, result['id'] as String);
      checkOwner();
      return result;
    }
    // A deletion can be accepted locally while a prior status request is in
    // flight. Its durable receipt takes precedence over a late empty response.
    final local = await offline?.store.accountDeletionJob(owner);
    checkOwner();
    if (local != null) {
      return {
        'id': local,
        'status': 'unknown',
        if (networkError != null) 'offline': true,
      };
    }
    if (networkError == null) {
      onOnlineClear?.call(owner);
    } else if (networkError is AuthRetryableFetchException &&
        session != null &&
        session.isExpired &&
        session.refreshToken != null &&
        identical(session, client.auth.currentSession)) {
      onRefreshFailure?.call(session, networkError);
    }
    return null;
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

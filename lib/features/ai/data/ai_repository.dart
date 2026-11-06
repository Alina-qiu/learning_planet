import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/offline_store.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class AiRepository {
  Future<Map<String, dynamic>> settings(String familyId);
  Future<Map<String, dynamic>> context(String childId);
  Future<Map<String, dynamic>> updateSettings(
    String familyId,
    int version,
    Map<String, dynamic> settings,
  );
  Future<Map<String, dynamic>?> pending(String childId);
  Future<Map<String, dynamic>> prepare(
    String familyId,
    String childId,
    Map<String, dynamic> input, {
    int generation = 0,
  });
  Future<Map<String, dynamic>> resolve(
    String childId,
    String requestId,
    String operation,
  );
  Future<void> dismiss(String childId, String requestId);
}

final aiRepositoryProvider = Provider<AiRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null || tasks is! OfflineTaskRepository) {
    throw StateError('AI服务尚未配置');
  }
  return SupabaseAiRepository(client, tasks.store);
});

class SupabaseAiRepository implements AiRepository {
  SupabaseAiRepository(this.client, this.store);
  final SupabaseClient client;
  final OfflineStore store;
  Future<void> _queue = Future.value();
  String _owner() => client.auth.currentUser?.id ?? (throw StateError('请先登录'));
  Future<void> _check(String owner, [String? child]) async {
    if (_owner() != owner) throw StateError('登录账号已变化');
    if (await store.accountDeletionJob(owner) != null ||
        (child != null && await store.isChildDeleted(child))) {
      throw StateError('资料已申请删除');
    }
    if (_owner() != owner) throw StateError('登录账号已变化');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Map<String, dynamic>> _rpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    final owner = _owner();
    await _check(owner);
    final result = await client
        .rpc<Map<String, dynamic>>(name, params: params)
        .timeout(const Duration(seconds: 15));
    await _check(owner);
    return result;
  }

  @override
  Future<Map<String, dynamic>> settings(String familyId) =>
      _rpc('read_ai_settings', {'target_family_id': familyId});
  @override
  Future<Map<String, dynamic>> context(String childId) =>
      _rpc('read_ai_context', {'target_child_id': childId});
  @override
  Future<Map<String, dynamic>> updateSettings(
    String familyId,
    int version,
    Map<String, dynamic> settings,
  ) => _rpc('update_ai_settings', {
    'target_family_id': familyId,
    'expected_version': version,
    'settings': settings,
  });
  @override
  Future<Map<String, dynamic>?> pending(String childId) async {
    final owner = _owner();
    await _check(owner, childId);
    final draft = await store.read(owner, 'ai-request:$childId');
    await _check(owner, childId);
    return draft;
  }

  @override
  Future<Map<String, dynamic>> prepare(
    String familyId,
    String childId,
    Map<String, dynamic> input, {
    int generation = 0,
  }) {
    final owner = _owner();
    final copy = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
    return _serial(
      () => store.transaction(() async {
        await _check(owner, childId);
        final existing = await store.read(owner, 'ai-request:$childId');
        if (existing != null) return existing;
        final draft = {
          'request_id': const Uuid().v4(),
          'child_id': childId,
          'family_id': familyId,
          'generation': generation,
          'input': copy,
        };
        await store.write(owner, 'ai-request:$childId', draft);
        return draft;
      }),
    );
  }

  @override
  Future<Map<String, dynamic>> resolve(
    String childId,
    String requestId,
    String operation,
  ) => _serial(() async {
    if (!['inspect', 'submit', 'cancel'].contains(operation)) {
      throw ArgumentError('operation');
    }
    final owner = _owner();
    await _check(owner, childId);
    final key = 'ai-request:$childId';
    final saved = await store.read(owner, key);
    if (saved == null || saved['request_id'] != requestId) {
      throw StateError('请求已清理');
    }
    await _check(owner, childId);
    Map<String, dynamic> receipt;
    if (operation == 'submit') {
      final response = await client.functions
          .invoke(
            'ai-analysis',
            body: {
              'child_id': childId,
              'request_id': requestId,
              'input': saved['input'],
              'consent': true,
              'generation': saved['generation'],
            },
          )
          .timeout(const Duration(seconds: 15));
      receipt = Map<String, dynamic>.from(response.data as Map);
    } else {
      receipt = await _rpc('resolve_ai_analysis', {
        'target_child_id': childId,
        'request_id': requestId,
        'input': saved['input'],
        'operation': operation,
        'expected_generation': saved['generation'],
      });
    }
    await _check(owner, childId);
    if ((await store.read(owner, key))?['request_id'] != requestId) {
      throw StateError('请求已清理');
    }
    if (receipt['request_id'] != requestId ||
        receipt['child_id'] != childId ||
        ![
          'unknown',
          'running',
          'completed',
          'failed',
          'cancelled',
          'discarded',
          'expired',
        ].contains(receipt['status'])) {
      throw StateError('AI回执不匹配，请核对原请求');
    }
    return receipt;
  });
  @override
  Future<void> dismiss(String childId, String requestId) => _serial(() async {
    final owner = _owner();
    await _check(owner, childId);
    final key = 'ai-request:$childId';
    final saved = await store.read(owner, key);
    if (saved == null || saved['request_id'] != requestId) return;
    // Fences a delayed initial dispatch and removes retained output. Never refunds an unknown charge.
    final receipt = await _rpc('resolve_ai_analysis', {
      'target_child_id': childId,
      'request_id': requestId,
      'input': saved['input'],
      'operation': 'cancel',
      'expected_generation': saved['generation'],
    });
    if (receipt['request_id'] != requestId ||
        receipt['child_id'] != childId ||
        ![
          'failed',
          'cancelled',
          'discarded',
          'expired',
        ].contains(receipt['status'])) {
      throw StateError('尚未确认结束，请核对原请求');
    }
    await _check(owner, childId);
    await store.remove(owner, key);
  });
}

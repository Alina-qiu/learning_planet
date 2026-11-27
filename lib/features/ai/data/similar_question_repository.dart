import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class SimilarQuestionRepository {
  Future<Map<String, dynamic>> context(String childId, String sourceId);
  Future<List<Map<String, dynamic>>> search(
    String childId,
    String sourceId,
    String query,
  );
  Future<Map<String, dynamic>> question(String childId, String id);
  Future<Map<String, dynamic>> check(
    String childId,
    Map<String, dynamic> config,
  );
  Future<Map<String, dynamic>> prepareApproval(
    String childId,
    String requestId,
    Map<String, dynamic> config,
  );
  Future<Map<String, dynamic>> save(String childId, String requestId);
  Future<Map<String, dynamic>> inspect(String childId, String requestId);
  Future<void> feedback(String childId, String requestId, String reason);
}

final similarQuestionRepositoryProvider = Provider<SimilarQuestionRepository>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (tasks is! OfflineTaskRepository || client == null) {
    throw StateError('请先配置并登录服务');
  }
  return SupabaseSimilarQuestionRepository(client, tasks.store);
});

class SupabaseSimilarQuestionRepository implements SimilarQuestionRepository {
  SupabaseSimilarQuestionRepository(this.client, this.store);
  final SupabaseClient client;
  final OfflineStore store;
  Future<void> _tail = Future.value();
  String _owner() => client.auth.currentUser?.id ?? (throw StateError('请先登录'));
  Future<void> _guard(String owner, String child, int generation) async {
    if (_owner() != owner ||
        store.reviewGeneration(owner) != generation ||
        await store.accountDeletionJob(owner) != null ||
        await store.isChildDeleted(child)) {
      throw StateError('资料或登录状态已变化');
    }
    if (_owner() != owner) throw StateError('登录状态已变化');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Map<String, dynamic>> _rpc(
    String child,
    String name,
    Map<String, dynamic> params,
  ) async {
    final owner = _owner(), generation = store.reviewGeneration(_owner());
    await _guard(owner, child, generation);
    final result = await client
        .rpc<Map<String, dynamic>>(name, params: params)
        .timeout(const Duration(seconds: 15));
    await _guard(owner, child, generation);
    return result;
  }

  @override
  Future<Map<String, dynamic>> context(String childId, String sourceId) async {
    final result = await _rpc(childId, 'similar_question_context', {
      'source_id': sourceId,
    });
    if (result['child_id'] != childId) throw StateError('原题不属于当前孩子');
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> search(
    String childId,
    String sourceId,
    String query,
  ) async {
    // Check source scope before presenting a list from a different route.
    await context(childId, sourceId);
    final result = await _rpc(childId, 'find_similar_questions', {
      'source_id': sourceId,
      'query': query,
    });
    return (result['items'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  @override
  Future<Map<String, dynamic>> question(String childId, String id) async {
    final result = await _rpc(childId, 'review_question_editor', {
      'target_question_id': id,
    });
    if (result['child_id'] != childId) throw StateError('题目不属于当前孩子');
    return result;
  }

  @override
  Future<Map<String, dynamic>> check(
    String childId,
    Map<String, dynamic> config,
  ) => _rpc(childId, 'preview_practice_answer', {
    'target_child_id': childId,
    'config': config,
  });
  @override
  Future<Map<String, dynamic>> prepareApproval(
    String childId,
    String requestId,
    Map<String, dynamic> config,
  ) {
    final owner = _owner(), generation = store.reviewGeneration(_owner());
    final frozen = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    return _serial(
      () => store.transaction(() async {
        await _guard(owner, childId, generation);
        final draft = await store.read(owner, 'ai-request:$childId');
        if (draft == null ||
            draft['request_id'] != requestId ||
            (draft['input'] as Map)['kind'] != 'similar') {
          throw StateError('生成请求已结束');
        }
        if (draft['approval'] != null) return draft;
        final result = {...draft, 'approval': frozen};
        await store.write(owner, 'ai-request:$childId', result);
        await _guard(owner, childId, generation);
        return result;
      }),
    );
  }

  @override
  Future<Map<String, dynamic>> save(String childId, String requestId) =>
      _serial(() async {
        final owner = _owner(), generation = store.reviewGeneration(_owner());
        await _guard(owner, childId, generation);
        final draft = await store.read(owner, 'ai-request:$childId');
        if (draft == null ||
            draft['request_id'] != requestId ||
            draft['approval'] is! Map) {
          throw StateError('请先确认并保存审核内容');
        }
        final result = await _rpc(childId, 'adopt_similar_question', {
          'target_child_id': childId,
          'request_id': requestId,
          'config': draft['approval'],
        });
        await _guard(owner, childId, generation);
        if (!await storeHasRequest(owner, childId, requestId)) {
          throw StateError('本机请求已清理');
        }
        return _receipt(requestId, result);
      });
  Future<bool> storeHasRequest(
    String owner,
    String child,
    String request,
  ) async =>
      (await store.read(owner, 'ai-request:$child'))?['request_id'] == request;
  Map<String, dynamic> _receipt(String id, Map<String, dynamic> result) {
    if (result['request_id'] != id ||
        !['unknown', 'saved', 'deleted'].contains(result['status']) ||
        (result['status'] == 'saved' && result['question_id'] is! String)) {
      throw StateError('保存回执无法确认');
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> inspect(
    String childId,
    String requestId,
  ) async => _receipt(
    requestId,
    await _rpc(childId, 'inspect_similar_adoption', {
      'target_child_id': childId,
      'request_id': requestId,
    }),
  );
  @override
  Future<void> feedback(String childId, String requestId, String reason) async {
    final owner = _owner(), generation = store.reviewGeneration(_owner());
    await _guard(owner, childId, generation);
    await client
        .rpc<void>(
          'feedback_ai_result',
          params: {
            'target_child_id': childId,
            'request_id': requestId,
            'reason': reason,
          },
        )
        .timeout(const Duration(seconds: 15));
    await _guard(owner, childId, generation);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/network_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../tasks/domain/task_start_origin.dart';
import '../domain/review_confidence.dart';

abstract interface class ReviewRepository {
  Future<List<Map<String, dynamic>>> questions(String childId);
  Future<Map<String, dynamic>> overview(String childId);
  Future<Map<String, dynamic>> editor(String questionId);
  Future<void> save(
    String childId,
    Map<String, dynamic> config, {
    String? questionId,
    String? requestId,
  });
  Future<void> archive(String questionId, bool archived);
  Future<Map<String, dynamic>> task(String taskId);
  Future<void> transition(String taskId, String operation);
  Future<Map<String, dynamic>> answer(
    String taskId,
    String questionId,
    String answer,
    String commandId, {
    ReviewConfidence? confidence,
    int? questionVersion,
  });
  Future<void> complete(String taskId, String key);
}

final reviewRepositoryProvider = Provider<ReviewRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) throw StateError('开发环境尚未配置 Supabase。');
  final live = SupabaseReviewRepository(client);
  return tasks is OfflineTaskRepository
      ? CachedReviewRepository(live, tasks.store, tasks.accountId, tasks: tasks)
      : live;
});
final reviewQuestionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, childId) {
      ref.watch(taskSyncStateProvider);
      return ref.watch(reviewRepositoryProvider).questions(childId);
    });
final reviewOverviewProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, childId) {
      ref.watch(taskSyncStateProvider);
      return ref.watch(reviewRepositoryProvider).overview(childId);
    });
final reviewTaskProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, taskId) {
      // A sync tick refreshes the same task. Keep its existing form mounted
      // while fetching, so periodic sync cannot dismiss the answer keyboard.
      // Repository/account changes remain dependencies and reload normally.
      ref.listen(taskSyncStateProvider, (_, _) => ref.invalidateSelf());
      return ref.watch(reviewRepositoryProvider).task(taskId);
    });

Future<void> startReviewWithOrigin(
  ReviewRepository repository,
  String taskId,
  TaskStartOrigin origin,
) => repository is AttributedTaskStarter
    ? (repository as AttributedTaskStarter).startWithOrigin(taskId, origin)
    : repository.transition(taskId, 'start');

class SupabaseReviewRepository
    implements ReviewRepository, AttributedTaskStarter {
  SupabaseReviewRepository(this.client);
  final SupabaseClient client;
  @override
  Future<void> startWithOrigin(String taskId, TaskStartOrigin origin) =>
      client.rpc<void>(
        'start_task_with_origin',
        params: {'target_task_id': taskId, 'requested_origin': origin.wire},
      );
  @override
  Future<List<Map<String, dynamic>>> questions(String childId) async {
    final owner = client.auth.currentUser?.id;
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += 500) {
      final page = await client
          .from('wrong_questions')
          .select()
          .eq('child_id', childId)
          .eq('deleting', false)
          .order('archived')
          .order('review_due_at')
          .order('id')
          .range(offset, offset + 499)
          .timeout(const Duration(seconds: 10));
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      rows.addAll(page);
      if (page.length < 500) return rows;
    }
  }

  @override
  Future<Map<String, dynamic>> overview(String childId) => client
      .rpc<Map<String, dynamic>>(
        'review_overview',
        params: {'target_child_id': childId},
      )
      .timeout(const Duration(seconds: 10));
  @override
  Future<Map<String, dynamic>> editor(String questionId) =>
      client.rpc<Map<String, dynamic>>(
        'review_question_editor',
        params: {'target_question_id': questionId},
      );
  @override
  Future<void> save(
    String childId,
    Map<String, dynamic> config, {
    String? questionId,
    String? requestId,
  }) => client
      .rpc<void>(
        requestId == null
            ? 'save_review_question'
            : 'save_manual_review_question',
        params: {
          'target_child_id': childId,
          'config': config,
          'target_question_id': questionId,
          if (requestId != null) 'request_id': requestId,
        },
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<void> archive(String questionId, bool archived) => client.rpc<void>(
    'archive_review_question',
    params: {'target_question_id': questionId, 'enabled': archived},
  );
  @override
  Future<Map<String, dynamic>> task(String taskId) => client
      .rpc<Map<String, dynamic>>(
        'load_review_task',
        params: {'target_task_id': taskId},
      )
      .timeout(const Duration(seconds: 10));
  @override
  Future<void> transition(String taskId, String operation) {
    if (!const {'start', 'pause', 'resume'}.contains(operation)) {
      throw ArgumentError.value(operation);
    }
    return client.rpc<void>(
      '${operation}_task',
      params: {'target_task_id': taskId},
    );
  }

  @override
  Future<Map<String, dynamic>> answer(
    String taskId,
    String questionId,
    String answer,
    String commandId, {
    ReviewConfidence? confidence,
    int? questionVersion,
  }) async {
    if (questionVersion != null) {
      final owner = client.auth.currentUser?.id;
      final snapshot = await task(taskId);
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      // The server freezes the items at first start. A stale screen can only
      // submit against an item in that frozen version, including on retry.
      final status = (snapshot['task'] as Map)['status'];
      final matches = (snapshot['items'] as List).cast<Map>().any(
        (item) =>
            item['wrong_question_id'] == questionId &&
            item['question_version'] == questionVersion,
      );
      if (!const {'in_progress', 'paused', 'completed'}.contains(status) ||
          !matches) {
        throw StateError('题目已更新，请查看新题后作答');
      }
    }
    return client.rpc<Map<String, dynamic>>(
      'submit_review_answer',
      params: {
        'target_task_id': taskId,
        'target_question_id': questionId,
        'answer': answer,
        'command_id': commandId,
        if (confidence != null) 'answer_confidence': confidence.wire,
      },
    );
  }

  @override
  Future<void> complete(String taskId, String key) => client.rpc<void>(
    'complete_task',
    params: {'target_task_id': taskId, 'completion_key': key},
  );
}

/// Only server snapshots are cached. Pending answers are projected from the outbox.
class CachedReviewRepository
    implements ReviewRepository, AttributedTaskStarter {
  CachedReviewRepository(this.live, this.store, this.accountId, {this.tasks});
  final ReviewRepository live;
  final OfflineTaskRepository? tasks;
  final OfflineStore store;
  final String? Function() accountId;
  Future<Map<String, dynamic>> _read(
    String key,
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    final owner = accountId();
    if (owner == null) throw StateError('请先登录');
    final generation = store.reviewGeneration(owner);
    void check() {
      if (accountId() != owner) throw StateError('登录账号已变化');
      if (store.reviewGeneration(owner) != generation) {
        throw StateError('错题缓存已清理，请重新加载');
      }
    }

    try {
      final data = await fetch();
      check();
      if (key.startsWith('review-task:')) {
        final snapshot = await store.transaction(() async {
          // An older read can return after the first offline start. Keep the
          // questions that the pending answers and their versions belong to.
          if (tasks != null) {
            final taskId = key.substring('review-task:'.length);
            final rows = await store.commands(
              owner,
              childId: (data['task'] as Map)['child_id'] as String?,
            );
            if (rows.any((row) => row['task_id'] == taskId)) {
              final original = await store.read(owner, key);
              if (original != null) return original;
            }
          }
          await store.writeReviewCache(owner, key, data, generation);
          return (await store.read(owner, key)) ?? data;
        });
        check();
        return snapshot;
      }
      await store.writeReviewCache(owner, key, data, generation);
      check();
      return data;
    } catch (error) {
      check();
      if (!isNetworkFailure(error)) {
        await store.remove(owner, key);
        rethrow;
      }
      final cached = await store.read(owner, key);
      check();
      if (cached == null) rethrow;
      return {...cached, 'offline_cache': true};
    }
  }

  @override
  Future<List<Map<String, dynamic>>> questions(String childId) async =>
      ((await _read(
                'review-questions:$childId',
                () async => {'items': await live.questions(childId)},
              ))['items']
              as List)
          .cast<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> overview(String childId) =>
      _read('review-overview:$childId', () => live.overview(childId));
  @override
  Future<Map<String, dynamic>> task(String taskId) async {
    final owner = accountId();
    if (owner == null) throw StateError('请先登录');
    final generation = store.reviewGeneration(owner);
    Future<Map<String, dynamic>> project(Map<String, dynamic> data) async {
      if (accountId() != owner || store.reviewGeneration(owner) != generation) {
        throw StateError('登录或复习缓存已变化');
      }
      final result = tasks == null ? data : await tasks!.projectReview(data);
      if (accountId() != owner || store.reviewGeneration(owner) != generation) {
        throw StateError('登录或复习缓存已变化');
      }
      return result;
    }

    if (tasks != null) {
      final cached = await store.read(owner, 'review-task:$taskId');
      final pending = (await store.commands(
        owner,
      )).any((row) => row['task_id'] == taskId && row['state'] == 'pending');
      if (cached != null && pending) return project(cached);
    }
    final data = await _read('review-task:$taskId', () => live.task(taskId));
    return project(data);
  }

  // Do not persist private live answer keys or defer PIN-protected writes.
  @override
  Future<Map<String, dynamic>> editor(String questionId) =>
      live.editor(questionId);
  @override
  Future<void> save(
    String childId,
    Map<String, dynamic> config, {
    String? questionId,
    String? requestId,
  }) =>
      live.save(childId, config, questionId: questionId, requestId: requestId);
  @override
  Future<void> archive(String questionId, bool archived) =>
      live.archive(questionId, archived);
  @override
  Future<void> transition(String taskId, String operation) => tasks == null
      ? live.transition(taskId, operation)
      : operation == 'start'
      ? _start(taskId)
      : tasks!.queueReview(taskId, operation);
  @override
  Future<void> startWithOrigin(String taskId, TaskStartOrigin origin) =>
      tasks == null
      ? startReviewWithOrigin(live, taskId, origin)
      : _start(taskId, origin: origin);

  Future<void> _start(String taskId, {TaskStartOrigin? origin}) async {
    final owner = accountId();
    if (owner == null) throw StateError('请先登录');
    final generation = store.reviewGeneration(owner);
    void checkScope() {
      if (accountId() != owner || store.reviewGeneration(owner) != generation) {
        throw StateError('登录或复习缓存已变化');
      }
    }

    var current = await task(taskId);
    final childId = (current['task'] as Map)['child_id'] as String;
    Future<void> enqueue() {
      checkScope();
      if ((current['task'] as Map)['review_waiting_for_due'] == true ||
          (current['items'] as List).isEmpty) {
        throw StateError('今天暂时没有到期的复习题');
      }
      return tasks!.queueReview(taskId, 'start', startOrigin: origin);
    }

    try {
      await enqueue();
    } on TaskSnapshotMissing {
      checkScope();
      if (current['offline_cache'] == true || current['local_pending'] == true) {
        rethrow;
      }
      // The hub can see a newly restored review before the home list does.
      // Get a fresh authorized list and recheck the questions before queuing.
      await tasks!.synchronize(childId, freshSnapshot: true);
      checkScope();
      current = await task(taskId);
      await enqueue();
    }
    if (current['offline_cache'] != true) {
      checkScope();
      await tasks!.synchronize(childId);
    }
  }

  @override
  Future<Map<String, dynamic>> answer(
    String taskId,
    String questionId,
    String answer,
    String commandId, {
    ReviewConfidence? confidence,
    int? questionVersion,
  }) async {
    if (tasks == null) {
      return live.answer(
        taskId,
        questionId,
        answer,
        commandId,
        confidence: confidence,
        questionVersion: questionVersion,
      );
    }
    await tasks!.queueReview(
      taskId,
      'answer',
      questionId: questionId,
      questionVersion: questionVersion,
      answer: answer,
      commandId: commandId,
      confidence: confidence,
    );
    return task(taskId);
  }

  @override
  Future<void> complete(String taskId, String key) => tasks == null
      ? live.complete(taskId, key)
      : tasks!.queueReview(taskId, 'complete');
}

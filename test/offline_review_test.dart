import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote, clone;

class ReviewRemote extends FakeTaskRemote implements ReviewTaskSyncRemote {
  ReviewRemote(super.now) {
    seed('child');
    tasks['task-child']!['source_type'] = 'automatic_wrong_review';
  }
  final item = <String, dynamic>{
    'wrong_question_id': 'question',
    'question_version': 0,
    'sequence': 1,
    'prompt': '2+2',
    'result': null,
    'review_kind': 'question',
  };
  bool conflictNext = false;
  Completer<void>? applyEntered, applyBarrier;
  Completer<void>? snapshotEntered;
  @override
  Future<Map<String, dynamic>> snapshot(String childId) {
    if (snapshotEntered != null && !snapshotEntered!.isCompleted) {
      snapshotEntered!.complete();
    }
    return super.snapshot(childId);
  }

  Map<String, dynamic> review() => clone({
    'task': tasks['task-child'],
    'items': [item],
  });
  @override
  Future<Map<String, dynamic>> reviewSnapshot(String taskId) async {
    check();
    return review();
  }

  @override
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command) async {
    check();
    requests.add(clone(command));
    if (applyEntered != null && !applyEntered!.isCompleted) {
      applyEntered!.complete();
    }
    await applyBarrier?.future;
    final task = tasks['task-child']!, wallet = wallets['child']!;
    Map<String, dynamic> response(String outcome) => clone({
      'outcome': outcome,
      'reason': '另一台设备已修改复习',
      'task': task,
      'wallet': wallet,
      'server_at': now().toIso8601String(),
      'review': review(),
    });
    if (conflictNext) return response('conflict');
    if (!receipts.containsKey(command['command_id'])) {
      switch (command['kind']) {
        case 'review_start' || 'review_resume':
          task['status'] = 'in_progress';
        case 'review_pause':
          task['status'] = 'paused';
        case 'review_answer':
          item.addAll({
            'result': true,
            'answer_text': command['answer'],
            'accepted_answers': ['4'],
          });
        case 'review_complete':
          task['status'] = 'completed';
          wallet['coin_balance'] += 5;
          wallet['xp'] += 5;
        default:
          throw StateError('Unexpected test request');
      }
      task['sync_version'] = (task['sync_version'] as int) + 1;
      receipts[command['command_id'] as String] = clone(command);
    }
    if (failAfterCommit) {
      failAfterCommit = false;
      throw const SocketException('Reply lost');
    }
    return response('applied');
  }
}

class LiveReview implements ReviewRepository {
  LiveReview(this.remote);
  final ReviewRemote remote;
  @override
  Future<Map<String, dynamic>> task(String taskId) =>
      remote.reviewSnapshot(taskId);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late OfflineStore store;
  late OfflineTaskRepository tasks;
  late CachedReviewRepository reviews;
  late ReviewRemote remote;
  late DateTime now;
  String? owner;
  void repositories() {
    tasks = OfflineTaskRepository(
      store: store,
      remote: remote,
      live: const UnconfiguredTaskRepository(),
      accountId: () => owner,
      clock: () => now,
      autoSync: false,
    )..setForeground(false);
    reviews = CachedReviewRepository(
      LiveReview(remote),
      store,
      () => owner,
      tasks: tasks,
    );
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 4, 8);
    owner = 'parent';
    store = OfflineStore(NativeDatabase.memory());
    remote = ReviewRemote(() => now);
    repositories();
    await tasks.loadTasks('child');
    await reviews.task('task-child');
    remote.online = false;
  });
  tearDown(() async {
    await tasks.dispose();
    await store.close();
  });
  Future<void> queueAnswer() async {
    await reviews.transition('task-child', 'start');
    await reviews.answer('task-child', 'question', '4', 'answer-command');
  }

  test(
    'offline review saves answers immediately without grading or changing the wallet',
    () async {
      await queueAnswer();
      final data = await reviews.task('task-child'),
          item = (data['items'] as List).single as Map;
      expect(item['result'], isNull);
      expect(item['pending_answer'], '4');
      expect(item['accepted_answers'], isNull);
      expect((await tasks.loadWallet('child')).coins, 100);
      expect((await store.commands('parent')).length, 2);
      expect(
        (await store.read(
          'parent',
          'review-task:task-child',
        ))!['items'][0]['pending_answer'],
        isNull,
      );
      await reviews.answer('task-child', 'question', '4', 'duplicate-command');
      expect((await store.commands('parent')).length, 2);
      await expectLater(
        reviews.answer('task-child', 'question', '5', 'changed-command'),
        throwsStateError,
      );
      await reviews.complete('task-child', 'completion');
      await reviews.complete('task-child', 'duplicate');
      expect((await reviews.task('task-child'))['local_completion'], true);
      expect((await tasks.loadWallet('child')).coins, 100);
    },
  );
  test(
    'review cannot finish unanswered, pause then answer, or use an expired lease',
    () async {
      await reviews.transition('task-child', 'start');
      await expectLater(
        reviews.complete('task-child', 'finish'),
        throwsStateError,
      );
      await reviews.transition('task-child', 'pause');
      await expectLater(
        reviews.answer('task-child', 'question', '4', 'answer'),
        throwsStateError,
      );
      await reviews.transition('task-child', 'resume');
      now = now.add(const Duration(days: 8));
      await expectLater(
        reviews.answer('task-child', 'question', '4', 'answer'),
        throwsStateError,
      );
      expect((await store.commands('parent')).length, 3);
    },
  );
  test(
    'review answer UUID and completion survive a real SQLite restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('planet-review-');
      final file = File('${dir.path}/review.sqlite');
      await tasks.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      repositories();
      remote.online = true;
      await tasks.loadTasks('child');
      await reviews.task('task-child');
      remote.online = false;
      await queueAnswer();
      await reviews.complete('task-child', 'finish');
      final before = await store.commands('parent');
      await tasks.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      repositories();
      expect(
        (await store.commands('parent')).map((r) => r['command_id']),
        before.map((r) => r['command_id']),
      );
      expect((await reviews.task('task-child'))['local_completion'], true);
      remote.online = true;
      await tasks.synchronize('child');
      expect(await store.commands('parent'), isEmpty);
      expect((await tasks.loadWallet('child')).coins, 105);
      await tasks.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase.memory());
      repositories();
      await dir.delete(recursive: true);
    },
  );
  test(
    'lost reply retries original UUID and commits server answer with queue acknowledgement',
    () async {
      await queueAnswer();
      await reviews.complete('task-child', 'finish');
      remote.online = true;
      remote.failAfterCommit = true;
      await tasks.synchronize('child');
      expect((await store.commands('parent')).length, 3);
      await tasks.synchronize('child');
      expect(await store.commands('parent'), isEmpty);
      expect(
        remote.requests[0]['command_id'],
        remote.requests[1]['command_id'],
      );
      final data = await reviews.task('task-child');
      expect(data['local_completion'], false);
      expect(data['items'][0]['result'], true);
      expect(data['items'][0]['pending_answer'], isNull);
      expect((await tasks.loadWallet('child')).coins, 105);
      await tasks.synchronize('child');
      expect((await tasks.loadWallet('child')).coins, 105);
    },
  );
  test(
    'conflict keeps local answer until successful server adoption, including offline failures',
    () async {
      await queueAnswer();
      remote.online = true;
      remote.conflictNext = true;
      await tasks.synchronize('child');
      expect(
        (await store.commands('parent')).every((r) => r['state'] == 'conflict'),
        true,
      );
      expect((await reviews.task('task-child'))['sync_conflict'], true);
      await expectLater(
        reviews.transition('task-child', 'start'),
        throwsStateError,
      );
      remote.online = false;
      await expectLater(
        tasks.acceptServer('child', 'task-child'),
        throwsA(isA<SocketException>()),
      );
      expect((await store.commands('parent')).length, 2);
      remote.online = true;
      await tasks.acceptServer('child', 'task-child');
      expect(await store.commands('parent'), isEmpty);
      expect((await reviews.task('task-child'))['sync_conflict'], false);
    },
  );
  test(
    'privacy cleanup removes answers and blocks an in-flight reply from resurrecting them',
    () async {
      await queueAnswer();
      await store.enqueue('other', 'child', {
        'command_id': 'other',
        'task_id': 'other',
        'kind': 'review_answer',
      });
      await store.enqueue('parent', 'sibling', {
        'command_id': 'ordinary',
        'task_id': 'ordinary',
        'kind': 'start',
      });
      remote.online = true;
      remote.applyEntered = Completer();
      remote.applyBarrier = Completer();
      final syncing = tasks.synchronize('child');
      await remote.applyEntered!.future;
      await store.removeReviewCache('parent');
      remote.applyBarrier!.complete();
      // The ordinary fixture is deliberately unsynchronized and has no snapshot.
      await syncing;
      expect(await store.read('parent', 'review-task:task-child'), isNull);
      expect((await store.commands('parent')).map((r) => r['command_id']), [
        'ordinary',
      ]);
      expect((await store.commands('other')).single['command_id'], 'other');
      expect(
        remote.requests.where((r) => r['kind'] == 'review_answer'),
        isEmpty,
      );
    },
  );
  test(
    'server adoption cannot silently discard commands queued while fetching',
    () async {
      await queueAnswer();
      remote.online = true;
      remote.snapshotEntered = Completer();
      remote.snapshotBarrier = Completer();
      final adoption = tasks.acceptServer('child', 'task-child');
      final rejected = expectLater(adoption, throwsStateError);
      await remote.snapshotEntered!.future;
      await reviews.complete('task-child', 'finish');
      remote.snapshotBarrier!.complete();
      await rejected;
      expect((await store.commands('parent')).length, 3);
    },
  );
  test(
    'account switch and child deletion cannot access or replay cached review answers',
    () async {
      await queueAnswer();
      owner = 'other';
      tasks.scopeChanged();
      await expectLater(
        reviews.task('task-child'),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        reviews.answer('task-child', 'question', '4', 'new'),
        throwsStateError,
      );
      expect((await store.commands('parent')).length, 2);
      owner = 'parent';
      tasks.scopeChanged();
      await tasks.forgetChild('child');
      expect(await store.commands('parent'), isEmpty);
      expect(await store.read('parent', 'review-task:task-child'), isNull);
    },
  );
  test(
    'late older review snapshot cannot roll back a confirmed answer',
    () async {
      final older = remote.review();
      await queueAnswer();
      remote.online = true;
      await tasks.synchronize('child');
      await store.writeReviewCache(
        'parent',
        'review-task:task-child',
        older,
        store.reviewGeneration('parent'),
      );
      expect(
        (await store.read(
          'parent',
          'review-task:task-child',
        ))!['items'][0]['result'],
        true,
      );
    },
  );
  testWidgets(
    'pending review completion shows saved answer and no confirmed reward at narrow width',
    (tester) async {
      await tester.runAsync(() async {
        await queueAnswer();
        await reviews.complete('task-child', 'finish');
      });
      final data = await tester.runAsync(() => reviews.task('task-child'));
      final localTasks = await tester.runAsync(() => tasks.loadTasks('child'));
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(tasks),
            reviewRepositoryProvider.overrideWithValue(reviews),
            reviewTaskProvider.overrideWith((ref, taskId) async => data!),
            tasksProvider.overrideWith((ref, childId) async => localTasks!),
            taskSyncStateProvider.overrideWith(
              (ref) => Stream.value(tasks.state),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const ReviewSessionScreen(
              taskId: 'task-child',
              childId: 'child',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('完成操作已保存在本机，等待服务端判题与结算。'), findsOneWidget);
      expect(find.text('你的答案：4'), findsOneWidget);
      expect(find.text('复习已完成，奖励已由服务端确认'), findsNothing);
      expect(find.text('回答正确 ✓'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/growth/presentation/task_feedback.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_confidence.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'offline_review_test.dart' show ReviewRemote, LiveReview;
import 'offline_tasks_test.dart' show clone;
import 'review_rewards_test.dart' show MilestoneReview;
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

class AutoReviewRemote extends ReviewRemote {
  AutoReviewRemote(super.now) {
    tasks['task-child']!.addAll({
      'review_auto_complete': true,
      'review_reward_policy': 2,
    });
  }
  bool loseFinalReply = false;
  int awards = 0;
  final extraItems = <Map<String, dynamic>>[];
  @override
  Map<String, dynamic> review() => clone({
    'task': tasks['task-child'],
    'items': [item, ...extraItems],
  });
  @override
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command) async {
    check();
    requests.add(clone(command));
    final task = tasks['task-child']!, wallet = wallets['child']!;
    final seen = receipts.containsKey(command['command_id']);
    var outcome = 'applied';
    if (!seen) {
      if (command['kind'] == 'review_start') {
        task['status'] = 'in_progress';
      } else if (command['kind'] == 'review_complete' &&
          task['status'] == 'completed') {
        outcome = 'already_completed';
      } else if (command['kind'] == 'review_answer') {
        final answered = [
          item,
          ...extraItems,
        ].singleWhere((q) => q['wrong_question_id'] == command['question_id']);
        answered.addAll({
          'result': true,
          'answer_text': command['answer'],
          'answer_confidence': command['answer_confidence'],
          'accepted_answers': ['4'],
        });
        if ([item, ...extraItems].every((q) => q['result'] != null)) {
          task.addAll({
            'status': 'completed',
            'coin_reward': 15,
            'xp_reward': 15,
          });
          wallet['coin_balance'] += 15;
          wallet['xp'] += 15;
          awards++;
        }
      } else {
        throw StateError('Unexpected automatic-review command');
      }
      task['sync_version'] = (task['sync_version'] as int) + 1;
      receipts[command['command_id'] as String] = clone(command);
      if (loseFinalReply &&
          command['kind'] == 'review_answer' &&
          task['status'] == 'completed') {
        loseFinalReply = false;
        throw const SocketException('Reply lost after atomic completion');
      }
    }
    return clone({
      'outcome': outcome,
      'task': task,
      'wallet': wallet,
      'server_at': now().toIso8601String(),
      'review': review(),
    });
  }
}

class FailingAutoStore extends OfflineStore {
  FailingAutoStore() : super(NativeDatabase.memory());
  bool failCompletion = false;
  @override
  Future<void> enqueue(
    String owner,
    String child,
    Map<String, dynamic> command,
  ) async {
    if (failCompletion && command['kind'] == 'review_complete') {
      throw StateError('Disk write failed');
    }
    await super.enqueue(owner, child, command);
  }
}

class OnlineAutoReview extends MilestoneReview {
  @override
  Future<Map<String, dynamic>> task(String id) async {
    final value = await super.task(id);
    (value['task'] as Map)['review_auto_complete'] = true;
    return value;
  }

  @override
  Future<Map<String, dynamic>> answer(
    String id,
    String question,
    String value,
    String command, {
    ReviewConfidence? confidence,
  }) async {
    check();
    submitted = value;
    submittedConfidence = confidence;
    result = true;
    status = 'completed';
    return task(id);
  }
}

void main() {
  late OfflineStore store;
  late OfflineTaskRepository tasks;
  late CachedReviewRepository reviews;
  late AutoReviewRemote remote;
  late DateTime now;
  void repositories() {
    tasks = OfflineTaskRepository(
      store: store,
      remote: remote,
      live: const UnconfiguredTaskRepository(),
      accountId: () => 'parent',
      clock: () => now,
      autoSync: false,
    )..setForeground(false);
    reviews = CachedReviewRepository(
      LiveReview(remote),
      store,
      () => 'parent',
      tasks: tasks,
    );
  }

  Future<void> cache() async {
    remote.online = true;
    await tasks.loadTasks('child');
    await reviews.task('task-child');
    remote.online = false;
  }

  setUp(() async {
    now = DateTime.utc(2026, 9, 16, 3);
    store = FailingAutoStore();
    remote = AutoReviewRemote(() => now);
    repositories();
    await cache();
  });
  tearDown(() async {
    await tasks.dispose();
    await store.close();
  });
  Future<Map<String, dynamic>> finalAnswer() async {
    await reviews.transition('task-child', 'start');
    return reviews.answer('task-child', 'question', '4', 'last-answer');
  }

  test(
    'last answer atomically queues completion and projects finished without local grading or coins',
    () async {
      final result = await finalAnswer(), rows = await store.commands('parent');
      expect(rows.map((r) => (r['command'] as Map)['kind']), [
        'review_start',
        'review_answer',
        'review_complete',
      ]);
      expect((rows.last['command'] as Map)['predecessor_id'], 'last-answer');
      expect(
        (rows.last['command'] as Map)['occurred_at'],
        (rows[1]['command'] as Map)['occurred_at'],
      );
      expect(result['task']['status'], 'completed');
      expect(result['local_completion'], isTrue);
      expect(result['items'][0]['result'], isNull);
      expect(result['items'][0]['pending_answer'], '4');
      expect(
        (await tasks.loadTasks('child')).single.status,
        TaskStatus.completed,
      );
      expect((await tasks.loadWallet('child')).coins, 100);
      expect(remote.awards, 0);
      await reviews.answer('task-child', 'question', '4', 'duplicate');
      await reviews.complete('task-child', 'old-client-finish');
      expect((await store.commands('parent')).length, 3);
      await expectLater(
        reviews.answer('task-child', 'question', 'changed', 'different'),
        throwsStateError,
      );
      await expectLater(
        reviews.transition('task-child', 'pause'),
        throwsStateError,
      );
    },
  );
  test(
    'partial answers keep timer running and only the final question queues completion',
    () async {
      remote.extraItems.add({
        ...remote.item,
        'wrong_question_id': 'second',
        'sequence': 2,
      });
      await cache();
      var result = await finalAnswer();
      expect(result['local_completion'], isFalse);
      expect(result['task']['status'], 'in_progress');
      expect((await store.commands('parent')).length, 2);
      now = now.add(const Duration(seconds: 25));
      result = await reviews.answer(
        'task-child',
        'second',
        '4',
        'second-answer',
      );
      expect(result['local_completion'], isTrue);
      expect(result['task']['accumulated_seconds'], 25);
      expect((await store.commands('parent')).length, 4);
      expect((await tasks.loadWallet('child')).coins, 100);
    },
  );
  test(
    'automatic answer and completion both survive a file database restart and replay once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'planet-auto-review-',
      );
      await tasks.dispose();
      await store.close();
      store = OfflineStore(
        NativeDatabase(File('${directory.path}/review.sqlite')),
      );
      repositories();
      await cache();
      await finalAnswer();
      final ids = (await store.commands(
        'parent',
      )).map((r) => r['command_id']).toList();
      await tasks.dispose();
      await store.close();
      store = OfflineStore(
        NativeDatabase(File('${directory.path}/review.sqlite')),
      );
      repositories();
      expect((await reviews.task('task-child'))['local_completion'], isTrue);
      expect((await store.commands('parent')).map((r) => r['command_id']), ids);
      remote.online = true;
      await tasks.synchronize('child');
      expect(await store.commands('parent'), isEmpty);
      expect(remote.awards, 1);
      expect((await tasks.loadWallet('child')).coins, 115);
      expect((await reviews.task('task-child'))['local_completion'], isFalse);
      expect(remote.requests.last['kind'], 'review_complete');
      await tasks.dispose();
      await store.close();
      store = FailingAutoStore();
      repositories();
      await directory.delete(recursive: true);
    },
  );
  test(
    'a lost final-answer reply retries its original UUID and drains the redundant finish without another reward',
    () async {
      await finalAnswer();
      remote.online = true;
      remote.loseFinalReply = true;
      await tasks.synchronize('child');
      expect(remote.awards, 1);
      expect((await store.commands('parent')).length, 2);
      expect((await tasks.loadWallet('child')).coins, 100);
      await tasks.synchronize('child');
      expect(await store.commands('parent'), isEmpty);
      expect(remote.awards, 1);
      expect((await tasks.loadWallet('child')).coins, 115);
      expect(
        remote.requests
            .where((r) => r['kind'] == 'review_answer')
            .map((r) => r['command_id']),
        ['last-answer', 'last-answer'],
      );
    },
  );
  test(
    'failure saving the completion rolls back the final answer and lets the same answer UUID retry',
    () async {
      await reviews.transition('task-child', 'start');
      (store as FailingAutoStore).failCompletion = true;
      await expectLater(
        reviews.answer('task-child', 'question', '4', 'last-answer'),
        throwsStateError,
      );
      expect((await store.commands('parent')).length, 1);
      var result = await reviews.task('task-child');
      expect(result['items'][0]['pending_answer'], isNull);
      expect(result['task']['status'], 'in_progress');
      (store as FailingAutoStore).failCompletion = false;
      result = await reviews.answer(
        'task-child',
        'question',
        '4',
        'last-answer',
      );
      expect(result['local_completion'], isTrue);
      expect((await store.commands('parent')).length, 3);
    },
  );
  test(
    'automatic completion reserves two queue slots before saving either row',
    () async {
      await reviews.transition('task-child', 'start');
      await store.transaction(() async {
        for (var i = 0; i < 498; i++) {
          await store.enqueue('parent', 'other', {
            'command_id': 'other-$i',
            'task_id': 'other-task',
            'kind': 'start',
            'occurred_at': now.toIso8601String(),
          });
        }
      });
      await expectLater(
        reviews.answer('task-child', 'question', '4', 'last-answer'),
        throwsStateError,
      );
      expect((await store.commands('parent')).length, 499);
      expect(
        (await reviews.task('task-child'))['items'][0]['pending_answer'],
        isNull,
      );
    },
  );
  test(
    'minimum duration fences a final local answer without saving a partial pair',
    () async {
      remote.tasks['task-child']!['minimum_seconds'] = 60;
      await cache();
      await reviews.transition('task-child', 'start');
      await expectLater(
        reviews.answer('task-child', 'question', '4', 'last-answer'),
        throwsStateError,
      );
      expect((await store.commands('parent')).length, 1);
      now = now.add(const Duration(seconds: 60));
      expect(
        (await reviews.answer(
          'task-child',
          'question',
          '4',
          'last-answer',
        ))['local_completion'],
        isTrue,
      );
    },
  );
  testWidgets(
    'online final submit shows automatic completion once with no extra finish tap at double text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = OnlineAutoReview()..status = 'in_progress';
      var sounds = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reviewRepositoryProvider.overrideWithValue(repository),
            taskRepositoryProvider.overrideWithValue(
              const UnconfiguredTaskRepository(),
            ),
            feedbackPreferencesStoreProvider.overrideWithValue(
              MemoryFeedbackPreferences(
                const FeedbackPreferences(sound: true, animation: false),
              ),
            ),
            completionSoundProvider.overrideWithValue(() async {
              sounds++;
            }),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const ReviewSessionScreen(taskId: 'task', childId: 'child'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('提交最后一题后自动完成，奖励由服务端确认。'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'yin2 hang2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('有点把握'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('有点把握'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('提交答案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交答案'));
      await tester.pumpAndSettle();
      expect(repository.completionCalls, 0);
      expect(sounds, 1);
      await tester.scrollUntilVisible(
        find.text('复习已完成，奖励已由服务端确认'),
        -200,
        maxScrolls: 20,
      );
      expect(find.text('25 金币 · 20 XP'), findsOneWidget);
      expect(find.text('完成复习并结算'), findsNothing);
      await tester.tap(find.byTooltip('刷新复习'));
      await tester.pumpAndSettle();
      expect(sounds, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'real offline final submit shows pending completion and keeps wallet unchanged',
    (tester) async {
      await tester.runAsync(() async {
        await reviews.transition('task-child', 'start');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              reviewRepositoryProvider.overrideWithValue(reviews),
              taskRepositoryProvider.overrideWithValue(tasks),
              feedbackPreferencesStoreProvider.overrideWithValue(
                MemoryFeedbackPreferences(
                  const FeedbackPreferences(animation: false),
                ),
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
        await tester.enterText(find.byType(TextField), '4');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('有点把握'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('有点把握'));
        await tester.pump();
        await tester.ensureVisible(find.text('提交答案'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('提交答案'));
        for (var i = 0; i < 15; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
        expect(find.text('完成操作已保存在本机，等待服务端判题与结算。'), findsOneWidget);
        expect(find.text('完成复习并结算'), findsNothing);
        expect(find.text('复习已完成，奖励已由服务端确认'), findsNothing);
        expect((await store.commands('parent')).length, 3);
        expect((await tasks.loadWallet('child')).coins, 100);
        await tester.pumpWidget(const SizedBox());
      });
    },
  );
}

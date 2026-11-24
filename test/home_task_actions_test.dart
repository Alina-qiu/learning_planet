import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/home/presentation/home_task_list.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/domain/task_sync_state.dart';
import 'support/task_workload.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

void main() {
  final start = DateTime.utc(2026, 11, 6, 5);
  final due = start.add(const Duration(hours: 1));
  TaskItem ready(
    int index, {
    String? template,
    bool review = false,
    bool deadlineOnly = false,
  }) => TaskItem(
    id: workloadTaskId(index),
    childId: workloadChild,
    title: '任务 $index',
    status: TaskStatus.ready,
    sourceType: review ? 'automatic_wrong_review' : 'parent_template',
    templateId: template,
    scheduledAt: deadlineOnly ? null : start,
    dueAt: due,
    dueDate: DateTime(2026, 11, 6),
    accumulatedSeconds: 0,
    minimumSeconds: 60,
    coinReward: 5,
    xpReward: 10,
  );

  Future<void> mount(
    WidgetTester tester,
    TaskRepository repository, {
    List<Map<String, dynamic>> reminders = const [],
    Stream<DateTime>? ticks,
    String child = workloadChild,
    String owner = workloadOwner,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(repository),
          authAccountIdProvider.overrideWithValue(owner),
          familyTodayProvider.overrideWith((_, _) async => start),
          taskSyncStateProvider.overrideWith(
            (_) => Stream.value(const TaskSyncState()),
          ),
          remindersProvider.overrideWith((_, _) async => reminders),
          authorizationClockProvider.overrideWith(
            (_) => ticks ?? Stream.value(start),
          ),
          feedbackPreferencesStoreProvider.overrideWithValue(
            MemoryFeedbackPreferences(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeTaskList(
                  childId: child,
                  familyId: workloadFamily,
                  onManageTasks: () => fail('Unexpected task list navigation'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'only matching scheduled reminder slots change a ready card at the window boundaries',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1200);
      addTearDown(tester.view.reset);
      final tasks = [
        ready(1),
        ready(2, template: 'future'),
        ready(3),
        ready(4, review: true),
        ready(5, deadlineOnly: true),
        ready(6, template: 'other-date'),
      ];
      final ticks = StreamController<DateTime>.broadcast();
      addTearDown(ticks.close);
      final before = start.subtract(const Duration(minutes: 10));
      await mount(
        tester,
        WorkloadTasks(tasks),
        ticks: ticks.stream,
        reminders: [
          {
            'remind_at': before.toIso8601String(),
            'tasks': [
              {'task_id': tasks[0].id},
              {'template_id': 'future', 'due_date': '2026-11-06'},
              {'template_id': 'other-date', 'due_date': '2026-11-07'},
              {'task_id': tasks[3].id},
            ],
          },
          {
            'remind_at': start.toIso8601String(),
            'tasks': [
              {'task_id': tasks[2].id},
            ],
          },
          {
            'remind_at': due
                .subtract(const Duration(minutes: 15))
                .toIso8601String(),
            'tasks': [
              {'task_id': tasks[4].id},
            ],
          },
        ],
      );
      Future<void> tick(DateTime at) async {
        ticks.add(at);
        await tester.pump();
        await tester.pump();
      }

      await tick(before.subtract(const Duration(seconds: 1)));
      expect(find.text('未开始'), findsNWidgets(6));
      await tick(before);
      for (final (index, task) in tasks.indexed) {
        final card = find.byKey(
          ValueKey('home-task:$workloadChild:${task.id}'),
        );
        final status = index < 2 ? '快开始啦' : '未开始';
        expect(
          find.descendant(of: card, matching: find.text(status)),
          findsOneWidget,
        );
      }
      await tick(start);
      expect(find.text('快开始啦'), findsNWidgets(3));
      await tick(due.subtract(const Duration(minutes: 15)));
      expect(find.text('快开始啦'), findsNWidgets(4));
      await tick(due.add(const Duration(seconds: 1)));
      expect(find.text('未开始'), findsNWidgets(6));
      expect(find.text('快开始啦'), findsNothing);
    },
  );

  testWidgets(
    'task feedback follows its account, child and latest task on the same screen',
    (tester) async {
      TaskItem active(int id) =>
          TaskItem.fromJson({...ready(id).toJson(), 'status': 'in_progress'});
      final repository = _HeldHomeTasks([active(1), active(2)]);
      await mount(tester, repository);
      await tester.pumpAndSettle();
      Future<void> tapTask(int id) async {
        final row = find.byKey(
          ValueKey('home-task:$workloadChild:${workloadTaskId(id)}'),
        );
        await tester.tap(find.descendant(of: row, matching: find.text('完成')));
        await tester.pump();
      }

      await tapTask(1);
      repository.waiter.completeError(StateError('任务一暂未保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('任务一暂未保存'), findsOneWidget);
      await tapTask(2);
      expect(find.textContaining('任务一暂未保存'), findsNothing);
      final oldAccount = repository.waiter;
      await mount(tester, repository, owner: 'second-owner');
      await tester.pumpAndSettle();
      await tapTask(1);
      final newAccount = repository.waiter;
      oldAccount.complete();
      await tester.pumpAndSettle();
      expect(find.text('任务已完成'), findsNothing);
      newAccount.complete();
      await tester.pumpAndSettle();
      expect(find.text('任务已完成'), findsOneWidget);
      await mount(
        tester,
        repository,
        owner: 'second-owner',
        child: 'second-child',
      );
      await tester.pumpAndSettle();
      expect(find.text('任务已完成'), findsNothing);
    },
  );
  testWidgets(
    'home uses synchronized time for reminders and running timers on a phone 48 hours fast, then saves one offline claim',
    (tester) async {
      await tester.runAsync(() async {
        final store = OfflineStore(NativeDatabase.memory());
        final task = ready(1);
        final remote = FakeTaskRemote(() => start);
        remote.tasks[task.id] = task.toJson();
        remote.wallets[workloadChild] = {
          'coin_balance': 100,
          'frozen_balance': 0,
          'xp': 120,
        };
        var now = start.add(const Duration(hours: 48));
        var owner = workloadOwner;
        final ticks = StreamController<DateTime>.broadcast();
        final repository = OfflineTaskRepository(
          store: store,
          remote: remote,
          live: WorkloadTasks([]),
          accountId: () => owner,
          autoSync: false,
          clock: () => now,
        )..setForeground(false);
        Future<void> waitFor(Finder finder) async {
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump(const Duration(milliseconds: 10));
            if (finder.evaluate().isNotEmpty) return;
          }
          expect(finder, findsOneWidget);
        }

        try {
          await repository.synchronize(workloadChild);
          remote.online = false;
          await mount(
            tester,
            repository,
            ticks: ticks.stream,
            reminders: [
              {
                'remind_at': start.toIso8601String(),
                'tasks': [
                  {'task_id': task.id},
                ],
              },
            ],
          );
          ticks.add(now);
          await waitFor(find.text('快开始啦'));
          expect(repository.displayTime(workloadChild), start);
          final unrelated =
              ScaffoldMessenger.of(
                tester.element(find.byType(HomeTaskList)),
              ).showSnackBar(
                const SnackBar(
                  content: Text('独立提示'),
                  duration: Duration(minutes: 1),
                ),
              );
          var unrelatedClosed = false;
          unrelated.closed.then((_) => unrelatedClosed = true);
          await tester.pump();
          await tester.tap(find.text('开始'));
          await waitFor(find.text('计时中 · 0分00秒 / 最低 1分00秒'));
          now = now.add(const Duration(seconds: 20));
          ticks.add(now);
          await waitFor(find.text('计时中 · 0分20秒 / 最低 1分00秒'));
          await tester.tap(find.text('完成'));
          await waitFor(find.textContaining('尚未达到最低有效时长'));
          expect(find.textContaining('计时中'), findsOneWidget);
          expect(await store.commands(workloadOwner), hasLength(1));
          // Repeated early attempts must not queue obsolete errors ahead of the
          // successful SQLite commit. Each tap waits for the button to re-enable.
          for (var retry = 0; retry < 2; retry++) {
            await tester.tap(find.text('完成'));
            await tester.pump();
            await waitFor(
              find.ancestor(
                of: find.text('完成'),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is FilledButton && widget.onPressed != null,
                ),
              ),
            );
            expect(find.textContaining('尚未达到最低有效时长'), findsOneWidget);
          }
          await tester.tap(find.text('暂停'));
          await waitFor(find.textContaining('已暂停 · 0分20秒'));
          now = now.add(const Duration(minutes: 5));
          await tester.tap(find.text('继续'));
          await waitFor(find.textContaining('计时中'));
          now = now.add(const Duration(seconds: 40));
          await tester.tap(find.text('完成'));
          await tester.tap(find.text('完成'));
          await waitFor(find.text('已完成'));
          await tester.pump(const Duration(milliseconds: 499));
          expect(find.textContaining('尚未达到最低有效时长'), findsNothing);
          expect(find.text('完成记录已保存本机，奖励待同步确认'), findsOneWidget);
          expect(find.text('独立提示'), findsOneWidget);
          expect(unrelatedClosed, isFalse);
          final commands = await store.commands(workloadOwner);
          expect(commands.map((row) => row['command']['kind']), [
            'start',
            'pause',
            'resume',
            'complete',
          ]);
          expect(commands.first['command']['start_origin'], 'child_mode');
          expect(
            (await repository.loadTasks(
              workloadChild,
            )).single.accumulatedSeconds,
            60,
          );
          expect((await repository.loadWallet(workloadChild)).coins, 100);
          expect(remote.requests, isEmpty);
          expect(repository.displayTime('other-child'), isNull);
          owner = 'other-owner';
          expect(repository.displayTime(workloadChild), isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await ticks.close();
          await repository.dispose();
          await store.close();
        }
      });
    },
  );
}

class _HeldHomeTasks extends WorkloadTasks {
  _HeldHomeTasks(super.tasks);
  late Completer<void> waiter;
  @override
  Future<void> complete(String taskId) {
    waiter = Completer<void>();
    return waiter.future;
  }
}

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/growth/data/growth_repository.dart';
import 'package:learning_planet/features/home/presentation/home_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/domain/task_sync_state.dart';
import 'package:learning_planet/features/tasks/domain/wallet_summary.dart';

import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'support/task_workload.dart';
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

class _SlowReads extends OfflineTaskRepository {
  _SlowReads({
    required super.store,
    required super.remote,
    required super.clock,
    required super.accountId,
  }) : super(live: WorkloadTasks([]), autoSync: false);

  Completer<void>? reads;

  @override
  Future<List<TaskItem>> loadTasks(String childId) async {
    await reads?.future;
    return super.loadTasks(childId);
  }

  @override
  Future<WalletSummary> loadWallet(String childId) async {
    await reads?.future;
    return super.loadWallet(childId);
  }
}

void main() {
  testWidgets(
    'background sync keeps the confirmed home card and wallet until new data arrives',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 2000);
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final now = DateTime.utc(2026, 9, 16, 4);
        final store = OfflineStore(NativeDatabase.memory());
        final remote = FakeTaskRemote(() => now)..seed(workloadChild);
        final repository = _SlowReads(
          store: store,
          remote: remote,
          accountId: () => workloadOwner,
          clock: () => now,
        )..setForeground(false);
        final card = find.byKey(
          const ValueKey('home-task:$workloadChild:task-$workloadChild'),
        );
        final title = find.descendant(of: card, matching: find.text('学习任务'));
        final start = find.descendant(of: card, matching: find.text('开始'));
        final balance = find.text('金币 100 · 冻结 0 · XP 200');
        Future<void> waitFor(Finder finder) async {
          for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(finder, findsOneWidget);
        }

        try {
          await repository.synchronize(workloadChild);
          repository.reads = Completer<void>();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                taskRepositoryProvider.overrideWithValue(repository),
                familiesProvider.overrideWith(
                  (_) => WorkloadFamily().loadFamilies(),
                ),
                authorizationClockProvider.overrideWith(
                  (_) => Stream.value(now),
                ),
                remindersProvider(workloadChild).overrideWith((_) async => []),
                growthProvider(workloadChild).overrideWith(
                  (_) async => {
                    'streak': 0,
                    'appearance': {'avatar': 'astronaut'},
                    'assets': <Map<String, dynamic>>[],
                  },
                ),
                feedbackPreferencesStoreProvider.overrideWithValue(
                  MemoryFeedbackPreferences(),
                ),
              ],
              child: MaterialApp(
                home: HomeScreen(
                  selectedChildId: workloadChild,
                  childNickname: '测试孩子',
                  children: const [
                    ChildProfile(
                      id: workloadChild,
                      familyId: workloadFamily,
                      nickname: '测试孩子',
                      grade: 2,
                    ),
                  ],
                  isParentMode: false,
                  onChildSelected: (_) {},
                  onManageFamily: () {},
                  onManageTasks: () {},
                  onParentMode: () {},
                  onSignOut: () async {},
                ),
              ),
            ),
          );
          expect(title, findsNothing);
          expect(balance, findsNothing);
          repository.reads!.complete();
          await waitFor(start);
          await waitFor(balance);

          repository.reads = Completer<void>();
          remote.snapshotBarrier = Completer<void>();
          final started = repository.changes.firstWhere(
            (s) => s.phase == TaskSyncPhase.syncing,
          );
          final syncing = repository.synchronize(workloadChild);
          await started;
          await tester.ensureVisible(start);
          await tester.pump();
          await tester.pump();
          expect(title, findsOneWidget);
          expect(start, findsOneWidget);
          expect(balance, findsOneWidget);

          remote.tasks['task-$workloadChild']!['title'] = '更新后的任务';
          remote.wallets[workloadChild]!['coin_balance'] = 107;
          repository.reads!.complete();
          remote.snapshotBarrier!.complete();
          await syncing;
          await waitFor(find.text('更新后的任务'));
          await waitFor(find.text('金币 107 · 冻结 0 · XP 200'));
          expect(title, findsNothing);
          expect(balance, findsNothing);

          // Once access is removed, a slow local read must clear both views.
          repository.reads = Completer<void>();
          await repository.forgetChild(workloadChild);
          await tester.pump();
          await tester.pump();
          expect(find.text('更新后的任务'), findsNothing);
          expect(find.text('金币 107 · 冻结 0 · XP 200'), findsNothing);
          repository.reads!.complete();
          await waitFor(find.text('任务读取失败，请下拉重试'));
          await waitFor(find.text('钱包读取失败，请下拉重试'));
        } finally {
          if (repository.reads?.isCompleted == false) {
            repository.reads!.complete();
          }
          if (remote.snapshotBarrier?.isCompleted == false) {
            remote.snapshotBarrier!.complete();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await repository.dispose();
          await store.close();
        }
      });
    },
  );
  test(
    'queue writes, account changes and deletion reset task data even during sync',
    () async {
      final now = DateTime.utc(2026, 9, 16, 4);
      final store = OfflineStore(NativeDatabase.memory());
      final remote = FakeTaskRemote(() => now)..seed(workloadChild);
      String? owner = workloadOwner;
      final repository = OfflineTaskRepository(
        store: store,
        remote: remote,
        clock: () => now,
        accountId: () => owner,
        live: WorkloadTasks([]),
        autoSync: false,
      )..setForeground(false);
      try {
        await repository.synchronize(workloadChild);
        final confirmed = repository.state;
        final started = repository.changes.firstWhere(
          (s) => s.phase == TaskSyncPhase.syncing,
        );
        remote.snapshotBarrier = Completer<void>();
        final syncing = repository.synchronize(workloadChild);
        final waiting = await started;
        expect(waiting.revision, greaterThan(confirmed.revision));
        expect(waiting.dataRevision, confirmed.dataRevision);
        await repository.loadTasks(workloadChild);
        await repository.start('task-$workloadChild');
        final queued = repository.state;
        expect(queued.phase, TaskSyncPhase.syncing);
        expect(queued.pending, 1);
        expect(queued.dataRevision, greaterThan(waiting.dataRevision));
        remote.snapshotBarrier!.complete();
        await syncing;
        expect(repository.state.dataRevision, greaterThan(queued.dataRevision));

        var revision = repository.state.dataRevision;
        for (final next in [null, 'second-account']) {
          owner = next;
          repository.scopeChanged();
          expect(repository.state.dataRevision, greaterThan(revision));
          revision = repository.state.dataRevision;
        }
        await repository.forgetAccount(owner!, 'synthetic-job');
        expect(repository.state.dataRevision, greaterThan(revision));
        await expectLater(
          repository.loadWallet(workloadChild),
          throwsStateError,
        );
      } finally {
        if (remote.snapshotBarrier?.isCompleted == false) {
          remote.snapshotBarrier!.complete();
        }
        await repository.dispose();
        await store.close();
      }
    },
  );
}

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/growth/data/growth_repository.dart';
import 'package:learning_planet/features/home/presentation/home_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task_sync_state.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'support/task_workload.dart';
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

void main() {
  final now = DateTime(2026, 11, 6, 12);
  const nickname = '喜欢阅读和数学的小星';

  Future<void> mount(
    WidgetTester tester,
    Size size,
    TaskRepository repository, {
    bool home = false,
    bool parent = false,
    VoidCallback? manage,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewPadding = size.width > size.height
        ? const FakeViewPadding(top: 24, left: 48, right: 48)
        : const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = tester.view.viewPadding;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(repository),
          familyTodayProvider(workloadChild).overrideWith((_) async => now),
          familiesProvider.overrideWith((_) => WorkloadFamily().loadFamilies()),
          activeParentFamilyProvider.overrideWithValue(
            parent ? workloadFamily : null,
          ),
          authorizationClockProvider.overrideWith((_) => Stream.value(now)),
          taskSyncStateProvider.overrideWith(
            (_) => Stream.value(
              const TaskSyncState(
                phase: TaskSyncPhase.offline,
                pending: 3,
                message: 'NETWORK_UNAVAILABLE',
              ),
            ),
          ),
          feedbackPreferencesStoreProvider.overrideWithValue(
            MemoryFeedbackPreferences(),
          ),
          growthProvider(workloadChild).overrideWith(
            (_) async => {
              'streak': 3,
              'appearance': {'avatar': 'astronaut'},
              'assets': <Map<String, dynamic>>[],
            },
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: home
              ? HomeScreen(
                  childNickname: nickname,
                  children: const [
                    ChildProfile(
                      id: workloadChild,
                      familyId: workloadFamily,
                      nickname: nickname,
                      grade: 2,
                    ),
                  ],
                  selectedChildId: workloadChild,
                  onChildSelected: (_) {},
                  onManageFamily: () {},
                  onManageTasks: manage ?? () {},
                  isParentMode: parent,
                  onParentMode: () {},
                  onSignOut: () async {},
                )
              : const TaskManagementScreen(
                  childId: workloadChild,
                  childNickname: nickname,
                  familyId: workloadFamily,
                  isParentMode: false,
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder verticalScroll() => find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      )
      .first;

  for (final size in [const Size(360, 800), const Size(640, 320)]) {
    testWidgets('large-text home task action clears system areas at $size', (
      tester,
    ) async {
      var opened = 0;
      await mount(
        tester,
        size,
        WorkloadTasks(taskWorkload(3, now, dueDate: now)),
        home: true,
        manage: () => opened++,
      );
      expect(tester.takeException(), isNull);
      final card = find.byKey(
        ValueKey('home-task:$workloadChild:${workloadTaskId(2)}'),
      );
      await tester.scrollUntilVisible(
        card,
        250,
        scrollable: verticalScroll(),
        maxScrolls: 30,
      );
      final position = tester.state<ScrollableState>(verticalScroll()).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final action = find.descendant(
        of: card,
        matching: find.byType(FilledButton),
      );
      final bounds = tester.getRect(action);
      expect(
        bounds.bottom,
        lessThanOrEqualTo(size.height - tester.view.padding.bottom),
      );
      expect(
        tester.getRect(card).left,
        greaterThanOrEqualTo(tester.view.padding.left),
      );
      expect(
        tester.getRect(card).right,
        lessThanOrEqualTo(size.width - tester.view.padding.right),
      );
      await tester.tap(action.hitTestable());
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'offline banner does not block large-text task completion at $size',
      (tester) async {
        await tester.runAsync(() async {
          final store = OfflineStore(NativeDatabase.memory());
          final remote = HeldTaskRemote();
          final repository = OfflineTaskRepository(
            store: store,
            remote: remote,
            live: WorkloadTasks([]),
            accountId: () => workloadOwner,
            autoSync: false,
            clock: () => now,
          )..setForeground(false);
          try {
            await store.write(
              workloadOwner,
              'tasks:$workloadChild',
              taskWorkloadSnapshot(taskWorkload(1, now, dueDate: now), now),
            );
            await mount(tester, size, repository);
            for (var i = 0; i < 6; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final complete = find.byTooltip('完成');
            await tester.scrollUntilVisible(
              complete,
              100,
              scrollable: verticalScroll(),
              maxScrolls: 30,
            );
            await tester.pumpAndSettle();
            final bounds = tester.getRect(complete);
            expect(
              bounds.top,
              greaterThanOrEqualTo(tester.view.padding.top + kToolbarHeight),
            );
            expect(
              bounds.bottom,
              lessThanOrEqualTo(size.height - tester.view.padding.bottom),
            );
            expect(bounds.left, greaterThanOrEqualTo(tester.view.padding.left));
            expect(
              bounds.right,
              lessThanOrEqualTo(size.width - tester.view.padding.right),
            );
            await tester.tap(complete.hitTestable());
            for (var i = 0; i < 8; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
            final commands = await store.commands(workloadOwner);
            expect(commands, hasLength(1));
            expect(commands.single['command']['kind'], 'complete');
            expect(remote.calls, 0);
            expect((await repository.loadWallet(workloadChild)).coins, 100);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await repository.dispose();
            await store.close();
          }
        });
      },
    );
  }
}

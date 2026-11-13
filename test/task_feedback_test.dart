import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/growth/domain/task_adventure.dart';
import 'package:learning_planet/features/growth/presentation/feedback_settings_screen.dart';
import 'package:learning_planet/features/growth/presentation/task_feedback.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'review_module_test.dart' show FakeReviewRepository;
import 'support/task_workload.dart';

class MemoryFeedbackPreferences implements FeedbackPreferencesStore {
  MemoryFeedbackPreferences([this.value = const FeedbackPreferences()]);
  FeedbackPreferences value;
  bool failRead = false, failWrite = false;
  Completer<FeedbackPreferences>? readWait;
  Completer<void>? writeWait;
  int writes = 0;
  @override
  Future<FeedbackPreferences> read() async {
    if (failRead) throw StateError('unavailable');
    return readWait == null ? value : readWait!.future;
  }

  @override
  Future<void> write(FeedbackPreferences next) async {
    writes++;
    if (writeWait != null) await writeWait!.future;
    if (failWrite) throw StateError('unavailable');
    value = next;
  }
}

class PreferencesTransport extends Fake implements SharedPreferencesAsync {
  final data = <String, String>{};
  @override
  Future<String?> getString(String key) async => data[key];
  @override
  Future<void> setString(String key, String value) async {
    data[key] = value;
  }
}

TaskItem adventureTask(
  String id,
  TaskStatus status, {
  String child = 'child',
  int day = 5,
}) => TaskItem(
  id: id,
  childId: child,
  title: '任务',
  status: status,
  coinReward: 100,
  xpReward: 200,
  dueDate: DateTime(2026, 11, day),
  accumulatedSeconds: 0,
);

void main() {
  test(
    'adventure uses family day and current child and never counts failures as completed',
    () {
      final tasks = [
        adventureTask('complete', TaskStatus.completed),
        adventureTask('complete', TaskStatus.completed),
        adventureTask('pending', TaskStatus.completed),
        adventureTask('ready', TaskStatus.ready),
        adventureTask('paused', TaskStatus.paused),
        adventureTask('abandoned', TaskStatus.abandoned),
        adventureTask('skipped', TaskStatus.skipped),
        adventureTask('backlog', TaskStatus.ready, day: 4),
        adventureTask('old-complete', TaskStatus.completed, day: 4),
        adventureTask('future', TaskStatus.ready, day: 6),
        adventureTask('other-child', TaskStatus.completed, child: 'other'),
      ];
      final progress = TaskAdventure.fromTasks(
        tasks,
        childId: 'child',
        familyDate: DateTime(2026, 11, 5),
        pendingTaskIds: {'pending'},
      );
      expect(progress.total, 7);
      expect(progress.completed, 2);
      expect(progress.remaining, 5);
      expect(progress.pending, 1);
      expect(progress.energy, closeTo(5 / 7, .001));
      final empty = TaskAdventure.fromTasks(
        [],
        childId: 'child',
        familyDate: DateTime(2026, 11, 5),
      );
      expect(empty.energy, 0);
      final restored = TaskAdventure.fromTasks(
        [adventureTask('backlog', TaskStatus.completed, day: 4)],
        childId: 'child',
        familyDate: DateTime(2026, 11, 5),
      );
      expect(restored.total, 0);
    },
  );
  test(
    'device preferences adapter persists exactly two flags and reloads on a new instance',
    () async {
      final transport = PreferencesTransport();
      final first = DeviceFeedbackPreferences(transport);
      expect((await first.read()).sound, isFalse);
      expect((await first.read()).animation, isTrue);
      await first.write(
        const FeedbackPreferences(sound: true, animation: false),
      );
      final reopened = await DeviceFeedbackPreferences(transport).read();
      expect(reopened.sound, isTrue);
      expect(reopened.animation, isFalse);
      expect(transport.data.keys, [DeviceFeedbackPreferences.key]);
      expect(jsonDecode(transport.data.values.single), {
        'sound': true,
        'animation': false,
      });
      transport.data[DeviceFeedbackPreferences.key] =
          '{"sound":"yes","animation":true}';
      await expectLater(first.read(), throwsFormatException);
    },
  );
  test(
    'preference read failures disable effects until retry and writes are serialized',
    () async {
      final store = MemoryFeedbackPreferences()..failRead = true;
      final controller = FeedbackPreferencesController(store);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.ready, isFalse);
      expect(controller.state.value.animation, isFalse);
      await controller.save(const FeedbackPreferences(sound: true));
      expect(store.writes, 0);
      store.failRead = false;
      await controller.load();
      store.writeWait = Completer<void>();
      final saved = controller.save(
        const FeedbackPreferences(sound: true, animation: false),
      );
      await controller.save(const FeedbackPreferences());
      expect(store.writes, 1);
      expect(controller.state.saving, isTrue);
      expect(controller.state.value.sound, isFalse);
      store.writeWait!.complete();
      await saved;
      expect(controller.state.value.sound, isTrue);
      store.failWrite = true;
      await controller.save(const FeedbackPreferences(sound: false));
      expect(controller.state.value.sound, isTrue);
      expect(controller.state.error, isNotNull);
      controller.dispose();
    },
  );
  test(
    'late preference reads and writes cannot update disposed controllers',
    () async {
      final store = MemoryFeedbackPreferences()
        ..readWait = Completer<FeedbackPreferences>();
      final first = FeedbackPreferencesController(store);
      first.dispose();
      store.readWait!.complete(const FeedbackPreferences(sound: true));
      await Future<void>.delayed(Duration.zero);
      store.readWait = null;
      final second = FeedbackPreferencesController(store);
      await Future<void>.delayed(Duration.zero);
      store.writeWait = Completer<void>();
      final saving = second.save(const FeedbackPreferences(animation: false));
      second.dispose();
      store.writeWait!.complete();
      await saving;
    },
  );

  testWidgets(
    'completion is visible immediately and effects and notice finish within two seconds',
    (tester) async {
      var sounds = 0;
      await feedbackHarness(
        tester,
        store: MemoryFeedbackPreferences(
          const FeedbackPreferences(sound: true),
        ),
        sound: () async {
          sounds++;
        },
      );
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(find.text('任务已完成'), findsOneWidget);
      expect(sounds, 1);
      final noticeTween = tester.widget<TweenAnimationBuilder<double>>(
        find.descendant(
          of: find.byType(TaskCompletionNotice),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
      );
      expect(noticeTween.duration, const Duration(milliseconds: 600));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();
      expect(find.byType(TaskCompletionNotice), findsNothing);
    },
  );
  testWidgets(
    'disabled sound and motion still show text and never call audio',
    (tester) async {
      var sounds = 0;
      await feedbackHarness(
        tester,
        store: MemoryFeedbackPreferences(
          const FeedbackPreferences(animation: false),
        ),
        sound: () async {
          sounds++;
        },
        pending: true,
      );
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(find.text('完成记录已保存本机，奖励待同步确认'), findsOneWidget);
      expect(sounds, 0);
      final tween = tester.widget<TweenAnimationBuilder<double>>(
        find.byType(TweenAnimationBuilder<double>),
      );
      expect(tween.duration, Duration.zero);
    },
  );
  testWidgets(
    'system reduce motion overrides enabled animation and sound failures preserve completion',
    (tester) async {
      await feedbackHarness(
        tester,
        store: MemoryFeedbackPreferences(
          const FeedbackPreferences(sound: true),
        ),
        reduceMotion: true,
        sound: () => throw StateError('sound unavailable'),
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('任务已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<TweenAnimationBuilder<double>>(
              find.byType(TweenAnimationBuilder<double>),
            )
            .duration,
        Duration.zero,
      );
      await tester.pump(const Duration(seconds: 2));
    },
  );
  testWidgets('asynchronous sound errors never fail durable completion', (
    tester,
  ) async {
    await feedbackHarness(
      tester,
      store: MemoryFeedbackPreferences(const FeedbackPreferences(sound: true)),
      sound: () async => throw StateError('unsupported'),
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('任务已完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'background completion never starts sound or transient celebration',
    (tester) async {
      var sounds = 0;
      await feedbackHarness(
        tester,
        store: MemoryFeedbackPreferences(
          const FeedbackPreferences(sound: true),
        ),
        sound: () async {
          sounds++;
        },
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(sounds, 0);
      expect(find.byType(TaskCompletionNotice), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byType(TaskCompletionNotice), findsNothing);
    },
  );
  testWidgets(
    'settings persist changes and do not claim a failed save succeeded at double text size',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryFeedbackPreferences();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            feedbackPreferencesStoreProvider.overrideWithValue(store),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const FeedbackSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成提示音'));
      await tester.pumpAndSettle();
      expect(store.value.sound, isTrue);
      store.failWrite = true;
      await tester.scrollUntilVisible(find.text('任务反馈动画'), 150);
      await tester.tap(find.text('任务反馈动画'));
      await tester.pumpAndSettle();
      expect(store.value.animation, isTrue);
      await tester.scrollUntilVisible(find.textContaining('偏好未能保存'), 180);
      expect(find.textContaining('系统已启用减少动态效果'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'adventure shows pending completion without any coin reward and handles large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            feedbackPreferencesStoreProvider.overrideWithValue(
              MemoryFeedbackPreferences(),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: TaskAdventureCard(
                  progress: TaskAdventure(total: 5, completed: 2, pending: 1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('怪兽能量 3 格'), findsOneWidget);
      expect(find.textContaining('1 项待同步确认'), findsOneWidget);
      expect(find.textContaining('金币'), findsNothing);
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('怪兽剩余能量')), findsOneWidget);
      semantics.dispose();
    },
  );
  testWidgets(
    'review completion celebrates once and refresh never replays the effect',
    (tester) async {
      final review = FakeReviewRepository()
        ..status = 'in_progress'
        ..result = true
        ..submitted = 'yin2 hang2';
      var sounds = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reviewRepositoryProvider.overrideWithValue(review),
            taskRepositoryProvider.overrideWithValue(
              const UnconfiguredTaskRepository(),
            ),
            activeParentFamilyProvider.overrideWithValue(null),
            feedbackPreferencesStoreProvider.overrideWithValue(
              MemoryFeedbackPreferences(const FeedbackPreferences(sound: true)),
            ),
            completionSoundProvider.overrideWithValue(() async {
              sounds++;
            }),
          ],
          child: const MaterialApp(
            home: ReviewSessionScreen(taskId: 'task', childId: 'child'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('完成复习并结算'));
      await tester.tap(find.text('完成复习并结算'));
      await tester.pumpAndSettle();
      expect(review.completionCalls, 1);
      expect(sounds, 1);
      expect(find.byType(TaskCompletionNotice), findsOneWidget);
      await tester.tap(find.byTooltip('刷新复习'));
      await tester.pumpAndSettle();
      expect(sounds, 1);
      expect(review.completionCalls, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(TaskCompletionNotice), findsNothing);
    },
  );
  testWidgets(
    'real local completion commits once before network reply and never invents wallet rewards',
    (tester) async {
      await tester.runAsync(() async {
        final store = OfflineStore(NativeDatabase.memory()),
            remote = HeldTaskRemote();
        final now = DateTime.now(),
            data = taskWorkload(1, DateTime.now(), dueDate: DateTime.now());
        await store.write(
          workloadOwner,
          'tasks:$workloadChild',
          taskWorkloadSnapshot(data, now),
        );
        final repository = OfflineTaskRepository(
          store: store,
          remote: remote,
          live: WorkloadTasks(data),
          accountId: () => workloadOwner,
          autoSync: false,
        );
        var sounds = 0;
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                taskRepositoryProvider.overrideWithValue(repository),
                familiesProvider.overrideWith(
                  (ref) => WorkloadFamily().loadFamilies(),
                ),
                activeParentFamilyProvider.overrideWithValue(null),
                authorizationClockProvider.overrideWith(
                  (ref) => Stream.value(now),
                ),
                feedbackPreferencesStoreProvider.overrideWithValue(
                  MemoryFeedbackPreferences(
                    const FeedbackPreferences(sound: true),
                  ),
                ),
                completionSoundProvider.overrideWithValue(() async {
                  sounds++;
                }),
              ],
              child: const MaterialApp(
                home: TaskManagementScreen(
                  childId: workloadChild,
                  childNickname: '测试孩子',
                  familyId: workloadFamily,
                  isParentMode: false,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('完成'));
          await tester.pumpAndSettle();
          expect(find.text('完成记录已保存本机，奖励待同步确认'), findsOneWidget);
          expect((await store.commands(workloadOwner)).length, 1);
          expect(remote.waiting.isCompleted, isFalse);
          expect((await repository.loadWallet(workloadChild)).coins, 100);
          expect(sounds, 1);
          await tester.pumpWidget(const SizedBox());
          expect(sounds, 1);
        } finally {
          await tester.pumpWidget(const SizedBox());
          remote.waiting.complete();
          await repository.dispose();
          await store.close();
        }
      });
    },
  );
}

Future<void> feedbackHarness(
  WidgetTester tester, {
  required MemoryFeedbackPreferences store,
  Future<void> Function()? sound,
  bool pending = false,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feedbackPreferencesStoreProvider.overrideWithValue(store),
        if (sound != null) completionSoundProvider.overrideWithValue(sound),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Consumer(
          builder: (context, ref, _) {
            ref.watch(feedbackPreferencesProvider);
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showTaskCompletionFeedback(
                    context,
                    ref,
                    pending: pending,
                  ),
                  child: const Text('完成'),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

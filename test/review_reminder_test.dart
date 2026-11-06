import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/notifications/data/parent_notification_device.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/wrong_questions/data/review_reminder_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_reminder.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_reminder_dialog.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_hub_screen.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'support/mock_supabase.dart';
import 'widget_test.dart' show FakeTaskRepository;
import 'review_module_test.dart' show FakeReviewRepository;

class NoTaskRemote extends Fake implements TaskSyncRemote {}

class ReminderCacheTasks extends OfflineTaskRepository {
  ReminderCacheTasks(OfflineStore store, String? Function() account)
    : super(
        store: store,
        remote: NoTaskRemote(),
        live: FakeTaskRepository(),
        accountId: account,
        autoSync: false,
      );
  @override
  Future<List<TaskItem>> loadTasks(String childId) async => [];
}

Map<String, dynamic> stateJson({
  int revision = 0,
  bool enabled = true,
  bool allowed = true,
  String? at,
}) => {
  'revision': revision,
  'enabled': enabled,
  'allowed': allowed,
  'remind_at': at,
  'remind_local': at == null ? null : '11-05 12:30 Asia/Shanghai',
};

class FakeReminders extends Fake implements ReviewReminderRepository {
  var state = ReviewReminder.fromJson(stateJson());
  final calls = <({int minutes, int revision, String id})>[];
  bool loseReply = false;
  @override
  Future<ReviewReminder> load(String taskId) async => state;
  @override
  Future<ReviewReminder> set(
    String taskId,
    int minutes,
    int revision,
    String id,
  ) async {
    calls.add((minutes: minutes, revision: revision, id: id));
    state = ReviewReminder.fromJson(
      stateJson(
        revision: revision + 1,
        at: minutes == 0
            ? null
            : DateTime.now()
                  .add(Duration(minutes: minutes))
                  .toUtc()
                  .toIso8601String(),
      ),
    );
    if (loseReply) {
      loseReply = false;
      throw const SocketException('reply lost');
    }
    return state;
  }
}

class FakeSchedules extends Fake implements ScheduleRepository {
  FakeSchedules(this.reminders);
  final FakeReminders reminders;
  @override
  Future<T> changeReminders<T>(String childId, Future<T> Function() action) =>
      action();
  @override
  Future<List<Map<String, dynamic>>> loadReminders(String childId) async => [
    if (reminders.state.at != null)
      {
        'remind_at': reminders.state.at!.toIso8601String(),
        'tasks': [
          {'task_id': 'task'},
        ],
      },
  ];
}

class FakeScheduler extends Fake implements NotificationScheduler {
  bool granted = true, failSync = false;
  int syncs = 0;
  @override
  Future<bool> requestPermission() async => granted;
  @override
  Future<void> setScope(String? childId) async {}
  @override
  Future<void> synchronize(
    String child,
    List<Map<String, dynamic>> rows,
  ) async {
    syncs++;
    if (failSync) throw StateError('native unavailable');
  }
}

void main() {
  test(
    'reminder changes retire cached plans and fence late replies across repository restarts',
    () async {
      final backend = MockSupabase();
      addTearDown(backend.close);
      await backend.signIn();
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final tasks = ReminderCacheTasks(
        store,
        () => backend.client.auth.currentUser?.id,
      );
      addTearDown(tasks.dispose);
      final repo = ScheduleRepository(backend.client, offline: tasks);
      await store.write(MockSupabase.firstUser, 'reminders:child', {
        'items': [
          {'reminder_key': 'old'},
        ],
      });
      final entered = Completer<void>(), release = Completer<void>();
      backend.handle = (request) async {
        entered.complete();
        await release.future;
        return MockSupabase.json(request, [
          {'reminder_key': 'old'},
        ]);
      };
      final pending = repo.loadReminders('child'),
          rejected = expectLater(pending, throwsStateError);
      await entered.future;
      await expectLater(
        repo.changeReminders('child', () async {
          await expectLater(repo.loadReminders('child'), throwsStateError);
          throw const SocketException('write reply lost');
        }),
        throwsA(isA<SocketException>()),
      );
      release.complete();
      await rejected;
      expect(
        await store.read(MockSupabase.firstUser, 'reminders:child'),
        isNull,
      );
      final restarted = ScheduleRepository(backend.client, offline: tasks);
      backend.handle = (_) => throw const SocketException('offline');
      await expectLater(
        restarted.loadReminders('child'),
        throwsA(isA<SocketException>()),
      );
      backend.handle = (request) => MockSupabase.json(request, [
        {'reminder_key': 'new'},
      ]);
      expect(
        (await restarted.loadReminders('child')).single['reminder_key'],
        'new',
      );
      backend.handle = (_) => throw const SocketException('offline');
      expect(
        (await restarted.loadReminders('child')).single['reminder_key'],
        'new',
      );
      await store.removeChildData('child');
      expect(
        await store.read(MockSupabase.firstUser, 'reminder-version:child'),
        isNull,
      );
    },
  );
  test('review reminder response validates version, flags and timestamp', () {
    final state = ReviewReminder.fromJson(
      stateJson(revision: 3, at: '2026-11-05T04:30:00Z'),
    );
    expect(state.revision, 3);
    expect(state.at, DateTime.utc(2026, 11, 5, 4, 30));
    for (final invalid in [
      {'revision': -1},
      {'revision': '1'},
      {'enabled': null},
      {'allowed': 'yes'},
      {'remind_at': 'bad'},
      {'remind_at': 2},
      {'remind_local': {}},
    ]) {
      expect(
        () => ReviewReminder.fromJson({...stateJson(), ...invalid}),
        throwsFormatException,
      );
    }
  });
  test(
    'real SDK sends explicit reminder intent and rejects changed account or privacy scope',
    () async {
      final backend = MockSupabase();
      addTearDown(backend.close);
      await backend.signIn();
      var privacy = 1;
      final repo = SupabaseReviewReminderRepository(
        backend.client,
        privacyGeneration: () => privacy,
      );
      backend.handle = (request) => MockSupabase.json(request, stateJson());
      expect((await repo.load('task')).revision, 0);
      await repo.set('task', 30, 2, 'request');
      expect(MockSupabase.body(backend.calls.last), {
        'target_task_id': 'task',
        'delay_minutes': 30,
        'expected_revision': 2,
        'command_id': 'request',
      });
      expect(() => repo.set('task', 1, 0, 'request'), throwsArgumentError);
      expect(() => repo.set('task', 15, -1, 'request'), throwsArgumentError);
      expect(() => repo.set('task', 15, 0, ''), throwsArgumentError);
      final entered = Completer<void>(), release = Completer<void>();
      backend.handle = (request) async {
        entered.complete();
        await release.future;
        return MockSupabase.json(request, stateJson());
      };
      final pending = repo.load('task');
      final rejected = expectLater(pending, throwsStateError);
      await entered.future;
      privacy++;
      release.complete();
      await rejected;
      backend.handle = (request) async {
        await backend.signIn(MockSupabase.secondUser);
        return MockSupabase.json(request, stateJson());
      };
      await expectLater(repo.load('task'), throwsStateError);
      await backend.client.auth.signOut();
      await expectLater(repo.load('task'), throwsStateError);
    },
  );
  Future<void> show(
    WidgetTester tester,
    FakeReminders repo,
    FakeScheduler scheduler, {
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewReminderRepositoryProvider.overrideWithValue(repo),
          notificationSchedulerProvider.overrideWithValue(scheduler),
          parentNotificationDeviceProvider.overrideWithValue(null),
          scheduleRepositoryProvider.overrideWithValue(FakeSchedules(repo)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: ReviewReminderDialog(
              childId: 'child',
              familyId: 'family',
              taskId: 'task',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'lost reply retries same intent, successful booking schedules and cancellation uses next revision',
    (tester) async {
      final repo = FakeReminders()..loseReply = true,
          scheduler = FakeScheduler();
      await show(tester, repo, scheduler);
      await tester.tap(find.text('约 30 分钟后'));
      await tester.pumpAndSettle();
      expect(find.text('重试原请求'), findsOneWidget);
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(repo.calls[0], repo.calls[1]);
      expect(scheduler.syncs, 1);
      expect(find.textContaining('已预约：'), findsOneWidget);
      await tester.tap(find.text('取消这次预约'));
      await tester.pumpAndSettle();
      expect(repo.calls.last.minutes, 0);
      expect(repo.calls.last.revision, 1);
      expect(find.text('当前没有未来预约'), findsOneWidget);
      expect(scheduler.syncs, 2);
    },
  );
  testWidgets(
    'native scheduling failure is retried without creating another booking',
    (tester) async {
      final repo = FakeReminders(),
          scheduler = FakeScheduler()..failSync = true;
      await show(tester, repo, scheduler);
      await tester.tap(find.text('约 15 分钟后'));
      await tester.pumpAndSettle();
      expect(find.textContaining('预约已保存，本机提醒同步失败'), findsOneWidget);
      scheduler.failSync = false;
      await tester.tap(find.text('重试本机提醒'));
      await tester.pumpAndSettle();
      expect(repo.calls, hasLength(1));
      expect(scheduler.syncs, 2);
      expect(find.text('重试本机提醒'), findsNothing);
    },
  );
  testWidgets(
    'denied system permission and family off switch never book reminders',
    (tester) async {
      final repo = FakeReminders(),
          scheduler = FakeScheduler()..granted = false;
      await show(tester, repo, scheduler);
      await tester.tap(find.text('约 15 分钟后'));
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty);
      expect(find.textContaining('未取得系统通知权限'), findsOneWidget);
      repo.state = ReviewReminder.fromJson(stateJson(enabled: false));
      await tester.tap(find.text('重新核对'));
      await tester.pumpAndSettle();
      expect(find.text('家长已关闭任务提醒。'), findsOneWidget);
      expect(find.text('约 15 分钟后'), findsNothing);
    },
  );
  testWidgets(
    'review reminder options remain usable at 360px and double text size',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, FakeReminders(), FakeScheduler(), scale: 2);
      await tester.ensureVisible(find.text('约 60 分钟后'));
      await tester.tap(find.text('约 60 分钟后'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已预约：'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'review hub exposes later reminder for active online review queues',
    (tester) async {
      final repo = FakeReminders();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
            reviewOverviewProvider.overrideWith(
              (ref, child) async => {
                'task_id': 'task',
                'due': 2,
                'backlog': 0,
                'reminder': stateJson(),
              },
            ),
            reviewRepositoryProvider.overrideWithValue(FakeReviewRepository()),
            reviewReminderRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: ReviewHubScreen(childId: 'child', familyId: 'family'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('稍后提醒'), findsOneWidget);
      await tester.tap(find.text('稍后提醒'));
      await tester.pumpAndSettle();
      expect(find.text('稍后提醒我复习'), findsOneWidget);
      expect(find.text('约 15 分钟后'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

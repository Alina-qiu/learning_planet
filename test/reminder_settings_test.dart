import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/notifications/data/parent_notification_device.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/domain/schedule_snapshot.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/presentation/reminder_settings_dialog.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';

import 'review_reminder_test.dart' show NoTaskRemote, FakeScheduler;
import 'scheduling_and_notifications_test.dart'
    show FakeNotifications, schedulerFor, reminder;
import 'support/mock_supabase.dart';
import 'support/task_push.dart' as task_push;
import 'widget_test.dart' show FakeTaskRepository;

class CacheTasks extends OfflineTaskRepository {
  CacheTasks(OfflineStore store, MockSupabase backend)
    : super(
        store: store,
        remote: NoTaskRemote(),
        live: SupabaseTaskRepository(backend.client),
        accountId: () => backend.client.auth.currentUser?.id,
        autoSync: false,
      );
  @override
  Future<List<TaskItem>> loadTasks(String childId) async => [];
}

class SettingsRepository extends Fake implements ScheduleRepository {
  bool enabled = true, loseReply = false;
  int saves = 0;
  String start = '21:00', end = '07:00';
  @override
  Future<Map<String, dynamic>> reminderSettings(String childId) async => {
    'enabled': enabled,
    'quiet_start': start,
    'quiet_end': end,
  };
  @override
  Future<void> saveReminderSettings(
    String childId,
    bool enabled,
    String start,
    String end, {
    bool Function()? canConfigure,
  }) async {
    if (canConfigure?.call() == false) throw StateError('PIN expired');
    saves++;
    this.enabled = enabled;
    this.start = start;
    this.end = end;
    if (loseReply) {
      loseReply = false;
      throw const SocketException('reply lost');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> loadReminders(String childId) async => [];
}

class ParentDevice extends Fake implements ParentNotificationDevice {
  @override
  Future<bool> isParentMode(String family) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('settings and receipts retire old plans', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({
        'task_notifications_enabled': true,
      });
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final operation in ['settings', 'receipt']) {
      test(
        '$operation fences late loads and offline cache after lost write reply',
        () async {
          final backend = MockSupabase();
          addTearDown(backend.close);
          await backend.signIn();
          final store = OfflineStore(NativeDatabase.memory());
          addTearDown(store.close);
          final tasks = CacheTasks(store, backend);
          addTearDown(tasks.dispose);
          final plugin = FakeNotifications();
          final activeScheduler = schedulerFor(plugin);
          final providers = ProviderContainer(
            overrides: [
              taskRepositoryProvider.overrideWithValue(tasks),
              notificationSchedulerProvider.overrideWithValue(activeScheduler),
            ],
          );
          addTearDown(providers.dispose);
          final repository = providers.read(scheduleRepositoryProvider);
          final old = reminder('old', 60);
          await activeScheduler.setScope('child');
          await activeScheduler.synchronize('child', [old]);
          backend.handle = (request) => MockSupabase.json(request, [old]);
          await repository.loadReminders('child');
          final entered = Completer<void>(), release = Completer<void>();
          backend.handle = (request) async {
            if (request.url.path.endsWith('load_task_reminders')) {
              entered.complete();
              await release.future;
              return MockSupabase.json(request, [old]);
            }
            expect(
              plugin.pending,
              isEmpty,
              reason: 'clear before sending the write',
            );
            expect(
              await store.read(MockSupabase.firstUser, 'reminders:child'),
              isNull,
            );
            expect(MockSupabase.body(request)['child_id'], 'child');
            if (operation == 'settings') {
              expect(MockSupabase.body(request)['enabled'], false);
            } else {
              expect(MockSupabase.body(request)['reminder_key'], 'old');
            }
            throw const SocketException('committed but reply lost');
          };
          final late = repository.loadReminders('child');
          final lateRejected = expectLater(late, throwsStateError);
          await entered.future;
          await expectLater(
            operation == 'settings'
                ? repository.saveReminderSettings(
                    'child',
                    false,
                    '21:00',
                    '07:00',
                  )
                : repository.acknowledge('child', 'old'),
            throwsA(isA<SocketException>()),
          );
          release.complete();
          await lateRejected;
          backend.handle = (_) => throw const SocketException('offline');
          final restarted = ScheduleRepository(backend.client, offline: tasks);
          await expectLater(
            restarted.loadReminders('child'),
            throwsA(isA<SocketException>()),
          );
          expect(plugin.pending, isEmpty);
          backend.handle = (request) => MockSupabase.json(request, []);
          expect(await restarted.loadReminders('child'), isEmpty);
        },
      );
    }

    test(
      'scope cancellation preserves other children and parent remote registration',
      () async {
        final plugin = FakeNotifications();
        final scopes = <String?>[];
        final tasks = task_push.Harness();
        await tasks.push.initialize();
        // Reuse the iOS adapter so the test exercises the production scope queue.
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final scheduler = LocalNotificationScheduler(
          plugin: plugin,
          remoteTaskPush: () => tasks.push,
          onScopeChanged: (scope) async {
            scopes.add(scope);
            await tasks.push.setScope(scope);
          },
        );
        await scheduler.setScope(task_push.sibling);
        await scheduler.synchronize(task_push.sibling, [
          reminder(task_push.sibling, 60),
        ]);
        await scheduler.cancelTaskReminders(task_push.child);
        expect(tasks.native.slots, hasLength(1));
        await scheduler.setScope('parent:owner:family');
        await scheduler.showParentMessages('parent:owner:family', {'weekly'});
        final oldScopes = [...scopes];
        await scheduler.cancelTaskReminders(task_push.child);
        expect(plugin.pending, hasLength(1));
        expect(scopes, oldScopes);
        await scheduler.setScope(task_push.child);
        final stale = scheduler.synchronize(task_push.child, [
          reminder('old', 60),
        ]);
        await scheduler.cancelTaskReminders(task_push.child);
        await stale;
        expect(plugin.pending, isEmpty);
        await scheduler.setScope(task_push.child);
        await scheduler.synchronize(task_push.child, [reminder('retry', 60)]);
        plugin.failNextClear = true;
        await expectLater(
          scheduler.cancelTaskReminders(task_push.child),
          throwsStateError,
        );
        expect(tasks.native.slots, isEmpty);
        await scheduler.cancelTaskReminders(task_push.child);
        expect(plugin.pending, isEmpty);
      },
    );

    test(
      'failed native clear, expired PIN and changed account prevent settings write',
      () async {
        final backend = MockSupabase();
        addTearDown(backend.close);
        await backend.signIn();
        var clears = 0, authorized = true, fail = true, changeOwner = false;
        final repo = ScheduleRepository(
          backend.client,
          beforeReminderChange: (_) async {
            clears++;
            if (fail) throw StateError('native clear failed');
            if (changeOwner) {
              await backend.signIn(MockSupabase.secondUser);
            } else {
              authorized = false;
            }
          },
        );
        Future<void> save() => repo.saveReminderSettings(
          'child',
          false,
          '21:00',
          '07:00',
          canConfigure: () => authorized,
        );
        await expectLater(
          repo.saveReminderSettings('child', false, '25:00', '07:00'),
          throwsFormatException,
        );
        expect(clears, 0);
        await expectLater(save(), throwsStateError);
        fail = false;
        await expectLater(save(), throwsStateError);
        expect(backend.calls, isEmpty);
        authorized = true;
        changeOwner = true;
        await expectLater(save(), throwsStateError);
        expect(backend.calls, isEmpty);
      },
    );

    test(
      'settings read rejects a late response from the previous account',
      () async {
        final backend = MockSupabase();
        addTearDown(backend.close);
        await backend.signIn();
        final repo = ScheduleRepository(backend.client);
        final entered = Completer<void>(), release = Completer<void>();
        backend.handle = (request) async {
          entered.complete();
          await release.future;
          return MockSupabase.json(request, {
            'enabled': true,
            'quiet_start': '21:00',
            'quiet_end': '07:00',
          });
        };
        final read = repo.reminderSettings('child');
        final rejected = expectLater(read, throwsStateError);
        await entered.future;
        await backend.signIn(MockSupabase.secondUser);
        release.complete();
        await rejected;
      },
    );
  });

  Future<void> open(
    WidgetTester tester,
    SettingsRepository repo,
    FakeScheduler scheduler, {
    bool parentDevice = false,
    StateProvider<String?>? auth,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
          scheduleRepositoryProvider.overrideWithValue(repo),
          notificationSchedulerProvider.overrideWithValue(scheduler),
          parentNotificationDeviceProvider.overrideWithValue(
            parentDevice ? ParentDevice() : null,
          ),
          activeParentFamilyProvider.overrideWith(
            (ref) => auth == null ? 'family' : ref.watch(auth),
          ),
          schedulesProvider.overrideWith(
            (ref, id) async => ScheduleSnapshot(
              childId: id,
              familyId: 'family',
              fetchedAt: DateTime.utc(2026, 11, 5),
              familyToday: '2026-11-05',
              items: [],
            ),
          ),
          remindersProvider.overrideWith((ref, id) async => []),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const ScheduleManagementScreen(
            childId: 'child',
            familyId: 'family',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('提醒设置'));
    await tester.pumpAndSettle();
    expect(find.byType(ReminderSettingsDialog), findsOneWidget);
  }

  testWidgets(
    'settings validate in place and reconcile unknown saves before editing',
    (tester) async {
      final repo = SettingsRepository()..loseReply = true;
      final scheduler = FakeScheduler();
      await open(tester, repo, scheduler);
      await tester.enterText(
        find.widgetWithText(TextFormField, '静默开始 HH:mm'),
        '25:00',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 HH:mm，例如 21:00'), findsOneWidget);
      expect(repo.saves, 0);
      await tester.enterText(
        find.widgetWithText(TextFormField, '静默开始 HH:mm'),
        '20:30',
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存结果尚未确认'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(repo.enabled, isFalse);
      await tester.tap(find.text('重新读取设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已读取服务器当前设置'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('重试本机提醒'));
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
      expect(scheduler.syncs, 1);
      expect(find.text('设置已确认，本机提醒已更新。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local scheduling retry does not repeat a confirmed settings write',
    (tester) async {
      final repo = SettingsRepository();
      final scheduler = FakeScheduler()..failSync = true;
      await open(tester, repo, scheduler);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('设置已保存，本机提醒尚未更新'), findsOneWidget);
      scheduler.failSync = false;
      await tester.tap(find.text('重试本机提醒'));
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
      expect(scheduler.syncs, 2);
    },
  );

  testWidgets(
    'PIN expiry blocks editing and saving; parent mode preserves local scope',
    (tester) async {
      final auth = StateProvider<String?>((ref) => 'family');
      final repo = SettingsRepository(), scheduler = FakeScheduler();
      await open(tester, repo, scheduler, parentDevice: true, auth: auth);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReminderSettingsDialog)),
      );
      container.read(auth.notifier).state = null;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(repo.saves, 0);
      container.read(auth.notifier).state = 'family';
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
      expect(scheduler.syncs, 0);
      expect(find.textContaining('此设备继续接收家长消息'), findsOneWidget);
    },
  );

  testWidgets('settings remain accessible at 360px and double text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, SettingsRepository(), FakeScheduler(), textScale: 2);
    await tester.ensureVisible(find.text('静默结束 HH:mm'));
    await tester.pumpAndSettle();
    expect(find.text('保存').hitTestable(), findsOneWidget);
    expect(find.text('关闭').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

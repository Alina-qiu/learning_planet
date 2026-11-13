import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/domain/task_priority.dart';
import 'package:learning_planet/features/tasks/domain/task_state_machine.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/tasks/presentation/task_presentation.dart';
import 'package:learning_planet/features/tasks/presentation/reminder_coordinator.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'review_module_test.dart' show FakeReviewRepository;
import 'widget_test.dart' show FakeTaskRepository;

TaskItem task({
  String id = 'task',
  TaskStatus status = TaskStatus.inProgress,
  TaskPriority priority = TaskPriority.mandatory,
}) => TaskItem(
  id: id,
  childId: 'child',
  title: '按自己的节奏完成今天的阅读练习',
  status: status,
  coinReward: 10,
  xpReward: 20,
  dueDate: DateTime(2026, 9, 16),
  accumulatedSeconds: 30,
  minimumSeconds: 60,
  expectedMinutes: 20,
  priority: priority,
  templateId: 'template',
  scheduledAt: DateTime.utc(2026, 9, 16, 8),
  dueAt: DateTime.utc(2026, 9, 16, 12),
);

class AbandonTasks extends FakeTaskRepository {
  TaskItem current = task();
  int abandoned = 0;
  @override
  Future<List<TaskItem>> loadTasks(String childId) async => [current];
  @override
  Future<void> abandon(String taskId) async {
    abandoned++;
    current = TaskItem.fromJson({
      ...current.toJson(),
      'status': 'abandoned',
      'active_started_at': null,
    });
  }
}

class DeniedSchedules extends ScheduleRepository {
  DeniedSchedules(super.client);
  @override
  Future<List<Map<String, dynamic>>> loadReminders(String childId) async {
    throw const PostgrestException(message: 'Denied', code: '42501');
  }
}

class RecordedNotifications implements NotificationScheduler {
  final scheduled = <List<Map<String, dynamic>>>[];
  final scopes = <String?>[];
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> setScope(String? childId) async {
    scopes.add(childId);
  }

  @override
  Future<void> synchronize(
    String childId,
    List<Map<String, dynamic>> reminders,
  ) async {
    scheduled.add(reminders);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'task ordering uses day and priority, moves terminal work last and retains snapshots across cache serialization',
    () {
      final required = task();
      final recommended = task(
        id: 'recommended',
        priority: TaskPriority.recommended,
      );
      final challenge = task(id: 'challenge', priority: TaskPriority.challenge);
      final old = TaskItem.fromJson({
        ...challenge.toJson(),
        'id': 'old',
        'due_date': '2026-09-15',
      });
      final abandoned = task(id: 'abandoned', status: TaskStatus.abandoned);
      expect(
        TaskItem.ordered([
          abandoned,
          challenge,
          recommended,
          required,
          old,
        ]).map((t) => t.id),
        ['old', 'task', 'recommended', 'challenge', 'abandoned'],
      );
      final loaded = TaskItem.fromJson(
        jsonDecode(jsonEncode(required.toJson())) as Map<String, dynamic>,
      );
      expect(loaded.toJson(), required.toJson());
      final legacy = {...challenge.toJson()}
        ..remove('task_priority')
        ..remove('expected_minutes');
      legacy['task_kind'] = 'challenge';
      expect(TaskItem.fromJson(legacy).priority, TaskPriority.challenge);
      expect(TaskItem.fromJson(legacy).expectedMinutes, isNull);
      expect(
        taskWindow(loaded, 'Asia/Shanghai'),
        '建议开始 9/16 16:00 · 截止 9/16 20:00（Asia/Shanghai）',
      );
      expect(taskWindow(loaded, 'America/New_York'), contains('9/16 04:00'));
    },
  );

  test(
    'target duration bounds and minimum are enforced without priority reward multipliers',
    () {
      ScheduleConfig config(int minutes, TaskPriority priority) =>
          ScheduleConfig(
            title: '阅读',
            startsOn: DateTime(2026, 9, 16),
            endsOn: DateTime(2026, 9, 17),
            recurrence: ScheduleRecurrence.daily,
            startTime: '16:00',
            dueTime: '20:00',
            expectedMinutes: minutes,
            minimumMinutes: 10,
            priority: priority,
            coins: 10,
            xp: 20,
          );
      for (final priority in TaskPriority.values) {
        final data = config(20, priority).toJson();
        expect(data['priority'], priority.value);
        expect(data['coins'], 10);
        expect(data['xp'], 20);
      }
      for (final minutes in [0, 9, 1441]) {
        expect(
          () => config(minutes, TaskPriority.mandatory).toJson(),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'abandonment freezes accumulated duration and cannot undo completed work',
    () {
      const machine = TaskStateMachine();
      final start = DateTime.utc(2026, 9, 16);
      final state = machine.start(
        const TaskTimingState(status: TaskStatus.ready),
        start,
      );
      final abandoned = machine.abandon(
        state,
        start.add(const Duration(seconds: 45)),
      );
      expect(
        abandoned.elapsedAt(start.add(const Duration(hours: 1))),
        const Duration(seconds: 45),
      );
      expect(machine.abandon(abandoned, start), same(abandoned));
      expect(() => machine.resume(abandoned, start), throwsStateError);
      expect(
        () => machine.abandon(
          const TaskTimingState(status: TaskStatus.completed),
          start,
        ),
        throwsStateError,
      );
    },
  );

  group('reminder cache and pending abandonment', () {
    late OfflineStore store;
    late OfflineTaskRepository offline;
    late FakeTaskRemote remote;
    late SupabaseClient client;
    late ScheduleRepository schedules;
    String? owner;
    var online = true, forbidden = false;
    Completer<void>? barrier;
    final day = DateTime.utc(2026, 9, 16, 8);
    Map<String, dynamic> entry(
      String title,
      String? id,
      String template,
      String date,
    ) => {
      'title': title,
      'task_id': id,
      'template_id': template,
      'due_date': date,
    };
    late List<Map<String, dynamic>> rows;
    setUp(() async {
      owner = 'user';
      online = true;
      forbidden = false;
      barrier = null;
      store = OfflineStore(NativeDatabase.memory());
      remote = FakeTaskRemote(() => day)..seed('child');
      remote.tasks['task-child']!['template_id'] = 'template';
      offline = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => owner,
        clock: () => day,
        autoSync: false,
      )..setForeground(false);
      await offline.loadTasks('child');
      rows = [
        {
          'reminder_key': 'today',
          'titles': '阅读、算术',
          'tasks': [
            entry('阅读', 'task-child', 'template', '2026-09-16'),
            entry('算术', 'other', 'other-template', '2026-09-16'),
          ],
        },
        {
          'reminder_key': 'tomorrow',
          'titles': '阅读',
          'tasks': [entry('阅读', null, 'template', '2026-09-17')],
        },
        {
          'reminder_key': 'template-today',
          'titles': '阅读',
          'tasks': [entry('阅读', null, 'template', '2026-09-16')],
        },
      ];
      client = SupabaseClient(
        'https://local.test',
        'test-key',
        httpClient: MockClient((request) async {
          await barrier?.future;
          if (forbidden) {
            return http.Response(
              jsonEncode({'code': '42501', 'message': 'Denied'}),
              403,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }
          if (!online) throw const SocketException('offline');
          return http.Response(
            jsonEncode(rows),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      schedules = ScheduleRepository(client, offline: offline);
    });
    tearDown(() async {
      await offline.dispose();
      await store.close();
      await client.dispose();
    });

    test(
      'offline abandonment removes only its merged entries and conflict restores the cached slot',
      () async {
        expect((await schedules.loadReminders('child')).length, 3);
        online = false;
        remote.online = false;
        await offline.abandon('task-child');
        final filtered = await schedules.loadReminders('child');
        expect(filtered.map((r) => r['reminder_key']), ['today', 'tomorrow']);
        expect(filtered.first['titles'], '算术');
        expect(filtered.last['titles'], '阅读');
        expect((await store.read('user', 'reminders:child'))!['items'], rows);
        remote.tasks['task-child']!.addAll({
          'status': 'paused',
          'sync_version': 99,
        });
        remote.online = true;
        await offline.synchronize('child');
        expect(offline.state.conflicts.length, 1);
        expect((await schedules.loadReminders('child')).length, 3);
        expect(
          (await schedules.loadReminders('child')).first['titles'],
          '算术、阅读',
        );
      },
    );

    test(
      'known permission denial purges reminders and a later network failure cannot resurrect them',
      () async {
        await schedules.loadReminders('child');
        forbidden = true;
        await expectLater(
          schedules.loadReminders('child'),
          throwsA(isA<PostgrestException>()),
        );
        expect(await store.read('user', 'reminders:child'), isNull);
        forbidden = false;
        online = false;
        await expectLater(
          schedules.loadReminders('child'),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test(
      'late response cannot repopulate reminders after account switch or child deletion',
      () async {
        barrier = Completer<void>();
        final pending = schedules.loadReminders('child');
        final assertion = expectLater(pending, throwsStateError);
        owner = 'other';
        barrier!.complete();
        await assertion;
        expect(await store.read('user', 'reminders:child'), isNull);
        owner = 'user';
        barrier = null;
        await schedules.loadReminders('child');
        await store.write('user', 'reminders:sibling', {'items': rows});
        await store.removeChildData('child');
        expect(await store.read('user', 'reminders:child'), isNull);
        expect(await store.read('user', 'reminders:sibling'), isNotNull);
        await expectLater(schedules.loadReminders('child'), throwsStateError);
        expect(await store.read('user', 'reminders:child'), isNull);
      },
    );
  });

  testWidgets(
    'narrow task screen supports cancel and confirmed abandonment with no overflowing actions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = AbandonTasks();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(repository),
            activeParentFamilyProvider.overrideWithValue('family'),
            familiesProvider.overrideWith(
              (ref) async => [
                const Family(
                  id: 'family',
                  name: '家',
                  timezone: 'Asia/Shanghai',
                  children: [],
                ),
              ],
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const TaskManagementScreen(
              childId: 'child',
              childNickname: '星宝',
              familyId: 'family',
              isParentMode: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('必须'), findsOneWidget);
      expect(find.textContaining('目标 20 分钟'), findsOneWidget);
      await tester.tap(find.byTooltip('放弃任务'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('继续任务'));
      await tester.pumpAndSettle();
      expect(repository.abandoned, 0);
      await tester.tap(find.byTooltip('放弃任务'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('确认放弃'));
      await tester.pumpAndSettle();
      expect(repository.abandoned, 1);
      expect(find.text('已放弃'), findsOneWidget);
      expect(find.byTooltip('放弃任务'), findsNothing);
      expect(find.byTooltip('家长补签'), findsOneWidget);
      expect(find.textContaining('完成奖励 +10'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'known reminder access denial clears pending device notifications',
    (tester) async {
      final client = SupabaseClient(
        'https://local.test',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient(
          (request) async => http.Response('{}', 200, request: request),
        ),
      );
      final notifications = RecordedNotifications();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(
              SupabaseTaskRepository(client),
            ),
            tasksProvider.overrideWith((ref, id) async => []),
            remindersProvider.overrideWith((ref, id) async => []),
            scheduleRepositoryProvider.overrideWithValue(
              DeniedSchedules(client),
            ),
            notificationSchedulerProvider.overrideWithValue(notifications),
          ],
          child: const MaterialApp(
            home: ReminderCoordinator(
              childId: 'child',
              familyId: 'family',
              child: SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(notifications.scopes, contains(null));
      expect(notifications.scheduled.every((rows) => rows.isEmpty), isTrue);
      await tester.pumpWidget(const SizedBox());
      // SDK stream disposal needs the widget fake clock to drain microtasks.
      unawaited(client.dispose());
      await tester.pump();
    },
  );

  testWidgets(
    'pending local abandonment disables cached review controls and preserves submitted explanation',
    (tester) async {
      final repository = AbandonTasks()
        ..current = task(status: TaskStatus.abandoned);
      final review = FakeReviewRepository()
        ..status = 'in_progress'
        ..cached = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(repository),
            reviewRepositoryProvider.overrideWithValue(review),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const ReviewSessionScreen(taskId: 'task', childId: 'child'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('这次复习已放弃'), findsOneWidget);
      expect(find.text('放弃这次复习'), findsNothing);
      expect(find.text('暂停复习'), findsNothing);
      expect(find.text('完成复习并结算'), findsNothing);
      expect(review.transitionCalls, 0);
      expect(review.completionCalls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';

class FakeNotifications extends Fake
    implements FlutterLocalNotificationsPlugin {
  final pending = <int, PendingNotificationRequest>{};
  final bodies = <String?>[];
  int schedules = 0;
  bool failNextClear = false;
  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;
  @override
  Future<void> cancelAll() async {
    if (failNextClear) {
      failNextClear = false;
      throw StateError('temporary plugin error');
    }
    pending.clear();
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    pending.remove(id);
  }

  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => pending.values.toList();
  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    schedules++;
    bodies.add(body);
    pending[id] = PendingNotificationRequest(id, title, body, payload);
  }
}

Map<String, dynamic> reminder(String key, int minutes) => {
  'reminder_key': key,
  'remind_at': DateTime.now()
      .add(Duration(minutes: minutes))
      .toUtc()
      .toIso8601String(),
  'titles': 'PRIVATE CHILD TASK',
};
ScheduleConfig config({
  ScheduleRecurrence recurrence = ScheduleRecurrence.daily,
  List<int> weekdays = const [],
  bool plan = false,
  List<Map<String, num>> tiers = const [],
}) => ScheduleConfig(
  title: ' Reading ',
  startsOn: DateTime(2026, 9, 16),
  endsOn: DateTime(2026, 9, 30),
  recurrence: recurrence,
  startTime: '16:00',
  dueTime: '20:00',
  weekdays: weekdays,
  longPlan: plan,
  minimumMinutes: 5,
  tiers: tiers,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('序列化周期和有效时长，星期去重排序', () {
    final value = config(
      recurrence: ScheduleRecurrence.weekly,
      weekdays: [5, 1, 5],
    ).toJson();
    expect(value['title'], 'Reading');
    expect(value['minimum_seconds'], 300);
    expect((value['rule'] as Map)['weekdays'], [1, 5]);
  });
  test('每周缺少日期或越界星期均拒绝', () {
    expect(
      () => config(recurrence: ScheduleRecurrence.weekly).toJson(),
      throwsFormatException,
    );
    expect(
      () =>
          config(recurrence: ScheduleRecurrence.weekly, weekdays: [8]).toJson(),
      throwsFormatException,
    );
  });
  test('拒绝无效日期、一次性长期计划和低于基础的奖励档位', () {
    expect(() => parseScheduleDate('2026-02-30'), throwsFormatException);
    expect(
      () => config(recurrence: ScheduleRecurrence.once, plan: true).toJson(),
      throwsFormatException,
    );
    expect(
      () => config(
        plan: true,
        tiers: [
          {'minimum_rate': .7, 'coins': 1, 'xp': 1},
        ],
      ).toJson(),
      throwsFormatException,
    );
  });
  test('客户端开关不能替代服务端授权有效期', () async {
    final now = DateTime.utc(2026, 9, 16);
    final container = ProviderContainer(
      overrides: [
        authorizationClockProvider.overrideWith((ref) => Stream.value(now)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authorizationClockProvider.future);
    container.read(parentModeProvider.notifier).state = true;
    container.read(parentFamilyIdProvider.notifier).state = 'family-a';
    expect(container.read(activeParentFamilyProvider), isNull);
    container.read(parentAuthorizedUntilProvider.notifier).state = now.add(
      const Duration(minutes: 10),
    );
    expect(container.read(activeParentFamilyProvider), 'family-a');
    container.read(parentAuthorizedUntilProvider.notifier).state = now;
    expect(container.read(activeParentFamilyProvider), isNull);
  });
  group('本地系统通知', () {
    test('清理失败后可重试，不忽略残留通知', () async {
      final plugin = FakeNotifications()..failNextClear = true;
      plugin.pending[123] = const PendingNotificationRequest(
        123,
        'old',
        'old',
        null,
      );
      final scheduler = LocalNotificationScheduler(plugin: plugin);
      await expectLater(scheduler.setScope(null), throwsStateError);
      await scheduler.setScope(null);
      expect(plugin.pending, isEmpty);
    });
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({
        'task_notifications_enabled': true,
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    test('冷启动未登录时清理上次的通知', () async {
      final plugin = FakeNotifications();
      plugin.pending[123] = const PendingNotificationRequest(
        123,
        'old',
        'old',
        null,
      );
      await LocalNotificationScheduler(plugin: plugin).setScope(null);
      expect(plugin.pending, isEmpty);
    });
    test('重复同步不重复调度，正文不泄露儿童任务', () async {
      final plugin = FakeNotifications();
      final scheduler = LocalNotificationScheduler(plugin: plugin);
      await scheduler.setScope('a');
      final rows = [reminder('one', 60)];
      await scheduler.synchronize('a', rows);
      await scheduler.synchronize('a', rows);
      expect(plugin.schedules, 1);
      expect(plugin.bodies.single, isNot(contains('PRIVATE')));
    });
    test('完成或已读后取消通知', () async {
      final plugin = FakeNotifications();
      final scheduler = LocalNotificationScheduler(plugin: plugin);
      await scheduler.setScope('a');
      await scheduler.synchronize('a', [reminder('one', 60)]);
      await scheduler.synchronize('a', []);
      expect(plugin.pending, isEmpty);
    });
    test('孩子切换后拒绝旧孩子的延迟同步', () async {
      final plugin = FakeNotifications();
      final scheduler = LocalNotificationScheduler(plugin: plugin);
      await scheduler.setScope('a');
      final stale = scheduler.synchronize('a', [reminder('old', 60)]);
      await scheduler.setScope('b');
      await stale;
      await scheduler.synchronize('a', [reminder('old', 60)]);
      expect(plugin.pending, isEmpty);
      await scheduler.synchronize('b', [reminder('new', 60)]);
      expect(plugin.pending, hasLength(1));
    });
    test('不调度过去时间，最多 60 条', () async {
      final plugin = FakeNotifications();
      final scheduler = LocalNotificationScheduler(plugin: plugin);
      await scheduler.setScope('a');
      await scheduler.synchronize('a', [
        reminder('past', -1),
        for (var i = 0; i < 80; i++) reminder('key-$i', i + 1),
      ]);
      expect(plugin.pending, hasLength(60));
    });
  });
}

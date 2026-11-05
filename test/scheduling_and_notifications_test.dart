import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/task_alarm_backend.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';

class FakeAndroidNotifications extends Fake
    implements AndroidFlutterLocalNotificationsPlugin {
  bool enabled = true;
  @override
  Future<bool?> areNotificationsEnabled() async => enabled;
  @override
  Future<bool?> requestNotificationsPermission() async => enabled;
}

class FakeIosNotifications extends Fake
    implements IOSFlutterLocalNotificationsPlugin {
  bool enabled = true;
  @override
  Future<NotificationsEnabledOptions?> checkPermissions() async =>
      NotificationsEnabledOptions(
        isEnabled: enabled,
        isSoundEnabled: enabled,
        isAlertEnabled: enabled,
        isBadgeEnabled: false,
        isProvisionalEnabled: false,
        isCriticalEnabled: false,
        isProvidesAppNotificationSettingsEnabled: false,
      );
}

class FakeNotifications extends Fake
    implements FlutterLocalNotificationsPlugin {
  final android = FakeAndroidNotifications();
  final ios = FakeIosNotifications();
  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => T == AndroidFlutterLocalNotificationsPlugin
      ? android as T
      : T == IOSFlutterLocalNotificationsPlugin
      ? ios as T
      : null;
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
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    bodies.add(body);
    pending[id] = PendingNotificationRequest(id, title, body, payload);
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

class FakeTaskAlarms implements TaskAlarmBackend {
  FakeTaskAlarms(this.plugin);
  final FakeNotifications plugin;
  @override
  Future<void> clear() => plugin.cancelAll();
  @override
  Future<void> replace(List<Map<String, Object>> alarms) async {
    final desired = {for (final row in alarms) row['id'] as int: row};
    plugin.pending.removeWhere((id, _) => !desired.containsKey(id));
    for (final entry in desired.entries) {
      final payload = jsonEncode(entry.value);
      if (plugin.pending[entry.key]?.payload == payload) continue;
      plugin.schedules++;
      plugin.bodies.add('有学习任务需要关注，请打开应用查看。');
      plugin.pending[entry.key] = PendingNotificationRequest(
        entry.key,
        '学习星球 · 任务提醒',
        '有学习任务需要关注，请打开应用查看。',
        payload,
      );
    }
  }
}

LocalNotificationScheduler schedulerFor(FakeNotifications plugin) =>
    LocalNotificationScheduler(
      plugin: plugin,
      taskAlarms: FakeTaskAlarms(plugin),
    );

Map<String, dynamic> reminder(String key, int minutes) => {
  'reminder_key': key,
  'remind_at': DateTime.now()
      .add(Duration(minutes: minutes))
      .toUtc()
      .toIso8601String(),
  'titles': 'PRIVATE CHILD TASK',
  'delivery_policy': {
    'version': 'task-reminder-v1',
    'timezone': 'Asia/Shanghai',
    'quiet_start': '21:00:00',
    'quiet_end': '07:00:00',
  },
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
  test(
    'family revocation preserves another scope and retries failed clearing of its own scope',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'task_notifications_enabled': true,
      });
      final plugin = FakeNotifications(),
          active = schedulerFor(FakeNotifications());
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('child');
      await scheduler.synchronize('child', [reminder('task', 5)]);
      expect(plugin.pending, isNotEmpty);
      await scheduler.cancelFamilyAccess('parent', 'other-family', {
        'other-child',
      });
      expect(plugin.pending, isNotEmpty);
      plugin.failNextClear = true;
      await expectLater(
        scheduler.cancelFamilyAccess('parent', 'family', {'child'}),
        throwsStateError,
      );
      await scheduler.cancelFamilyAccess('parent', 'family', {'child'});
      expect(plugin.pending, isEmpty);
      await active.setScope('parent:other:family');
      await active.cancelFamilyAccess('parent', 'family', {});
    },
  );
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
    test('iOS家长提醒也检查当前系统权限，桌面不误报送达', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final plugin = FakeNotifications(),
          scheduler = schedulerFor(FakeNotifications());
      final iosScheduler = schedulerFor(plugin);
      await iosScheduler.setScope('parent');
      expect(
        await iosScheduler.showParentMessages('parent', {'weekly'}),
        isTrue,
      );
      plugin.ios.enabled = false;
      expect(
        await iosScheduler.showParentMessages('parent', {'weekly'}),
        isFalse,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await scheduler.setScope('desktop');
      expect(
        await scheduler.showParentMessages('desktop', {'weekly'}),
        isFalse,
      );
    });
    test('家长提醒清除孩子计划，合并固定文案并拒绝未知类别和旧范围', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('child');
      await scheduler.synchronize('child', [reminder('task', 5)]);
      expect(plugin.pending, isNotEmpty);
      await scheduler.setScope('parent:owner:family');
      expect(plugin.pending, isEmpty);
      expect(
        await scheduler.showParentMessages('parent:owner:family', {
          'redemption',
          'weekly',
          'sync',
        }),
        isTrue,
      );
      expect(plugin.pending.length, 3);
      expect(
        plugin.pending.values.every((n) => n.payload == 'parent_messages'),
        isTrue,
      );
      expect(plugin.bodies.join(), isNot(contains('PRIVATE')));
      final ids = plugin.pending.keys.toSet();
      await scheduler.showParentMessages('parent:owner:family', {'redemption'});
      expect(plugin.pending.keys.toSet(), ids);
      expect(
        await scheduler.showParentMessages('parent:owner:family', {
          'task_click',
        }),
        isFalse,
      );
      expect(await scheduler.showParentMessages('old', {'weekly'}), isFalse);
      plugin.android.enabled = false;
      expect(
        await scheduler.showParentMessages('parent:owner:family', {'weekly'}),
        isFalse,
      );
      await scheduler.setScope(null);
      expect(plugin.pending, isEmpty);
    });
    test('清理失败后可重试，不忽略残留通知', () async {
      final plugin = FakeNotifications()..failNextClear = true;
      plugin.pending[123] = const PendingNotificationRequest(
        123,
        'old',
        'old',
        null,
      );
      final scheduler = schedulerFor(plugin);
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
      await schedulerFor(plugin).setScope(null);
      expect(plugin.pending, isEmpty);
    });
    test('重复同步不重复调度，正文不泄露儿童任务', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('a');
      final rows = [reminder('one', 60)];
      await scheduler.synchronize('a', rows);
      await scheduler.synchronize('a', rows);
      expect(plugin.schedules, 1);
      expect(plugin.bodies.single, isNot(contains('PRIVATE')));
    });
    test('完成或已读后取消通知', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('a');
      await scheduler.synchronize('a', [reminder('one', 60)]);
      await scheduler.synchronize('a', []);
      expect(plugin.pending, isEmpty);
    });
    test('旧缓存缺少投递策略时清除现有提醒并提示联网更新', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('a');
      await scheduler.synchronize('a', [reminder('one', 60)]);
      final stale = reminder('two', 90)..remove('delivery_policy');
      await expectLater(scheduler.synchronize('a', [stale]), throwsStateError);
      expect(plugin.pending, isEmpty);
    });
    test('系统撤销授权后清理旧任务计划，恢复权限后按当前列表重建', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('child');
      await scheduler.synchronize('child', [reminder('old', 60)]);
      plugin.android.enabled = false;
      await scheduler.synchronize('child', [reminder('new', 90)]);
      expect(plugin.pending, isEmpty);
      expect(plugin.schedules, 1);
      plugin.android.enabled = true;
      await scheduler.synchronize('child', [reminder('new', 90)]);
      expect(plugin.pending.keys, [reminderNotificationId('child:new')]);
      expect(
        plugin.pending.containsKey(reminderNotificationId('child:old')),
        isFalse,
      );
    });
    test('iOS系统关闭权限后不保留旧任务计划', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('child');
      await scheduler.synchronize('child', [reminder('old', 60)]);
      plugin.ios.enabled = false;
      await scheduler.synchronize('child', [reminder('new', 90)]);
      expect(plugin.pending, isEmpty);
      expect(plugin.schedules, 1);
    });
    test('权限申请被拒绝会持久关闭并清除旧提醒', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('child');
      await scheduler.synchronize('child', [reminder('old', 60)]);
      plugin.android.enabled = false;
      expect(await scheduler.requestPermission(), isFalse);
      expect(plugin.pending, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'task_notifications_enabled',
        ),
        isFalse,
      );
      plugin.android.enabled = true;
      await scheduler.synchronize('child', [reminder('new', 90)]);
      expect(plugin.pending, isEmpty);
    });
    test('本机授权开关关闭时清理仍残留在插件中的计划', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('child');
      await scheduler.synchronize('child', [reminder('old', 60)]);
      await (await SharedPreferences.getInstance()).setBool(
        'task_notifications_enabled',
        false,
      );
      await scheduler.synchronize('child', [reminder('new', 90)]);
      expect(plugin.pending, isEmpty);
    });
    test('孩子切换后拒绝旧孩子的延迟同步', () async {
      final plugin = FakeNotifications();
      final scheduler = schedulerFor(plugin);
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
      final scheduler = schedulerFor(plugin);
      await scheduler.setScope('a');
      await scheduler.synchronize('a', [
        reminder('past', -1),
        for (var i = 0; i < 80; i++) reminder('key-$i', i + 1),
      ]);
      expect(plugin.pending, hasLength(60));
    });
  });
}

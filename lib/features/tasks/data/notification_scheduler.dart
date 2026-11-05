import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../domain/task_reminder_policy.dart';
import 'task_alarm_backend.dart';
import '../../../core/diagnostics/startup_timings.dart';

final notificationSchedulerProvider = Provider<NotificationScheduler>(
  (ref) => const DisabledNotificationScheduler(),
);
final notificationErrorProvider = StateProvider<String?>((ref) => null);

abstract interface class NotificationScheduler {
  Future<bool> requestPermission();
  Future<void> setScope(String? childId);
  Future<void> synchronize(
    String childId,
    List<Map<String, dynamic>> reminders,
  );
}

abstract interface class ParentMessageScheduler {
  Future<bool> showParentMessages(String scope, Set<String> kinds);
}

abstract interface class TaskReminderCancellation {
  /// Retire only the active child's plan; preserve another child's or the
  /// parent's notification scope, including its remote registration.
  Future<void> cancelTaskReminders(String childId);
}

abstract interface class FamilyReminderCancellation {
  Future<void> cancelFamilyAccess(
    String owner,
    String family,
    Set<String> childIds,
  );
}

class DisabledNotificationScheduler implements NotificationScheduler {
  const DisabledNotificationScheduler();
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> setScope(String? childId) async {}
  @override
  Future<void> synchronize(
    String childId,
    List<Map<String, dynamic>> reminders,
  ) async {}
}

int reminderNotificationId(String value) {
  var hash = 2166136261;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
  }
  return hash;
}

class LocalNotificationScheduler
    implements
        NotificationScheduler,
        ParentMessageScheduler,
        TaskReminderCancellation,
        FamilyReminderCancellation {
  LocalNotificationScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    TaskAlarmBackend? taskAlarms,
    this.onScopeChanged,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _taskAlarms = taskAlarms ?? MethodChannelTaskAlarms();
  final TaskAlarmBackend _taskAlarms;
  final Future<void> Function(String?)? onScopeChanged;
  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initialization;
  Future<void> _queue = Future.value();
  String? _scope;
  @override
  Future<void> cancelFamilyAccess(
    String owner,
    String family,
    Set<String> childIds,
  ) =>
      _scope == 'parent:$owner:$family' ||
          childIds.contains(_scope) ||
          (_scope == null && !_scopeInitialized)
      ? setScope(null)
      : Future.value();
  bool _scopeInitialized = false;
  bool _hasReceivedScope = false;
  int _version = 0;
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  Future<void> _initialize() => _initialization ??=
      () async {
        if (!_supported) return;
        measureStartupSync(StartupPhase.timezone, tzdata.initializeTimeZones);
        await measureStartup(
          StartupPhase.notificationPlugin,
          () => _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('ic_notification'),
              iOS: DarwinInitializationSettings(
                requestAlertPermission: false,
                requestSoundPermission: false,
                requestBadgePermission: false,
              ),
            ),
          ),
        );
      }().catchError((Object error) {
        _initialization = null;
        throw error;
      });
  Future<void> _serialize(Future<void> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _clearAll() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await measureStartup(StartupPhase.taskAlarmClear, _taskAlarms.clear);
    }
    await measureStartup(StartupPhase.notificationClear, _plugin.cancelAll);
  }

  @override
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    await _initialize();
    final granted = defaultTargetPlatform == TargetPlatform.android
        ? await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission()
        : await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: false);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('task_notifications_enabled', granted == true);
    if (granted != true) {
      await _serialize(_clearAll);
    }
    return granted == true;
  }

  Future<bool> _permissionGranted() async =>
      (defaultTargetPlatform == TargetPlatform.android
          ? await _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.areNotificationsEnabled()
          : (await _plugin
                    .resolvePlatformSpecificImplementation<
                      IOSFlutterLocalNotificationsPlugin
                    >()
                    ?.checkPermissions())
                ?.isEnabled) ==
      true;

  @override
  Future<void> setScope(String? childId) {
    if (_scopeInitialized && _scope == childId && childId != null) {
      return Future.value();
    }
    // Startup already suspended native delivery before restoring the account.
    // Its first empty local scope must not erase a valid persisted opt-in.
    final initialEmptyScope = !_hasReceivedScope && childId == null;
    _hasReceivedScope = true;
    _scopeInitialized = true;
    _scope = childId;
    _version++;
    final version = _version;
    final remoteFence = initialEmptyScope
        ? Future<void>.value()
        : onScopeChanged?.call(childId) ?? Future<void>.value();
    // Attach an error handler immediately while another local operation may
    // still own the queue; the queued await below still propagates the error.
    unawaited(remoteFence.catchError((Object _) {}));
    return _serialize(() async {
      await remoteFence;
      if (!_supported) return;
      await _initialize();
      await _clearAll();
    }).catchError((Object error) {
      if (_version == version) _scopeInitialized = false;
      throw error;
    });
  }

  @override
  Future<void> cancelTaskReminders(String childId) =>
      _scope == childId || (_scope == null && !_scopeInitialized)
      ? setScope(null)
      : Future<void>.value();

  @override
  Future<void> synchronize(
    String childId,
    List<Map<String, dynamic>> reminders,
  ) {
    final version = _version;
    return _serialize(() async {
      if (!_supported || _scope != childId || version != _version) return;
      await _initialize();
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getBool('task_notifications_enabled') != true ||
          !await _permissionGranted()) {
        // A system-settings change can revoke a previously granted permission.
        // Remove persisted alarms so a later grant cannot revive stale plans.
        await _clearAll();
        return;
      }
      final now = DateTime.now();
      final desired = <int, Map<String, dynamic>>{};
      // Reserve four of iOS's 64 pending slots. Never schedule past slots.
      for (final reminder in reminders) {
        final at = DateTime.parse(reminder['remind_at'] as String);
        if (!at.isAfter(now)) continue;
        var id = reminderNotificationId('$childId:${reminder['reminder_key']}');
        while (desired.containsKey(id)) {
          id = (id + 1) & 0x7fffffff;
        }
        desired[id] = reminder;
        if (desired.length == 60) break;
      }
      if (_scope != childId || version != _version) return;
      List<Map<String, Object>> alarms;
      try {
        alarms = [
          for (final entry in desired.entries)
            taskAlarmPayload(entry.key, entry.value),
        ];
      } catch (_) {
        await _clearAll();
        rethrow;
      }
      if (_scope != childId || version != _version) return;
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _taskAlarms.replace(alarms);
        return;
      }
      final pending = await _plugin.pendingNotificationRequests();
      final existing = {
        for (final notification in pending) notification.id: notification,
      };
      for (final id in existing.keys) {
        if (!desired.containsKey(id)) await _plugin.cancel(id: id);
      }
      for (final entry in desired.entries) {
        if (_scope != childId || version != _version) return;
        final payload = jsonEncode({
          'kind': 'task-reminder-v1',
          ...alarms.firstWhere((alarm) => alarm['id'] == entry.key),
        });
        if (existing[entry.key]?.payload == payload) continue;
        await _plugin.zonedSchedule(
          id: entry.key,
          title: '学习星球 · 任务提醒',
          body: '有学习任务需要关注，请打开应用查看。',
          scheduledDate: tz.TZDateTime.from(
            DateTime.parse(entry.value['remind_at'] as String),
            tz.UTC,
          ),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'learning_tasks',
              '学习任务',
              channelDescription: '任务开始与截止提醒',
              visibility: NotificationVisibility.private,
            ),
            iOS: DarwinNotificationDetails(threadIdentifier: 'learning_tasks'),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
        );
      }
    });
  }

  @override
  Future<bool> showParentMessages(String scope, Set<String> kinds) async {
    const messages = {
      'redemption': '有兑换申请待审批，请打开应用查看家长消息。',
      'weekly': '上周学习报告可以查看了，请打开应用查看家长消息。',
      'sync': '本机有同步问题需要关注，请打开同步中心查看。',
    };
    if (kinds.isEmpty || !kinds.every(messages.containsKey)) return false;
    final version = _version;
    var shown = false;
    await _serialize(() async {
      if (!_supported || _scope != scope || version != _version) return;
      await _initialize();
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getBool('task_notifications_enabled') != true) return;
      for (final kind in kinds) {
        if (!await _permissionGranted()) return;
        if (_scope != scope || version != _version) return;
        await _plugin.show(
          id: reminderNotificationId('parent:$scope:$kind'),
          title: '学习星球 · 家长消息',
          body: messages[kind],
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'learning_parents',
              '家长消息',
              channelDescription: '兑换申请、同步异常和周报',
              onlyAlertOnce: true,
              visibility: NotificationVisibility.private,
            ),
            iOS: DarwinNotificationDetails(),
          ),
          payload: 'parent_messages',
        );
      }
      shown = _scope == scope && version == _version;
    });
    return shown;
  }
}

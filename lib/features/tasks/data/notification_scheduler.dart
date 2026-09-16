import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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

class LocalNotificationScheduler implements NotificationScheduler {
  LocalNotificationScheduler({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initialization;
  Future<void> _queue = Future.value();
  String? _scope;
  bool _scopeInitialized = false;
  int _version = 0;
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  Future<void> _initialize() => _initialization ??=
      () async {
        if (!_supported) return;
        tzdata.initializeTimeZones();
        await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_notification'),
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestSoundPermission: false,
              requestBadgePermission: false,
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
    return granted == true;
  }

  @override
  Future<void> setScope(String? childId) {
    if (_scopeInitialized && _scope == childId) return Future.value();
    _scopeInitialized = true;
    _scope = childId;
    _version++;
    final version = _version;
    return _serialize(() async {
      if (!_supported) return;
      await _initialize();
      await _plugin.cancelAll();
    }).catchError((Object error) {
      if (_version == version) _scopeInitialized = false;
      throw error;
    });
  }

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
      if (preferences.getBool('task_notifications_enabled') != true) return;
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
          'child': childId,
          'key': entry.value['reminder_key'],
          'at': entry.value['remind_at'],
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
            iOS: DarwinNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
        );
      }
    });
  }
}

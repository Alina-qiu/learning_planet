import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:learning_planet/main.dart' as application;
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/task_alarm_backend.dart';

Map<String, dynamic> _reminder(String key, int minutes) => {
  'reminder_key': key,
  'remind_at': DateTime.now()
      .add(Duration(minutes: minutes))
      .toUtc()
      .toIso8601String(),
  'titles': 'SYNTHETIC_PRIVATE_TASK_DO_NOT_SHOW',
  'delivery_policy': {
    'version': 'task-reminder-v1',
    'timezone': 'UTC',
    'quiet_start': '00:00:00',
    'quiet_end': '00:00:00',
  },
};

Future<void> _seedNativeAlarm(FlutterLocalNotificationsPlugin plugin) =>
    plugin.zonedSchedule(
      id: 1900000001,
      title: '学习星球 · 测试记录',
      body: '仅用于本机测试',
      scheduledDate: tz.TZDateTime.now(tz.UTC).add(const Duration(hours: 2)),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('learning_tasks', '学习任务'),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'synthetic-stale-record',
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const granted = bool.fromEnvironment(
    'TEST_NOTIFICATIONS_GRANTED',
    defaultValue: true,
  );
  const keepForReboot = bool.fromEnvironment('TEST_KEEP_ALARMS_FOR_REBOOT');
  testWidgets('native notification scheduling and startup cleanup (granted=$granted)', (
    tester,
  ) async {
    final plugin = FlutterLocalNotificationsPlugin();
    final backend = MethodChannelTaskAlarms();
    final scheduler = LocalNotificationScheduler(
      plugin: plugin,
      taskAlarms: backend,
    );
    final preferences = await SharedPreferences.getInstance();
    final previous = preferences.getBool('task_notifications_enabled');
    final report = <String, dynamic>{
      'permission_granted': granted,
      'platform': 'Android API36 AOSP emulator',
      'backend': 'none',
      'qualifies_for_device_acceptance': false,
    };
    binding.reportData = report;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('本机提醒验证'))),
      );
      await scheduler.setScope('integration-child-a');
      final nativePermission = await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!
          .areNotificationsEnabled();
      expect(
        nativePermission,
        granted,
        reason:
            'Use the test script to set the emulator permission before launch.',
      );
      await preferences.setBool('task_notifications_enabled', true);
      final rows = [
        _reminder('past', -10),
        for (var i = 0; i < 80; i++) _reminder('future-$i', 60 + i),
      ];
      if (granted) {
        expect(await scheduler.requestPermission(), isTrue);
        await scheduler.synchronize('integration-child-a', rows);
        final scheduled = await backend.pending();
        expect(scheduled, hasLength(60));
        expect(
          scheduled.every(
            (item) => item.keys.toSet().difference({'id', 'at'}).isEmpty,
          ),
          isTrue,
        );
        expect(scheduled.toString(), isNot(contains('SYNTHETIC_PRIVATE_TASK')));
        await scheduler.synchronize('integration-child-a', rows);
        expect(
          (await backend.pending()).map((item) => item['id']).toSet(),
          scheduled.map((item) => item['id']).toSet(),
        );
        await scheduler.synchronize('integration-child-a', [rows[1]]);
        expect(await backend.pending(), hasLength(1));
        await expectLater(
          backend.replace([
            {
              'id': 7,
              'at': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch,
              'timezone': 'invalid/zone',
              'quiet_start': '00:00:00',
              'quiet_end': '00:00:00',
            },
          ]),
          throwsA(isA<PlatformException>()),
        );
        expect(await backend.pending(), isEmpty);
        await scheduler.synchronize('integration-child-a', [rows[1]]);
        expect(await backend.pending(), hasLength(1));
        report['invalid_replacement_retires_old_policy_and_can_retry'] = true;
        await scheduler.cancelTaskReminders('integration-child-other');
        expect(await backend.pending(), hasLength(1));
        await scheduler.cancelTaskReminders('integration-child-a');
        expect(await backend.pending(), isEmpty);
        await scheduler.synchronize('integration-child-a', rows);
        expect(await backend.pending(), isEmpty);
        await scheduler.setScope('integration-child-a');
        await scheduler.synchronize('integration-child-a', [rows[1]]);
        expect(await backend.pending(), hasLength(1));
        report['settings_cancellation_retires_only_current_child_scope'] = true;
        await scheduler.setScope('integration-child-b');
        await scheduler.synchronize('integration-child-a', rows);
        expect(await plugin.pendingNotificationRequests(), isEmpty);
        expect(await backend.pending(), isEmpty);
        report['schedule_dedup_limit_cancellation_scope'] = true;

        // Exercise real AlarmManager delivery. A quiet policy is deliberately
        // supplied for one pending alarm, modeling a delivery delayed into it.
        final now = DateTime.now().toUtc();
        String time(DateTime at) =>
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
        final at = now.add(const Duration(seconds: 5)).millisecondsSinceEpoch;
        await backend.replace([
          {
            'id': 1800000001,
            'at': at,
            'timezone': 'UTC',
            'quiet_start': '00:00:00',
            'quiet_end': '00:00:00',
          },
          {
            'id': 1800000002,
            'at': at,
            'timezone': 'UTC',
            'quiet_start': time(now.subtract(const Duration(minutes: 1))),
            'quiet_end': time(now.add(const Duration(minutes: 30))),
          },
        ]);
        final delivery = Stopwatch()..start();
        while ((await backend.pending()).isNotEmpty &&
            delivery.elapsed < const Duration(seconds: 60)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          await backend.pending(),
          isEmpty,
          reason:
              'The emulator did not deliver both inexact alarm broadcasts within 60 seconds.',
        );
        final delivered = await plugin.getActiveNotifications();
        expect(delivered.map((item) => item.id), [1800000001]);
        expect(delivered.single.body, '有学习任务需要关注，请打开应用查看。');
        report['receiver_quiet_gate_actual_delivery'] = true;

        await scheduler.setScope('integration-parent');
        expect(
          await scheduler.showParentMessages('integration-parent', {
            'weekly',
            'redemption',
          }),
          isTrue,
        );
        final active = await plugin.getActiveNotifications();
        expect(active, hasLength(2));
        expect(active.every((item) => item.title == '学习星球 · 家长消息'), isTrue);
        await scheduler.showParentMessages('integration-parent', {'weekly'});
        expect(
          (await plugin.getActiveNotifications())
              .map((item) => item.id)
              .toSet(),
          active.map((item) => item.id).toSet(),
        );
        report['native_parent_notifications_active'] = active
            .map(
              (item) => {'id': item.id, 'title': item.title, 'body': item.body},
            )
            .toList();
      } else {
        // Simulate persisted alarms created before the user revoked permission.
        await _seedNativeAlarm(plugin);
        expect(await plugin.pendingNotificationRequests(), hasLength(1));
        await scheduler.synchronize('integration-child-a', rows);
        expect(await plugin.pendingNotificationRequests(), isEmpty);
        expect(
          await scheduler.showParentMessages('integration-child-a', {'weekly'}),
          isFalse,
        );
        expect(await plugin.getActiveNotifications(), isEmpty);
        report['revoked_permission_clears_old_alarm_without_rescheduling'] =
            true;
      }

      await _seedNativeAlarm(plugin);
      expect(await plugin.pendingNotificationRequests(), hasLength(1));
      if (granted) {
        await backend.replace([
          {
            'id': 1800000003,
            'at': DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
            'timezone': 'UTC',
            'quiet_start': '00:00:00',
            'quiet_end': '00:00:00',
          },
        ]);
        expect(await backend.pending(), hasLength(1));
      }
      // Invoke the real production startup, not a direct scheduler.setScope.
      final app = await application.initializeApp();
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(find.text('调试版本尚未连接服务'), findsOneWidget);
      expect(await plugin.pendingNotificationRequests(), isEmpty);
      expect(await backend.pending(), isEmpty);
      expect(await plugin.getActiveNotifications(), isEmpty);
      report['production_startup_clears_pending_and_active_notifications'] =
          true;
      if (keepForReboot) {
        expect(granted, isTrue);
        // Production startup cleared the scope through another bridge instance.
        await backend.clear();
        await backend.replace([
          for (var i = 1; i <= 2; i++)
            {
              'id': 1800000010 + i,
              'at': DateTime.now()
                  .add(Duration(hours: i))
                  .millisecondsSinceEpoch,
              'timezone': 'Etc/UTC',
              'quiet_start': '00:00:00',
              'quiet_end': '00:00:00',
            },
        ]);
        expect(await backend.pending(), hasLength(2));
        report['future_alarms_retained_for_host_reboot_check'] = true;
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!keepForReboot ||
          report['future_alarms_retained_for_host_reboot_check'] != true) {
        await backend.clear();
      }
      await plugin.cancelAll();
      if (previous == null) {
        await preferences.remove('task_notifications_enabled');
      } else {
        await preferences.setBool('task_notifications_enabled', previous);
      }
    }
  });
}

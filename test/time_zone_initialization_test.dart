import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/economy/presentation/economy_text.dart';
import 'package:learning_planet/features/reports/data/family_activity_recorder.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'scheduling_and_notifications_test.dart'
    show FakeNotifications, schedulerFor;
import 'support/task_workload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'notification startup, the task repository and family activity share the loaded rules',
    () async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await schedulerFor(FakeNotifications()).setScope(null);
      final newYork = tz.getLocation('America/New_York');
      tz.setLocalLocation(newYork);
      final store = OfflineStore(NativeDatabase.memory());
      final tasks = OfflineTaskRepository(
        store: store,
        remote: FakeTaskRemote(DateTime.now),
        live: WorkloadTasks([]),
        accountId: () => workloadOwner,
        autoSync: false,
      );
      final activity = FamilyActivityRecorder(
        store: store,
        owner: () => workloadOwner,
        send: (_, _) async => {},
      );
      try {
        final display = EconomyTime('America/New_York');
        expect(display.format('2026-03-08T06:59:00Z'), '2026-03-08 01:59');
        expect(display.format('2026-03-08T07:00:00Z'), '2026-03-08 03:00');
        expect(tz.getLocation('America/New_York'), same(newYork));
        expect(tz.local, same(newYork));
      } finally {
        activity.dispose();
        await tasks.dispose();
        await store.close();
        tz.setLocalLocation(tz.UTC);
      }
    },
  );

  test(
    'a fresh isolate with a custom location still receives the full family zone database',
    () async {
      final preserved = await Isolate.run(() {
        final custom = tz.Location('Test/Family', [0], [0], [tz.TimeZone.UTC]);
        tz.timeZoneDatabase.add(custom);
        tz.setLocalLocation(custom);
        final display = EconomyTime('Asia/Shanghai');
        tz.timeZoneDatabase.clear();
        tz.timeZoneDatabase.add(custom);
        final restored = EconomyTime('America/Los_Angeles');
        return (
          display.format('2026-01-01T16:00:00Z'),
          restored.format('2026-01-01T00:00:00Z'),
          tz.getLocation('Australia/Sydney').name,
          identical(tz.timeZoneDatabase.locations[custom.name], custom),
          identical(tz.local, custom),
        );
      });
      expect(preserved, (
        '2026-01-02 00:00',
        '2025-12-31 16:00',
        'Australia/Sydney',
        true,
        true,
      ));
    },
  );
}

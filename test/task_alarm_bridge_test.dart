import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:learning_planet/features/tasks/data/task_alarm_backend.dart';
import 'package:learning_planet/features/tasks/domain/task_reminder_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(tz.initializeTimeZones);
  tearDown(
    () => messenger.setMockMethodCallHandler(
      MethodChannelTaskAlarms.channel,
      null,
    ),
  );
  test(
    'native payload contains only opaque ID, instant and family delivery policy',
    () {
      final value = taskAlarmPayload(7, {
        'remind_at': '2026-11-05T12:00:00Z',
        'titles': 'PRIVATE',
        'delivery_policy': {
          'version': 'task-reminder-v1',
          'timezone': 'Asia/Shanghai',
          'quiet_start': '21:00:00',
          'quiet_end': '07:00:00',
        },
      });
      expect(value.keys.toSet(), {
        'id',
        'at',
        'timezone',
        'quiet_start',
        'quiet_end',
      });
      expect(value['at'], DateTime.utc(2026, 11, 5, 12).millisecondsSinceEpoch);
      expect(
        () => taskAlarmPayload(7, {'remind_at': '2026-11-05T12:00:00Z'}),
        throwsStateError,
      );
      expect(
        () => taskAlarmPayload(7, {
          'remind_at': 'invalid',
          'delivery_policy': {},
        }),
        throwsStateError,
      );
    },
  );
  test('invalid timezone and quiet hours cannot bypass native checks', () {
    for (final invalid in [
      {'timezone': 'unknown/zone'},
      {'quiet_start': '25:00:00'},
      {'quiet_end': '07:00'},
      {'version': 'old'},
    ]) {
      expect(
        () => taskAlarmPayload(7, {
          'remind_at': '2026-11-05T12:00:00Z',
          'delivery_policy': {
            'version': 'task-reminder-v1',
            'timezone': 'UTC',
            'quiet_start': '21:00:00',
            'quiet_end': '07:00:00',
            ...invalid,
          },
        }),
        throwsA(anything),
      );
    }
  });
  test('PostgreSQL UTC alias becomes a supported native timezone', () {
    final value = taskAlarmPayload(8, {
      'remind_at': '2026-11-05T12:00:00Z',
      'delivery_policy': {
        'version': 'task-reminder-v1',
        'timezone': 'UTC',
        'quiet_start': '21:00:00',
        'quiet_end': '07:00:00',
      },
    });
    expect(value['timezone'], 'Etc/UTC');
  });
  test(
    'native bridge fences updates and reacquires a cleared scope after clock reset',
    () async {
      var revision = 3;
      String? failure;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(MethodChannelTaskAlarms.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'clear') return ++revision;
        if (call.method == 'pending') {
          return [
            {'id': 7, 'at': 8},
          ];
        }
        expect(call.arguments['revision'], revision);
        if (failure != null) {
          final code = failure!;
          failure = null;
          revision++;
          throw PlatformException(code: code);
        }
        return null;
      });
      final native = MethodChannelTaskAlarms();
      await native.replace([]);
      for (final code in ['alarm_scope_changed', 'task_alarms_unavailable']) {
        failure = code;
        await expectLater(
          native.replace([]),
          throwsA(isA<PlatformException>()),
        );
        await native.replace([]);
      }
      expect(await native.pending(), [
        {'id': 7, 'at': 8},
      ]);
      expect(calls.map((call) => call.method), [
        'clear',
        'replace',
        'replace',
        'clear',
        'replace',
        'replace',
        'clear',
        'replace',
        'pending',
      ]);
    },
  );
}

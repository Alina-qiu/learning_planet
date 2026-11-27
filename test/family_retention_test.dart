import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/data_management/domain/child_export.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/reports/data/family_activity_recorder.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/family_retention.dart';
import 'package:learning_planet/features/reports/domain/learning_report.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/presentation/reminder_coordinator.dart';
import 'learning_report_test.dart' show sample;
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'support/mock_supabase.dart';
import 'widget_test.dart' show FakeTaskRepository;

Map<String, dynamic> retention({
  String status = 'returned',
  bool mature = true,
}) => {
  'version': 'retention-v1',
  'family_id': 'family',
  'cohort_date': '2026-10-01',
  'timezone': 'America/New_York',
  'anchor_source': 'observed',
  'days': [
    {'offset': 1, 'date': '2026-10-02', 'mature': mature, 'status': status},
    {'offset': 7, 'date': '2026-10-08', 'mature': mature, 'status': status},
  ],
};
Map<String, dynamic> receipt(
  String family,
  List<String> moments,
  DateTime now, {
  bool complete = false,
}) => {
  'family_id': family,
  'server_time': now.toIso8601String(),
  'acknowledged': moments,
  'accepted': moments.length,
  'cohort_timezone': 'America/New_York',
  'complete': complete,
};

class _Reports implements ReportRepository {
  @override
  Future<LearningReport> load(ReportScope scope) async =>
      LearningReport({...sample().data, 'family_retention': retention()});
}

class _Recorder extends Mock implements FamilyActivityRecorder {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineStore store;
  late DateTime now;
  late Duration elapsed;
  late String? owner;
  late List<List<String>> uploads;
  late FamilyActivitySender sender;
  FamilyActivityRecorder recorder() => FamilyActivityRecorder(
    store: store,
    owner: () => owner,
    clock: () => now,
    elapsed: () => elapsed,
    send: (f, m) => sender(f, m),
  );
  Future<void> observe(
    FamilyActivityRecorder r, {
    bool current = true,
    String family = 'family',
    String timezone = 'America/New_York',
  }) => r.observe(family, timezone, isCurrent: () => current);
  void advance(Duration duration) {
    now = now.add(duration);
    elapsed += duration;
  }

  setUp(() {
    store = OfflineStore(NativeDatabase.memory());
    now = DateTime.utc(2026, 11, 1, 4, 30);
    elapsed = Duration.zero;
    owner = 'parent';
    uploads = [];
    sender = (f, m) async {
      uploads.add(List.of(m));
      return receipt(f, m, now);
    };
  });
  tearDown(() async => store.close());

  test(
    'foreground collection deduplicates a 25-hour family day and monotonic server time survives device clock changes',
    () async {
      final r = recorder();
      await observe(r);
      await observe(r);
      expect(uploads.length, 1);
      advance(const Duration(hours: 1));
      await observe(r);
      advance(const Duration(hours: 1));
      await observe(r);
      expect(
        uploads.length,
        1,
      ); // Both repeated 01:30 hours belong to November 1.
      final correct = now;
      now = DateTime.utc(2099);
      await observe(r);
      expect(uploads.length, 1);
      now = correct;
      advance(const Duration(hours: 22, minutes: 30));
      await observe(r);
      expect(uploads.length, 2);
      expect(uploads.last.single, '2026-11-02T05:00:00.000Z');
      await observe(r, current: false);
      expect(uploads.length, 2);
    },
  );

  test(
    'offline samples survive a real database close/reopen and a lost reply replays identical timestamps',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'learning-planet-retention-',
      );
      await store.close();
      store = OfflineStore(NativeDatabase(File('${dir.path}/activity.sqlite')));
      try {
        sender = (f, m) async {
          uploads.add(List.of(m));
          throw const SocketException('offline');
        };
        await observe(recorder());
        final original = uploads.single.single;
        await store.close();
        store = OfflineStore(
          NativeDatabase(File('${dir.path}/activity.sqlite')),
        );
        final r = recorder();
        advance(const Duration(days: 1, hours: 1));
        var lost = true;
        sender = (f, m) async {
          uploads.add(List.of(m));
          if (lost) throw TimeoutException('lost response');
          return receipt(f, m, now);
        };
        await observe(r);
        expect(uploads.last.first, original);
        expect(uploads.last.length, 2);
        final frozen = List.of(uploads.last);
        lost = false;
        advance(const Duration(minutes: 1));
        await observe(r);
        expect(uploads.last, frozen);
        expect(
          (await store.read(
            'parent',
            FamilyActivityRecorder.key('family'),
          ))!['samples'],
          isEmpty,
        );
      } finally {
        await store.close();
        store = OfflineStore(NativeDatabase.memory());
        final root = Directory.systemTemp.absolute.path;
        if (!dir.absolute.path.startsWith(
          '$root${Platform.pathSeparator}learning-planet-retention-',
        )) {
          throw StateError('Unexpected temporary path');
        }
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'seven-day outbox stays bounded through a long outage, while retry backoff does not suppress new daily samples',
    () async {
      sender = (f, m) async {
        uploads.add(List.of(m));
        throw const SocketException('offline');
      };
      final r = recorder();
      await observe(r);
      await observe(r);
      expect(uploads.length, 1);
      for (var i = 0; i < 20; i++) {
        advance(const Duration(days: 1));
        await observe(r);
      }
      final cached = (await store.read(
        'parent',
        FamilyActivityRecorder.key('family'),
      ))!;
      expect((cached['samples'] as List).length, lessThanOrEqualTo(8));
      expect((cached['seen'] as List).length, 9);
      for (final value in cached['samples'] as List) {
        expect(
          now.difference(DateTime.parse(value as String)).inDays,
          lessThanOrEqualTo(7),
        );
      }
    },
  );

  test(
    'bad receipts retain pending samples, denied membership clears them, completion stops collection',
    () async {
      sender = (f, m) async {
        uploads.add(List.of(m));
        return {...receipt(f, m, now), 'acknowledged': []};
      };
      final r = recorder();
      await observe(r);
      expect(
        (await store.read(
          'parent',
          FamilyActivityRecorder.key('family'),
        ))!['samples'],
        isNotEmpty,
      );
      advance(const Duration(minutes: 1));
      sender = (f, m) async =>
          throw const PostgrestException(message: 'denied', code: '42501');
      await observe(r);
      expect(
        await store.read('parent', FamilyActivityRecorder.key('family')),
        isNull,
      );
      advance(const Duration(minutes: 2));
      sender = (f, m) async {
        uploads.add(List.of(m));
        return receipt(f, m, now, complete: true);
      };
      await observe(r);
      final count = uploads.length;
      advance(const Duration(days: 1));
      await observe(r);
      expect(uploads.length, count);
    },
  );

  test(
    'account changes and deletion during upload cannot rewrite deleted cache or another account records',
    () async {
      final sent = Completer<void>(),
          response = Completer<Map<String, dynamic>>();
      sender = (f, m) async {
        uploads.add(List.of(m));
        sent.complete();
        return response.future;
      };
      final r = recorder();
      final pending = observe(r);
      await sent.future;
      await store.removeChildData('deleted-child');
      response.complete(receipt('family', uploads.single, now));
      await pending;
      expect(
        await store.read('parent', FamilyActivityRecorder.key('family')),
        isNull,
      );
      sender = (f, m) async {
        owner = 'other';
        return receipt(f, m, now);
      };
      await observe(r);
      expect(
        await store.read('other', FamilyActivityRecorder.key('family')),
        isNull,
      );
      expect(
        (await store.read(
          'parent',
          FamilyActivityRecorder.key('family'),
        ))!['samples'],
        isNotEmpty,
      );
      await store.removeAccountData('parent', 'deletion');
      owner = 'parent';
      await observe(r);
      expect(
        await store.read('parent', FamilyActivityRecorder.key('family')),
        isNull,
      );
      owner = null;
      await observe(r);
    },
  );

  test(
    'future device times are discarded and the server clock permits a corrected foreground sample',
    () async {
      final server = now;
      now = now.add(const Duration(days: 3));
      sender = (f, m) async {
        uploads.add(List.of(m));
        return {...receipt(f, m, server), 'accepted': 0};
      };
      final r = recorder();
      await observe(r);
      sender = (f, m) async {
        uploads.add(List.of(m));
        return receipt(f, m, server);
      };
      await observe(r);
      expect(uploads.last.single, server.toIso8601String());
    },
  );

  test(
    'a timezone setting change refreshes the frozen cohort zone and a disposed recorder cannot restore cache',
    () async {
      final r = recorder();
      await observe(r);
      await observe(r, timezone: 'Asia/Shanghai');
      expect(uploads.length, 2);
      expect(
        (await store.read(
          'parent',
          FamilyActivityRecorder.key('family'),
        ))!['cohort_timezone'],
        'America/New_York',
      );
      r.dispose();
      advance(const Duration(days: 1));
      await observe(r);
      expect(uploads.length, 2);
    },
  );

  test(
    'ZIP builder accepts every current exported category including AI, parent receipts and shared retention',
    () {
      final names = exportSectionLabels.keys.toList();
      expect(names.length, 40);
      final bytes = buildChildExportZip({
        'manifest': {
          'id': 'export',
          'child_id': 'child',
          'schema_version': 1,
          'created_at': '2026-11-04T00:00:00Z',
          'sections': [
            for (final name in names)
              {
                'name': name,
                'columns': ['id'],
                'count': 0,
              },
          ],
        },
        'records': {for (final name in names) name: <Map<String, dynamic>>[]},
      });
      final zip = ZipDecoder().decodeBytes(bytes);
      for (final name in [
        'ai_question_origins',
        'ai_question_adoptions',
        'ai_feedback',
        'ai_report_feedback',
        'parent_notification_receipts',
        'family_retention',
        'family_activity_days',
      ]) {
        expect(zip.findFile('$name.csv'), isNotNull);
      }
      expect(zip.files.where((f) => f.name.endsWith('.csv')).length, 40);
    },
  );

  test(
    'real Supabase SDK provider sends only family and instants; report validation rejects a foreign family',
    () async {
      final api = MockSupabase();
      await api.signIn();
      final tasks = OfflineTaskRepository(
        store: store,
        remote: FakeTaskRemote(() => now),
        live: SupabaseTaskRepository(api.client),
        accountId: () => api.client.auth.currentUser?.id,
        autoSync: false,
      );
      final container = ProviderContainer(
        overrides: [taskRepositoryProvider.overrideWithValue(tasks)],
      );
      try {
        api.handle = (request) {
          final body = MockSupabase.body(request);
          expect(body.keys.toSet(), {'target_family_id', 'moments'});
          return MockSupabase.json(
            request,
            receipt(
              body['target_family_id'] as String,
              (body['moments'] as List).cast<String>(),
              DateTime.now().toUtc(),
            ),
          );
        };
        await observe(container.read(familyActivityRecorderProvider)!);
        expect(api.calls.single.url.path, endsWith('/record_family_activity'));
        api.handle = (request) => MockSupabase.json(request, {
          ...sample().data,
          'child_id': 'child',
          'period': 'day',
          'family_retention': {...retention(), 'family_id': 'foreign'},
        });
        await expectLater(
          SupabaseReportRepository(api.client).load((
            childId: 'child',
            familyId: 'family',
            period: 'day',
            endDate: null,
          )),
          throwsFormatException,
        );
      } finally {
        container.dispose();
        await tasks.dispose();
        await api.close();
      }
      final offline = ProviderContainer(
        overrides: [
          taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
        ],
      );
      expect(offline.read(familyActivityRecorderProvider), isNull);
      offline.dispose();
    },
  );

  test(
    'retention parsing preserves unknown, waiting, observed and missing data and rejects inconsistent dates or maturity',
    () {
      expect(sample().familyRetention, isNull);
      for (final status in [
        'returned',
        'not_observed',
        'collection_unknown',
        'historical_unknown',
        'pending',
        'collecting',
      ]) {
        final row = retention(
          status: status,
          mature: !['pending', 'collecting'].contains(status),
        );
        if (status == 'historical_unknown') row['anchor_source'] = 'legacy';
        expect(FamilyRetention.fromJson(row).days.first.label, isNotEmpty);
      }
      final noTask = {
        'version': 'retention-v1',
        'family_id': 'family',
        'cohort_date': null,
        'timezone': null,
        'anchor_source': 'observed',
        'days': [
          for (final offset in [1, 7])
            {
              'offset': offset,
              'date': null,
              'mature': false,
              'status': 'no_task',
            },
        ],
      };
      expect(FamilyRetention.fromJson(noTask).days.first.label, '尚未创建任务');
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (v) => v['version'] = 'other',
        (v) => v['cohort_date'] = '2026-02-30',
        (v) => (v['days'] as List).removeLast(),
        (v) => v['timezone'] = null,
        (v) => (v['days'] as List)[0]['date'] = '2026-10-03',
        (v) => (v['days'] as List)[0]['status'] = 'invented',
        (v) => (v['days'] as List)[0]['offset'] = 2,
        (v) {
          (v['days'] as List)[0]['status'] = 'not_observed';
          (v['days'] as List)[0]['mature'] = false;
        },
      ]) {
        final row = retention();
        mutation(row);
        expect(() => FamilyRetention.fromJson(row), throwsFormatException);
      }
    },
  );

  testWidgets(
    'coordinator records only foreground family activity and stops after lifecycle pause or disposal',
    (tester) async {
      final r = _Recorder();
      final calls = <String>[];
      when(
        () => r.observe(any(), any(), isCurrent: any(named: 'isCurrent')),
      ).thenAnswer((call) async {
        if ((call.namedArguments[#isCurrent] as bool Function())()) {
          calls.add(call.positionalArguments[0] as String);
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
            familyActivityRecorderProvider.overrideWithValue(r),
            tasksProvider.overrideWith((ref, id) async => []),
            remindersProvider.overrideWith((ref, id) async => []),
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
      expect(calls, isNotEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final before = calls.length;
      await tester.pump(const Duration(minutes: 2));
      expect(calls.length, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.length, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
      final disposed = calls.length;
      await tester.pump(const Duration(minutes: 1));
      expect(calls.length, disposed);
    },
  );

  testWidgets(
    'parent report shows family-specific observation dates at 360px and double text; PIN expiry removes data',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
            reportRepositoryProvider.overrideWithValue(_Reports()),
            familiesProvider.overrideWith((ref) async => []),
            parentModeProvider.overrideWith((ref) => true),
            parentFamilyIdProvider.overrideWith((ref) => 'family'),
            parentAuthorizedUntilProvider.overrideWith(
              (ref) => DateTime.now().add(const Duration(hours: 1)),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const LearningReportScreen(
              childId: 'child',
              familyId: 'family',
              childNickname: '小星',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('家庭回访'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('次日（2026-10-02）：已记录回访'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(parentAuthorizedUntilProvider.notifier).state = DateTime(
        2000,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('已记录回访'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

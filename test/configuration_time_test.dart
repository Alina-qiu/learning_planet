import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/presentation/getting_started_screen.dart';
import 'package:learning_planet/features/economy/presentation/reward_editor.dart';
import 'package:learning_planet/features/reports/data/configuration_time_recorder.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/configuration_session.dart';
import 'package:learning_planet/features/reports/domain/configuration_time.dart';
import 'package:learning_planet/features/reports/domain/learning_report.dart';
import 'package:learning_planet/features/reports/presentation/configuration_time_scope.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';
import 'learning_report_test.dart' show sample;
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'support/mock_supabase.dart';
import 'widget_test.dart' show FakeTaskRepository;

Map<String, dynamic> metrics({
  int ms = 15000,
  int samples = 1,
  int parents = 1,
}) => {
  'version': 'configuration-v1',
  'family_id': 'family',
  'milliseconds': ms,
  'samples': samples,
  'parents': parents,
  'retained_from': '2026-08-01T00:00:00Z',
  'partial_window': false,
};
Map<String, dynamic> ack(List<Map<String, dynamic>> events, DateTime now) => {
  'event_ids': events.map((e) => e['event_id']).toList(),
  'accepted': events.length,
  'server_time': now.toIso8601String(),
};

class _Store extends Mock implements OfflineStore {}

class _UiRecorder extends ConfigurationTimeRecorder {
  _UiRecorder(OfflineStore store)
    : super(
        store: store,
        owner: () => 'parent',
        clock: () => DateTime.utc(2026, 11, 4),
        send: (e) async => {},
      );
  final spans = <(ConfigurationRecordingScope, DateTime, DateTime)>[];
  @override
  Future<void> record(
    ConfigurationRecordingScope scope,
    DateTime start,
    DateTime end,
  ) async {
    spans.add((scope, start, end));
  }

  int get total =>
      spans.fold(0, (total, s) => total + s.$3.difference(s.$2).inMilliseconds);
}

class _Reports implements ReportRepository {
  @override
  Future<LearningReport> load(ReportScope scope) async =>
      LearningReport({...sample().data, 'configuration_time': metrics()});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'monotonic editing time excludes background, expired PIN and idle tails; input does not create per-keystroke records',
    () {
      var elapsed = Duration.zero;
      final spans = <(DateTime, DateTime)>[];
      final session = ConfigurationSession(
        startedAt: DateTime.utc(2026, 11, 4),
        elapsed: () => elapsed,
        onInterval: (a, b) => spans.add((a, b)),
      );
      for (var i = 1; i <= 100; i++) {
        elapsed = Duration(milliseconds: i * 100);
        session.activity();
      }
      expect(spans, isEmpty);
      elapsed = const Duration(seconds: 15);
      session.sample();
      expect(spans.single.$2.difference(spans.single.$1).inSeconds, 15);
      session.setForeground(false);
      elapsed = const Duration(seconds: 115);
      session.sample();
      expect(spans.length, 1);
      session.setForeground(true);
      elapsed = const Duration(seconds: 125);
      session.setEnabled(false);
      elapsed = const Duration(seconds: 225);
      session.sample();
      expect(spans.length, 2);
      session.setEnabled(true);
      elapsed = const Duration(seconds: 400);
      session.sample();
      expect(
        spans.fold<int>(0, (n, s) => n + s.$2.difference(s.$1).inSeconds),
        145,
      );
      session.activity();
      elapsed = const Duration(seconds: 410);
      session.close();
      expect(spans.last.$2.difference(spans.last.$1).inSeconds, 10);
      final count = spans.length;
      elapsed = const Duration(seconds: 500);
      session.activity();
      session.sample();
      session.close();
      expect(spans.length, count);
      expect(
        spans.every(
          (s) => s.$2.difference(s.$1) <= const Duration(seconds: 30),
        ),
        isTrue,
      );
    },
  );

  late OfflineStore store;
  late DateTime now;
  late Duration ticks;
  late String? actor;
  late ConfigurationSender sender;
  late List<List<Map<String, dynamic>>> requests;
  ConfigurationTimeRecorder recorder() => ConfigurationTimeRecorder(
    store: store,
    owner: () => actor,
    send: (e) => sender(e),
    clock: () => now,
    elapsed: () => ticks,
  );
  Future<void> edit(ConfigurationTimeRecorder r, {String child = 'child'}) =>
      r.record(
        r.capture(child, 'family', ConfigurationKind.task),
        now.subtract(const Duration(seconds: 15)),
        now,
      );
  void advance(Duration value) {
    now = now.add(value);
    ticks += value;
  }

  setUp(() {
    store = OfflineStore(NativeDatabase.memory());
    now = DateTime.utc(2026, 11, 4, 8);
    ticks = Duration.zero;
    actor = 'parent';
    requests = [];
    sender = (e) async {
      requests.add(e);
      return ack(e, now);
    };
  });
  tearDown(() async => store.close());
  test(
    'offline editing survives a real restart; lost reply preserves immutable event UUIDs and account isolation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-config-',
      );
      await store.close();
      store = OfflineStore(
        NativeDatabase(File('${directory.path}/config.sqlite')),
      );
      try {
        sender = (e) async {
          requests.add(e);
          throw const SocketException('offline');
        };
        await edit(recorder());
        final original = requests.single.single;
        await store.close();
        store = OfflineStore(
          NativeDatabase(File('${directory.path}/config.sqlite')),
        );
        final r = recorder();
        await r.flush();
        expect(requests.last.single, original);
        sender = (e) async {
          requests.add(e);
          return ack(e, now);
        };
        advance(const Duration(minutes: 1));
        await r.flush();
        expect(requests.last.single, original);
        expect(
          await store.read('parent', ConfigurationTimeRecorder.cacheKey),
          isNull,
        );
        actor = 'other';
        await r.flush();
        expect(requests.length, 3);
      } finally {
        await store.close();
        store = OfflineStore(NativeDatabase.memory());
        final root = Directory.systemTemp.absolute.path;
        if (!directory.absolute.path.startsWith(
          '$root${Platform.pathSeparator}learning-planet-config-',
        )) {
          throw StateError('Unexpected temporary directory');
        }
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'privacy barriers and account changes discard old recording scopes and cannot resurrect in-flight cache',
    () async {
      final r = recorder(), old = rScope(recorder());
      actor = 'other';
      await r.record(old, now.subtract(const Duration(seconds: 1)), now);
      expect(requests, isEmpty);
      actor = 'parent';
      final started = Completer<void>(),
          response = Completer<Map<String, dynamic>>();
      sender = (e) async {
        requests.add(e);
        started.complete();
        return response.future;
      };
      final pending = edit(r);
      await started.future;
      await store.removeChildData('child');
      response.complete(ack(requests.single, now));
      await pending;
      expect(
        await store.read('parent', ConfigurationTimeRecorder.cacheKey),
        isNull,
      );
      await edit(r);
      expect(requests.length, 1);
      await store.removeAccountData('parent', 'job');
      await edit(r, child: 'sibling');
      expect(
        await store.read('parent', ConfigurationTimeRecorder.cacheKey),
        isNull,
      );
      actor = null;
      await edit(r);
      r.dispose();
      actor = 'parent';
      await r.flush();
      expect(requests.length, 1);
    },
  );
  test(
    'bounded queue trims expired samples; foreground flush and backoff preserve intervals recorded during an upload',
    () async {
      final r = recorder();
      r.setForeground(false);
      await edit(r);
      expect(requests, isEmpty);
      final sent = Completer<void>(),
          response = Completer<Map<String, dynamic>>();
      sender = (e) async {
        requests.add(e);
        sent.complete();
        return response.future;
      };
      r.setForeground(true);
      await sent.future;
      final requestServerTime = now;
      advance(const Duration(seconds: 3));
      final second = edit(r);
      response.complete(ack(requests.single, requestServerTime));
      await second;
      expect(
        (await store.read(
          'parent',
          ConfigurationTimeRecorder.cacheKey,
        ))!['events'],
        hasLength(1),
      );
      sender = (e) async {
        requests.add(e);
        return {...ack(e, now), 'event_ids': []};
      };
      await r.flush();
      final calls = requests.length;
      await r.flush();
      expect(requests.length, calls);
      sender = (e) async {
        requests.add(e);
        return ack(e, now);
      };
      advance(const Duration(minutes: 1));
      await r.flush();
      expect(
        await store.read('parent', ConfigurationTimeRecorder.cacheKey),
        isNull,
      );
      final cached = List.generate(
        1010,
        (i) => {
          'event_id': const Uuid().v4(),
          'child_id': 'child',
          'family_id': 'family',
          'kind': 'rules',
          'started_at': now
              .subtract(Duration(seconds: i + 1))
              .toIso8601String(),
          'ended_at': now.subtract(Duration(seconds: i)).toIso8601String(),
        },
      );
      cached.add({
        ...cached.first,
        'event_id': const Uuid().v4(),
        'started_at': now.subtract(const Duration(days: 8)).toIso8601String(),
        'ended_at': now
            .subtract(const Duration(days: 8))
            .add(const Duration(seconds: 1))
            .toIso8601String(),
      });
      await store.write('parent', ConfigurationTimeRecorder.cacheKey, {
        'events': cached,
      });
      await r.flush();
      expect(
        (await store.read(
          'parent',
          ConfigurationTimeRecorder.cacheKey,
        ))!['events'],
        hasLength(950),
      );
      expect(requests.last.length, 50);
      final requestTime = now;
      sender = (events) async {
        advance(const Duration(seconds: 20));
        return ack(events, requestTime);
      };
      await r.flush();
      expect(
        r.now,
        now,
        reason: 'A delayed response cannot reset a monotonic clock',
      );
    },
  );
  test(
    'real SDK collector sends only bounded metadata and a foreign family report is rejected',
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
      final providers = ProviderContainer(
        overrides: [taskRepositoryProvider.overrideWithValue(tasks)],
      );
      try {
        api.handle = (request) {
          final body = MockSupabase.body(request);
          expect(body.keys, contains('events'));
          final events = (body['events'] as List).cast<Map<String, dynamic>>();
          expect(events.single.keys.toSet(), {
            'event_id',
            'child_id',
            'family_id',
            'kind',
            'started_at',
            'ended_at',
          });
          return MockSupabase.json(
            request,
            ack(events, DateTime.now().toUtc()),
          );
        };
        final r = providers.read(configurationTimeRecorderProvider)!;
        final instant = r.now;
        await r.record(
          r.capture('child', 'family', ConfigurationKind.rules),
          instant.subtract(const Duration(seconds: 5)),
          instant,
        );
        expect(
          api.calls.single.url.path,
          endsWith('/record_parent_configuration'),
        );
        api.handle = (request) => MockSupabase.json(request, {
          ...sample().data,
          'child_id': 'child',
          'period': 'day',
          'configuration_time': {...metrics(), 'family_id': 'wrong'},
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
        providers.dispose();
        await tasks.dispose();
        await api.close();
      }
    },
  );
  test(
    'report duration validates bounds, zero samples and version without inventing historic timing',
    () {
      expect(sample().configurationTime, isNull);
      expect(ConfigurationTime.fromJson(metrics()).label, '已记录0分15秒');
      expect(
        ConfigurationTime.fromJson(
          metrics(ms: 0, samples: 0, parents: 0),
        ).label,
        '暂无配置计时记录',
      );
      expect(ConfigurationTime.fromJson(metrics(ms: 1)).label, '已记录不足1秒');
      for (final change in [
        {'version': 'other'},
        {'milliseconds': -1},
        {'samples': 0},
        {'parents': 2},
        {'milliseconds': 30001},
        {'samples': 1.5},
      ]) {
        expect(
          () => ConfigurationTime.fromJson({...metrics(), ...change}),
          throwsFormatException,
        );
      }
    },
  );

  for (final editorName in ['task', 'reward', 'starter']) {
    final kind = editorName == 'task'
        ? ConfigurationKind.task
        : ConfigurationKind.rules;
    testWidgets(
      '$editorName editor pauses on lifecycle/PIN changes, accepts IME changes and stops at cancel before route animation',
      (tester) async {
        final fakeStore = _Store();
        when(() => fakeStore.privacyGeneration).thenReturn(0);
        final r = _UiRecorder(fakeStore);
        var tick = Duration.zero;
        final auth = StateProvider<String?>((ref) => 'family');
        final editor = switch (editorName) {
          'task' => ScheduleEditor(today: DateTime(2026, 11, 4)),
          'reward' => const RewardEditor(),
          _ => const StarterRulesEditor(
            data: {
              'child': {'starter_task_preset': 'study20'},
              'daily_limit': 100,
              'active_rewards': 0,
            },
          ),
        };
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              configurationTimeRecorderProvider.overrideWithValue(r),
              configurationElapsedProvider.overrideWithValue(() => tick),
              activeParentFamilyProvider.overrideWith((ref) => ref.watch(auth)),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ConfigurationTimeScope(
                          childId: 'child',
                          familyId: 'family',
                          kind: kind,
                          child: editor,
                        ),
                      ),
                    ),
                    child: const Text('edit'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('edit'));
        await tester.pumpAndSettle();
        tick = const Duration(seconds: 15);
        await tester.pump(const Duration(seconds: 15));
        expect(r.total, 15000);
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        tick = const Duration(seconds: 115);
        await tester.pump(const Duration(seconds: 100));
        expect(r.total, 15000);
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump();
        tick = const Duration(seconds: 125);
        final providers = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp)),
        );
        providers.read(auth.notifier).state = null;
        await tester.pump();
        expect(r.total, 25000);
        tick = const Duration(seconds: 225);
        await tester.pump(const Duration(seconds: 100));
        expect(r.total, 25000);
        providers.read(auth.notifier).state = 'family';
        await tester.pump();
        tick = const Duration(seconds: 350);
        await tester.enterText(find.byType(TextFormField).first, 'edit again');
        await tester.pump();
        tick = const Duration(seconds: 360);
        Navigator.of(tester.element(find.byType(ConfigurationTimeScope))).pop();
        await tester.pump();
        final closed = r.total;
        expect(closed, 155000);
        expect(
          r.spans.every((s) => s.$1.kind == kind && s.$1.child == 'child'),
          isTrue,
        );
        tick = const Duration(seconds: 400);
        await tester.pumpAndSettle();
        expect(r.total, closed);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'configuration report uses family context, visible missing-data wording and parent PIN protection at double text',
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
              childNickname: '星',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('家长配置用时'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('已记录0分15秒'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(parentAuthorizedUntilProvider.notifier).state = DateTime(
        2000,
      );
      await tester.pumpAndSettle();
      expect(find.text('已记录0分15秒'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

ConfigurationRecordingScope rScope(ConfigurationTimeRecorder r) =>
    r.capture('child', 'family', ConfigurationKind.task);

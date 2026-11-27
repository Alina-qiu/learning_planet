import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/data/schedule_snapshots.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/tasks/domain/schedule_snapshot.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';
import 'support/mock_supabase.dart';
import 'reminder_settings_test.dart' show CacheTasks;

Map<String, dynamic> scheduleRow({
  String id = 'template',
  String child = 'child',
  bool plan = true,
}) => {
  'id': id,
  'child_id': child,
  'title': '阅读计划 $id',
  'active': true,
  'created_at': '2026-11-05T00:00:00Z',
  'recurrence': 'daily',
  'starts_on': '2026-11-01',
  'ends_on': '2026-11-30',
  'start_time': '16:00',
  'due_time': '20:00',
  'coin_reward': 20,
  'xp_reward': 20,
  'minimum_seconds': 0,
  'long_plans': !plan
      ? null
      : {
          'id': 'plan-$id',
          'template_id': id,
          'minimum_rate': .8,
          'bonus_coins': 100,
          'bonus_xp': 80,
          'settled_at': null,
          'plan_leaves': [
            {'leave_date': '2026-11-02'},
          ],
          'progress': {'expected': 29, 'completed': 7, 'rate': 7 / 29},
          'plan_stage_rewards': [],
          'plan_bonus_tiers': [],
        },
};
Map<String, dynamic> schedulePage({
  List<Map<String, dynamic>>? items,
  Object? cursor,
  String child = 'child',
  String family = 'family',
}) => {
  'schema': 1,
  'child_id': child,
  'family_id': family,
  'family_today': '2026-11-05',
  'fetched_at': '2026-11-05T01:00:00Z',
  'items': items ?? [scheduleRow(child: child)],
  'next_cursor': cursor,
};

class ScreenSchedules extends Fake implements ScheduleRepository {
  ScheduleSnapshot value = ScheduleSnapshot.fromJson(schedulePage(), 'child');
  bool fail = false;
  int calls = 0, writes = 0;
  Completer<DateTime>? date;
  @override
  Future<ScheduleSnapshot> loadSchedules(String childId) async {
    calls++;
    if (fail) throw StateError('private server details');
    return value;
  }

  @override
  Future<DateTime> today(String childId) async =>
      date == null ? DateTime(2026, 11, 5) : await date!.future;
  @override
  Future<void> save(
    String childId,
    ScheduleConfig config, {
    String? templateId,
  }) async {
    writes++;
  }
}

Future<ProviderContainer> mountSchedules(
  WidgetTester tester,
  ScreenSchedules repository, {
  bool parent = false,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        scheduleRepositoryProvider.overrideWithValue(repository),
        remindersProvider.overrideWith((ref, child) async => []),
        activeParentFamilyProvider.overrideWith(
          (ref) => ref.watch(parentFamilyIdProvider),
        ),
        parentFamilyIdProvider.overrideWith((ref) => parent ? 'family' : null),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const ScheduleManagementScreen(
          childId: 'child',
          familyId: 'family',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(ScheduleManagementScreen)),
  );
}

void main() {
  late MockSupabase backend;
  setUp(() async {
    backend = MockSupabase();
    await backend.signIn();
    backend.handle = (r) => MockSupabase.json(r, schedulePage());
  });
  tearDown(() async {
    await backend.close();
  });
  test(
    'schedule reader walks keyset pages and combines progress without per-plan HTTP requests',
    () async {
      final repo = ScheduleSnapshots(backend.client);
      backend.handle = (r) {
        final params = MockSupabase.body(r);
        expect(r.url.path, '/rest/v1/rpc/task_schedule_page');
        expect(params['page_size'], 100);
        return MockSupabase.json(
          r,
          params['after_id'] == null
              ? schedulePage(
                  cursor: {
                    'created_at': '2026-11-05T00:00:00Z',
                    'id': 'template',
                  },
                )
              : schedulePage(items: [scheduleRow(id: 'older')]),
        );
      };
      final value = await repo.load('child');
      expect(value.items.map((r) => r['id']), ['template', 'older']);
      expect(value.offline, isFalse);
      expect(MockSupabase.body(backend.calls.last)['after_id'], 'template');
      expect(backend.calls.length, 2);
      expect(() => value.items.clear(), throwsUnsupportedError);
    },
  );
  test(
    'file database reopen restores only a complete previously synchronized child snapshot',
    () async {
      final dir = await Directory.systemTemp.createTemp('planet-schedules-');
      final file = File('${dir.path}/cache.db');
      var store = OfflineStore(NativeDatabase(file));
      try {
        await ScheduleSnapshots(backend.client, store: store).load('child');
        await store.close();
        store = OfflineStore(NativeDatabase(file));
        backend.handle = (_) => throw const SocketException('offline');
        final value = await ScheduleSnapshots(
          backend.client,
          store: store,
        ).load('child');
        expect(value.offline, isTrue);
        expect(value.items.single['long_plans']['progress']['completed'], 7);
        expect(value.fetchedAt, DateTime.utc(2026, 11, 5, 1));
        await expectLater(
          ScheduleSnapshots(backend.client, store: store).load('sibling'),
          throwsA(isA<SocketException>()),
        );
        await backend.signIn(MockSupabase.secondUser);
        await expectLater(
          ScheduleSnapshots(backend.client, store: store).load('child'),
          throwsA(isA<SocketException>()),
        );
      } finally {
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'second-page failure keeps the old complete snapshot and never caches a partial replacement',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final repo = ScheduleSnapshots(backend.client, store: store);
      await repo.load('child');
      backend.handle = (r) {
        if (MockSupabase.body(r)['after_id'] != null) {
          throw const SocketException('second page');
        }
        return MockSupabase.json(
          r,
          schedulePage(
            items: [scheduleRow(id: 'new')],
            cursor: {'created_at': '2026-11-05T00:00:00Z', 'id': 'new'},
          ),
        );
      };
      final value = await repo.load('child');
      expect(value.offline, isTrue);
      expect(value.items.single['id'], 'template');
      expect(
        (await store.read(
          MockSupabase.firstUser,
          'schedules:child',
        ))!['items'].single['id'],
        'template',
      );
    },
  );
  test(
    'permission errors erase cached schedules while malformed pages cannot become offline success',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final repo = ScheduleSnapshots(backend.client, store: store);
      await repo.load('child');
      for (final body in [
        schedulePage(child: 'other'),
        schedulePage(family: ''),
        schedulePage(items: [scheduleRow(), scheduleRow()]),
      ]) {
        backend.handle = (r) => MockSupabase.json(r, body);
        await expectLater(repo.load('child'), throwsFormatException);
      }
      backend.handle = (r) => MockSupabase.json(
        r,
        schedulePage(
          cursor: {'created_at': '2026-11-05T00:00:00Z', 'id': 'template'},
        ),
      );
      await expectLater(repo.load('child'), throwsFormatException);
      backend.handle = MockSupabase.denied;
      await expectLater(repo.load('child'), throwsA(isA<Exception>()));
      expect(
        await store.read(MockSupabase.firstUser, 'schedules:child'),
        isNull,
      );
      backend.handle = (_) => throw const SocketException('offline');
      await expectLater(repo.load('child'), throwsA(isA<SocketException>()));
    },
  );
  test(
    'account switches and privacy cleanup prevent late schedule replies from being cached',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final repo = ScheduleSnapshots(backend.client, store: store);
      for (final change in <Future<void> Function()>[
        () => backend.signIn(MockSupabase.secondUser),
        () async {
          store.privacyGeneration++;
        },
      ]) {
        final entered = Completer<void>(), release = Completer<http.Response>();
        backend.handle = (r) {
          entered.complete();
          return release.future;
        };
        final pending = expectLater(repo.load('child'), throwsStateError);
        await entered.future;
        await change();
        release.complete(MockSupabase.json(backend.calls.last, schedulePage()));
        await pending;
        expect(
          await store.read(MockSupabase.firstUser, 'schedules:child'),
          isNull,
        );
        expect(
          await store.read(MockSupabase.secondUser, 'schedules:child'),
          isNull,
        );
      }
    },
  );
  test(
    'newer list reads and schedule writes fence old replies before they can restore stale cached progress',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final repo = ScheduleSnapshots(backend.client, store: store);
      await repo.load('child');
      for (final write in [false, true]) {
        final entered = Completer<void>(), release = Completer<http.Response>();
        backend.handle = (r) {
          entered.complete();
          return release.future;
        };
        final pending = expectLater(repo.load('child'), throwsStateError);
        await entered.future;
        if (write) {
          await repo.change('child', () async {});
        } else {
          backend.handle = (r) => MockSupabase.json(
            r,
            schedulePage(items: [scheduleRow(id: 'latest')]),
          );
          await repo.load('child');
        }
        release.complete(MockSupabase.json(backend.calls.last, schedulePage()));
        await pending;
        final cached = await store.read(
          MockSupabase.firstUser,
          'schedules:child',
        );
        if (write) {
          expect(cached, isNull);
        } else {
          expect(cached!['items'].single['id'], 'latest');
        }
      }
    },
  );
  test(
    'child, membership and account cleanup erase schedule data and versions without clearing another scope',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final repo = ScheduleSnapshots(backend.client, store: store);
      for (final child in ['deleted', 'revoked', 'account', 'kept']) {
        backend.handle = (r) =>
            MockSupabase.json(r, schedulePage(child: child, family: child));
        await repo.load(child);
        await store.write(MockSupabase.firstUser, 'schedule-version:$child', {
          'value': 0,
        });
      }
      await store.removeChildData('deleted');
      expect(
        await store.read(MockSupabase.firstUser, 'schedules:deleted'),
        isNull,
      );
      expect(
        await store.read(MockSupabase.firstUser, 'schedule-version:deleted'),
        isNull,
      );
      await expectLater(repo.load('deleted'), throwsStateError);
      await store.applyFamilyAccess(MockSupabase.firstUser, [
        FamilyAccessState(
          familyId: 'revoked',
          version: 2,
          active: false,
          lastRevokedVersion: 2,
          childIds: {'revoked'},
        ),
      ]);
      expect(
        await store.read(MockSupabase.firstUser, 'schedules:revoked'),
        isNull,
      );
      expect(
        await store.read(MockSupabase.firstUser, 'schedules:kept'),
        isNotNull,
      );
      await expectLater(repo.load('revoked'), throwsStateError);
      await store.write(
        MockSupabase.secondUser,
        'schedules:kept',
        schedulePage(child: 'kept'),
      );
      await store.removeAccountData(MockSupabase.firstUser, 'job');
      await expectLater(repo.load('account'), throwsStateError);
      expect(
        await store.read(MockSupabase.secondUser, 'schedules:kept'),
        isNotNull,
      );
    },
  );
  test(
    'all schedule mutations invalidate persisted lists even when the response is lost',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final tasks = CacheTasks(store, backend);
      addTearDown(tasks.dispose);
      final repo = ScheduleRepository(backend.client, offline: tasks);
      final config = ScheduleConfig(
        title: 'Read',
        startsOn: DateTime(2026, 11, 5),
        endsOn: DateTime(2026, 11, 6),
        recurrence: ScheduleRecurrence.daily,
        startTime: '16:00',
        dueTime: '20:00',
      );
      for (final action in <Future<Object?> Function()>[
        () => repo.save('child', config),
        () => repo.setActive('child', 'template', false),
        () => repo.approveLeave('child', 'plan', DateTime(2026, 11, 5), 'Trip'),
        () => repo.settle('child', 'plan'),
      ]) {
        backend.handle = (r) => MockSupabase.json(r, schedulePage());
        await repo.loadSchedules('child');
        backend.handle = (_) => throw TimeoutException('reply lost');
        await expectLater(action(), throwsA(isA<TimeoutException>()));
        expect(
          await store.read(MockSupabase.firstUser, 'schedules:child'),
          isNull,
        );
        await expectLater(
          repo.loadSchedules('child'),
          throwsA(isA<TimeoutException>()),
        );
      }
      backend.handle = (r) => MockSupabase.json(
        r,
        r.url.path.endsWith('/settle_long_plan') ? .75 : null,
      );
      expect(await repo.settle('child', 'plan'), .75);
      expect(MockSupabase.body(backend.calls.last), {'target_plan_id': 'plan'});
    },
  );
  test(
    'memory-only changes reject concurrent submissions and signed-out sessions cannot read or mutate',
    () async {
      final repo = ScheduleSnapshots(backend.client);
      final entered = Completer<void>(), release = Completer<void>();
      final first = repo.change('child', () async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var secondSent = false;
      await expectLater(
        repo.change('child', () async {
          secondSent = true;
        }),
        throwsStateError,
      );
      await expectLater(repo.load('child'), throwsStateError);
      expect(secondSent, isFalse);
      release.complete();
      await first;
      expect((await repo.load('child')).items.length, 1);
      await backend.client.auth.signOut();
      await expectLater(repo.load('child'), throwsStateError);
      await expectLater(
        repo.change('child', () async {
          secondSent = true;
        }),
        throwsStateError,
      );
      expect(secondSent, isFalse);
    },
  );
  testWidgets(
    'cached plans remain readable at double text size and cannot edit, approve leave or settle',
    (tester) async {
      final repo = ScreenSchedules()
        ..value = ScheduleSnapshot.fromJson(
          schedulePage(),
          'child',
          offline: true,
        );
      await mountSchedules(tester, repo, parent: true, scale: 2);
      expect(find.textContaining('离线查看'), findsOneWidget);
      expect(find.textContaining('2026-11-05'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('批准请假'), findsNothing);
      expect(find.text('到期结算'), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('完成率 24.1%'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'schedule list builds visible rows and supports explicit retry after a failure or empty snapshot',
    (tester) async {
      final repo = ScreenSchedules()..fail = true;
      await mountSchedules(tester, repo);
      expect(find.textContaining('private server'), findsNothing);
      expect(find.text('重新读取计划'), findsOneWidget);
      repo.fail = false;
      repo.value = ScheduleSnapshot.fromJson(
        schedulePage(items: []),
        'child',
        offline: true,
      );
      await tester.tap(find.text('重新读取计划'));
      await tester.pumpAndSettle();
      expect(find.text('还没有周期模板或长期计划'), findsOneWidget);
      repo.value = ScheduleSnapshot.fromJson(
        schedulePage(
          items: [
            for (var i = 0; i < 1000; i++) scheduleRow(id: '$i', plan: false),
          ],
        ),
        'child',
      );
      await tester.tap(find.byTooltip('刷新计划'));
      await tester.pumpAndSettle();
      expect(find.byType(Card).evaluate().length, lessThan(15));
      expect(find.text('阅读计划 999'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'PIN revision changes during editor preparation prevent opening or saving the old operation',
    (tester) async {
      final repo = ScreenSchedules()..date = Completer<DateTime>();
      final container = await mountSchedules(tester, repo, parent: true);
      await tester.tap(find.text('配置任务'));
      await tester.pump();
      container.read(parentAuthorizationRevisionProvider.notifier).state++;
      repo.date!.complete(DateTime(2026, 11, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(repo.writes, 0);
      expect(find.textContaining('家长授权已到期'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

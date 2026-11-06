import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart'
    as domain;
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/presentation/family_gate.dart';
import 'package:learning_planet/features/tasks/presentation/reminder_coordinator.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_time_providers.dart';
import 'package:learning_planet/features/auth_family/data/family_time_repository.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/auth_family/presentation/family_time_screen.dart';
import 'package:learning_planet/features/notifications/data/parent_notification_device.dart';
import 'package:learning_planet/features/notifications/data/parent_notification_repository.dart';
import 'package:learning_planet/features/notifications/data/remote_parent_push.dart';
import 'package:learning_planet/features/notifications/domain/parent_notification.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'widget_test.dart'
    show FakeFamilyRepository, FakeAuthRepository, FakeTaskRepository;

class TimeFamilies extends FakeFamilyRepository {
  TimeFamilies() : super.withChild();
  int loads = 0;
  String zone = 'Asia/Shanghai';
  @override
  Future<List<domain.Family>> loadFamilies() async {
    loads++;
    return [
      for (final value in await super.loadFamilies())
        domain.Family(
          id: value.id,
          name: value.name,
          timezone: zone,
          children: value.children,
        ),
    ];
  }
}

final timeZoneSignal = StateProvider<String?>((ref) => null);

Map<String, dynamic> settings({
  String zone = 'Asia/Shanghai',
  int version = 0,
  String family = 'family',
}) => {
  'family_id': family,
  'timezone': zone,
  'version': version,
  'family_today': '2026-11-05',
  'child_ids': ['child'],
};

class TimeRemote implements FamilyTimeRemote {
  Map<String, dynamic> value = settings();
  final calls = <Map<String, dynamic>>[];
  Completer<void>? barrier;
  bool loseReply = false;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    calls.add({'name': name, ...params});
    await barrier?.future;
    if (name == 'set_family_timezone') {
      final next = params['requested_timezone'] as String;
      if (params['expected_version'] == value['version']) {
        value = settings(
          zone: next,
          version:
              (value['version'] as int) + (next == value['timezone'] ? 0 : 1),
        );
      }
      if (loseReply) {
        loseReply = false;
        throw const SocketException('reply lost');
      }
    }
    return {...value};
  }
}

class TimeHarness {
  final remote = TimeRemote();
  String? owner = 'parent';
  bool authorized = true;
  int revision = 1;
  final events = <String>[];
  late final repository = FamilyTimeRepository(
    remote: remote,
    accountId: () => owner,
    isAuthorized: (_) => authorized,
    authorizationRevision: () => revision,
    changeConfiguration: (before, action) async {
      events.add('retire');
      try {
        return await action();
      } finally {
        events.add('retire-again');
      }
    },
  );
}

class _NoParentRepository extends Fake
    implements ParentNotificationRepository {}

class TimeParentRepository extends _NoParentRepository {
  bool fail = false;
  @override
  Future<ParentInbox> load(String family) async {
    if (fail) throw const SocketException('policy unavailable');
    return ParentInbox.fromJson({
      'family_id': family,
      'timezone': 'UTC',
      'items': [],
      'settings': {
        ...const ParentNotificationSettings(
          enabled: true,
          version: 2,
        ).toConfig(),
        'version': 2,
      },
    });
  }
}

class TimePush extends Fake implements RemoteParentPush {
  final events = <String>[];
  bool enabled = true;
  @override
  Future<RemotePushStatus> status(String family) async =>
      enabled ? RemotePushStatus.enabled : RemotePushStatus.disabled;
  @override
  Future<void> disableFamilyAccess(String owner, String family) async {
    events.add('disabled:$family');
    enabled = false;
  }

  @override
  Future<void> enable(
    String family,
    ParentNotificationSettings settings, {
    required bool Function() canConfigure,
  }) async {
    expect(canConfigure(), true);
    events.add('enabled:${settings.version}');
    enabled = true;
  }
}

class TimeScheduler implements NotificationScheduler {
  final scopes = <String?>[];
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> setScope(String? value) async {
    scopes.add(value);
  }

  @override
  Future<void> synchronize(
    String childId,
    List<Map<String, dynamic>> reminders,
  ) async {
    throw StateError('not expected');
  }
}

class HeldFamilyStore extends OfflineStore {
  HeldFamilyStore() : super(NativeDatabase.memory());
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> write(
    String owner,
    String key,
    Map<String, dynamic> data,
  ) async {
    if (key == 'families') {
      entered.complete();
      await release.future;
    }
    await super.write(owner, key, data);
  }
}

Future<ProviderContainer> openTimeScreen(
  WidgetTester tester,
  TimeHarness h, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      familyTimeRepositoryProvider.overrideWithValue(h.repository),
      activeParentFamilyProvider.overrideWith(
        (ref) => ref.watch(parentFamilyIdProvider),
      ),
    ],
  );
  container.read(parentFamilyIdProvider.notifier).state = 'family';
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const FamilyTimeScreen(familyId: 'family'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> chooseZone(WidgetTester tester, String search, String zone) async {
  await tester.ensureVisible(find.widgetWithIcon(OutlinedButton, Icons.public));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.public));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), search);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, zone));
  await tester.pumpAndSettle();
}

Future<void> timeTap(WidgetTester tester, String text) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(text));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'city search remains reachable with the keyboard and double text',
    (tester) async {
      final h = TimeHarness();
      await openTimeScreen(tester, h, scale: 2);
      await tester.ensureVisible(
        find.widgetWithIcon(OutlinedButton, Icons.public),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.public));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '纽约');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(ListTile, 'America/New_York'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(ListTile, 'America/New_York'));
      await tester.pumpAndSettle();
      expect(find.text('将改为：America/New_York'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'cached task timezone is read without networking and refuses deleted child data',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final remote = FakeTaskRemote(DateTime.now)..seed('child');
      final tasks = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        autoSync: false,
      );
      addTearDown(tasks.dispose);
      tasks.setForeground(false);
      remote.online = false;
      expect(await tasks.cachedFamilyTimezone('child'), isNull);
      remote.online = true;
      await tasks.loadTasks('child');
      remote.online = false;
      expect(await tasks.cachedFamilyTimezone('child'), 'Asia/Shanghai');
      await store.removeChildData('child');
      await expectLater(tasks.cachedFamilyTimezone('child'), throwsStateError);
    },
  );
  testWidgets(
    'family gate reloads shared settings when task sync confirms another device changed the timezone',
    (tester) async {
      final family = TimeFamilies(),
          auth = FakeAuthRepository(const AuthSession(userId: 'parent-1'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(auth),
            familyRepositoryProvider.overrideWithValue(family),
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
            taskFamilyTimezoneProvider.overrideWith(
              (ref, child) async => ref.watch(timeZoneSignal),
            ),
          ],
          child: MaterialApp(theme: buildAppTheme(), home: const FamilyGate()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReminderCoordinator>(find.byType(ReminderCoordinator))
            .familyTimezone,
        'Asia/Shanghai',
      );
      final before = family.loads,
          container = ProviderScope.containerOf(
            tester.element(find.byType(FamilyGate)),
          );
      family.zone = 'UTC';
      container.read(timeZoneSignal.notifier).state = 'UTC';
      await tester.pumpAndSettle();
      expect(family.loads, before + 1);
      expect(
        tester
            .widget<ReminderCoordinator>(find.byType(ReminderCoordinator))
            .familyTimezone,
        'UTC',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(family.loads, before + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'a family cache write already inside SQLite rolls back when timezone retirement starts',
    () async {
      final store = HeldFamilyStore();
      addTearDown(store.close);
      final client = SupabaseClient(
        'https://example.test',
        'anon',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/families')
                  ? [
                      {
                        'id': 'family',
                        'name': 'Home',
                        'timezone': 'Asia/Shanghai',
                      },
                    ]
                  : [],
            ),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.dispose);
      final repository = OfflineFamilyRepository(client, store, () => 'parent');
      final old = repository.loadFamilies();
      await store.entered.future;
      final rejected = expectLater(old, throwsStateError);
      final changed = repository.changeConfiguration(
        'family',
        () async => true,
      );
      store.release.complete();
      await rejected;
      expect(await changed, true);
      expect(await store.read('parent', 'families'), isNull);
    },
  );
  test(
    'production provider retires family, plan and reminder caches while retaining offline task commands',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final remote = FakeTaskRemote(DateTime.now)..seed('child'),
          scheduler = TimeScheduler();
      final tasks = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        autoSync: false,
      );
      addTearDown(tasks.dispose);
      tasks.setForeground(false);
      await tasks.loadTasks('child');
      remote.online = false;
      await tasks.start('task-child');
      final commands = await store.commands('parent');
      expect(commands, isNotEmpty);
      for (final key in ['families', 'schedules:child', 'reminders:child']) {
        await store.write('parent', key, {'old': true, 'items': <dynamic>[]});
      }
      final client = SupabaseClient(
        'https://example.test',
        'anon',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/set_family_timezone')) {
            for (final key in [
              'families',
              'schedules:child',
              'reminders:child',
            ]) {
              expect(await store.read('parent', key), isNull);
            }
            expect(scheduler.scopes, [null]);
          }
          return http.Response(
            jsonEncode(settings(zone: 'UTC', version: 1)),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      // The offline adapter's production client is used by taskSupabaseClient.
      final configuredTasks = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: SupabaseTaskRepository(client),
        accountId: () => 'parent',
        autoSync: false,
      );
      addTearDown(configuredTasks.dispose);
      configuredTasks.setForeground(false);
      final schedules = ScheduleRepository(client, offline: configuredTasks),
          family = OfflineFamilyRepository(client, store, () => 'parent');
      final container = ProviderContainer(
        overrides: [
          taskRepositoryProvider.overrideWithValue(configuredTasks),
          familyRepositoryProvider.overrideWithValue(family),
          scheduleRepositoryProvider.overrideWithValue(schedules),
          notificationSchedulerProvider.overrideWithValue(scheduler),
          parentNotificationDeviceProvider.overrideWithValue(
            ParentNotificationDevice(
              configuredTasks,
              _NoParentRepository(),
              scheduler,
            ),
          ),
          activeParentFamilyProvider.overrideWithValue('family'),
        ],
      );
      addTearDown(container.dispose);
      final repository = container.read(familyTimeRepositoryProvider)!;
      final saved = await repository.save(
        FamilyTimeSettings.fromJson(settings()),
        'UTC',
      );
      expect(saved.timezone, 'UTC');
      expect(await store.commands('parent'), commands);
      for (final key in ['families', 'schedules:child', 'reminders:child']) {
        expect(await store.read('parent', key), isNull);
      }
      expect(
        (await store.read('parent', 'schedule-version:child'))!['value'],
        2,
      );
      expect(
        (await store.read('parent', 'reminder-version:child'))!['value'],
        2,
      );
    },
  );
  test(
    'parent remote delivery is disabled before timezone write and restored only with a fresh policy',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final tasks = OfflineTaskRepository(
        store: store,
        remote: FakeTaskRemote(DateTime.now),
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        autoSync: false,
      );
      addTearDown(tasks.dispose);
      final push = TimePush(),
          parent = TimeParentRepository(),
          scheduler = TimeScheduler();
      final device = ParentNotificationDevice(
        tasks,
        parent,
        scheduler,
        remotePush: push,
      );
      await store.write('parent', 'parent-notification-mode:family', {
        'enabled': true,
      });
      expect(
        await device.changeFamilyTimezone('family', () async {
          expect(push.enabled, false);
          return 'saved';
        }, canConfigure: () => true),
        'saved',
      );
      expect(push.events, ['disabled:family', 'enabled:2']);
      parent.fail = true;
      await expectLater(
        device.changeFamilyTimezone(
          'family',
          () async => 1,
          canConfigure: () => true,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(push.enabled, false);
      expect(push.events, ['disabled:family', 'enabled:2', 'disabled:family']);
    },
  );
  test(
    'local privacy cleanup fences a delayed settings read and missing account makes no RPC',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final remote = TimeRemote()..barrier = Completer<void>();
      String? owner = 'parent';
      final repository = FamilyTimeRepository(
        remote: remote,
        store: store,
        accountId: () => owner,
        isAuthorized: (_) => true,
        authorizationRevision: () => 1,
        changeConfiguration: (before, action) => action(),
      );
      final load = repository.load('family');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final rejected = expectLater(load, throwsStateError);
      await store.removeChildData('child');
      remote.barrier!.complete();
      await rejected;
      final count = remote.calls.length;
      owner = null;
      await expectLater(repository.load('family'), throwsStateError);
      expect(remote.calls.length, count);
    },
  );
  test(
    'real Supabase serialization carries family, selected IANA zone and expected version',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.test',
        'anon',
        httpClient: MockClient((request) async {
          requests.add({
            'path': request.url.path,
            ...jsonDecode(request.body) as Map<String, dynamic>,
          });
          return http.Response(
            jsonEncode(settings()),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final remote = SupabaseFamilyTimeRemote(client);
      await remote.call('set_family_timezone', {
        'target_family_id': 'family',
        'requested_timezone': 'UTC',
        'expected_version': 3,
      });
      expect(requests.single, {
        'path': '/rest/v1/rpc/set_family_timezone',
        'target_family_id': 'family',
        'requested_timezone': 'UTC',
        'expected_version': 3,
      });
    },
  );
  test(
    'lost timezone reply retries the same version without a second change and always retires cached state',
    () async {
      final h = TimeHarness(),
          before = await TimeHarness().repository.load('family');
      h.remote.loseReply = true;
      await expectLater(
        h.repository.save(before, 'UTC'),
        throwsA(isA<SocketException>()),
      );
      expect(h.remote.value['version'], 1);
      expect(h.events, ['retire', 'retire-again']);
      final result = await h.repository.save(before, 'UTC');
      expect(result.version, 1);
      expect(result.timezone, 'UTC');
      expect(h.remote.calls[0], h.remote.calls[1]);
      expect(h.events.length, 4);
    },
  );
  test(
    'account, authorization renewal and wrong family responses cannot publish stale settings',
    () async {
      for (final mutate in <void Function(TimeHarness)>[
        (h) => h.owner = 'other',
        (h) => h.authorized = false,
        (h) => h.revision++,
      ]) {
        final h = TimeHarness();
        h.remote.barrier = Completer<void>();
        final load = h.repository.load('family');
        await Future<void>.delayed(Duration.zero);
        final rejected = expectLater(load, throwsStateError);
        mutate(h);
        h.remote.barrier!.complete();
        await rejected;
      }
      final h = TimeHarness();
      h.remote.value = settings(family: 'foreign');
      await expectLater(h.repository.load('family'), throwsFormatException);
      h.authorized = false;
      await expectLater(h.repository.load('family'), throwsStateError);
      expect(h.remote.calls.length, 1);
    },
  );
  test(
    'a configuration fence failing before RPC and duplicate taps cannot send a second write',
    () async {
      final h = TimeHarness(), before = FamilyTimeSettings.fromJson(settings());
      h.remote.barrier = Completer<void>();
      final first = h.repository.save(before, 'UTC');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        h.repository.save(before, 'Asia/Tokyo'),
        throwsStateError,
      );
      expect(h.remote.calls.length, 1);
      h.remote.barrier!.complete();
      await first;
      final repository = FamilyTimeRepository(
        remote: h.remote,
        accountId: () => h.owner,
        isAuthorized: (_) => true,
        authorizationRevision: () => 1,
        changeConfiguration: (before, action) =>
            throw StateError('native cancellation failed'),
      );
      await expectLater(repository.save(before, 'UTC'), throwsStateError);
      expect(h.remote.calls.length, 1);
    },
  );
  test(
    'family cache cannot be restored by a read started before timezone mutation or a failed write',
    () async {
      final store = OfflineStore(NativeDatabase.memory()),
          entered = Completer<void>(),
          reply = Completer<http.Response>();
      addTearDown(store.close);
      bool hold = true;
      String zone = 'Asia/Shanghai';
      final client = SupabaseClient(
        'https://example.test',
        'anon',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/families')) {
            if (hold) {
              entered.complete();
              return reply.future;
            }
            return http.Response(
              jsonEncode([
                {'id': 'family', 'name': 'Home', 'timezone': zone},
              ]),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = OfflineFamilyRepository(client, store, () => 'parent');
      await store.write('parent', 'families', {'items': []});
      final old = repository.loadFamilies();
      await entered.future;
      await repository.changeConfiguration('family', () async {
        expect(await store.read('parent', 'families'), isNull);
        await expectLater(repository.loadFamilies(), throwsStateError);
        zone = 'UTC';
      });
      final rejected = expectLater(old, throwsStateError);
      reply.complete(
        http.Response(
          jsonEncode([
            {'id': 'family', 'name': 'Home', 'timezone': 'Asia/Shanghai'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: http.Request(
            'GET',
            Uri.parse('https://example.test/rest/v1/families'),
          ),
        ),
      );
      await rejected;
      expect(await store.read('parent', 'families'), isNull);
      hold = false;
      expect((await repository.loadFamilies()).single.timezone, 'UTC');
      expect(
        (await store.read('parent', 'families'))!['items'][0]['timezone'],
        'UTC',
      );
      await expectLater(
        repository.changeConfiguration(
          'family',
          () => throw const SocketException('lost'),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(await store.read('parent', 'families'), isNull);
    },
  );
  test(
    'timezone change cancels child alarms and suppresses refresh until the mutation completes',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final tasks = OfflineTaskRepository(
        store: store,
        remote: FakeTaskRemote(DateTime.now),
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        autoSync: false,
      );
      addTearDown(tasks.dispose);
      final scheduler = TimeScheduler(),
          device = ParentNotificationDevice(
            tasks,
            _NoParentRepository(),
            scheduler,
          );
      await store.write('parent', 'parent-notification-policy:family', {
        'old': true,
      });
      final entered = Completer<void>(), reply = Completer<int>();
      final change = device.changeFamilyTimezone('family', () {
        entered.complete();
        return reply.future;
      }, canConfigure: () => true);
      await entered.future;
      expect(scheduler.scopes, [null]);
      expect(
        await store.read('parent', 'parent-notification-policy:family'),
        isNull,
      );
      expect(
        await device.refresh('family', 'child', isCurrent: () => true),
        true,
      );
      reply.complete(1);
      expect(await change, 1);
      expect(
        await device.refresh('family', 'child', isCurrent: () => true),
        false,
      );
      await expectLater(
        device.changeFamilyTimezone(
          'family',
          () => throw const SocketException('lost'),
          canConfigure: () => true,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(scheduler.scopes, [null, null]);
      expect(
        await store.read('parent', 'parent-notification-policy:family'),
        isNull,
      );
    },
  );
  testWidgets(
    'parent chooses a searchable city and saves with the displayed version at double text',
    (tester) async {
      final h = TimeHarness();
      await openTimeScreen(tester, h, scale: 2);
      expect(find.text('家庭今天：2026-11-05'), findsOneWidget);
      await chooseZone(tester, '纽约', 'America/New_York');
      await timeTap(tester, '保存时区');
      expect(h.remote.value['timezone'], 'America/New_York');
      expect(
        h.remote.calls
            .where((c) => c['name'] == 'set_family_timezone')
            .single['expected_version'],
        0,
      );
      expect(find.text('家庭时区已保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'uncertain save freezes the original selection and allows retry or authoritative reload',
    (tester) async {
      final h = TimeHarness();
      await openTimeScreen(tester, h);
      await chooseZone(tester, '纽约', 'America/New_York');
      h.remote.loseReply = true;
      await timeTap(tester, '保存时区');
      expect(find.text('重试原设置'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithIcon(OutlinedButton, Icons.public),
            )
            .onPressed,
        isNull,
      );
      await timeTap(tester, '重试原设置');
      expect(h.remote.value['version'], 1);
      expect(find.text('家庭时区已保存'), findsOneWidget);
      await chooseZone(tester, '东京', 'Asia/Tokyo');
      h.remote.loseReply = true;
      await timeTap(tester, '保存时区');
      await timeTap(tester, '刷新核对');
      expect(find.text('当前：东京'), findsOneWidget);
      expect(find.text('重试原设置'), findsNothing);
      expect(h.remote.value['version'], 2);
    },
  );
  testWidgets(
    'expired parent authorization hides settings and a delayed load cannot restore them',
    (tester) async {
      final h = TimeHarness();
      final container = await openTimeScreen(tester, h);
      h.remote.barrier = Completer<void>();
      await tester.ensureVisible(find.text('刷新家庭时区'));
      await tester.tap(find.text('刷新家庭时区'));
      await tester.pump();
      container.read(parentFamilyIdProvider.notifier).state = null;
      h.authorized = false;
      await tester.pump();
      h.remote.barrier!.complete();
      await tester.pumpAndSettle();
      expect(find.text('家长授权已到期，请返回首页重新验证 PIN'), findsOneWidget);
      expect(find.text('家庭今天：2026-11-05'), findsNothing);
    },
  );
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/features/auth_family/data/family_access_repository.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/auth_family/application/family_access_provider.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/presentation/family_gate.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'support/mock_supabase.dart';
import 'widget_test.dart' as fixture;

FamilyAccessState state(int version, {bool active = false, int? revoked}) =>
    FamilyAccessState(
      familyId: 'family',
      version: version,
      active: active,
      lastRevokedVersion: revoked ?? (active ? 0 : version),
      childIds: {'child'},
    );
Map<String, dynamic> accessJson(
  int version, {
  bool active = false,
  int? revoked,
  String owner = 'parent',
}) => {
  'owner_id': owner,
  'states': [
    {
      'family_id': 'family',
      'version': version,
      'active': active,
      'last_revoked_version': revoked ?? (active ? 0 : version),
      'child_ids': ['child'],
    },
  ],
};

class _WaitingTasks extends FakeTaskRemote {
  _WaitingTasks(super.now);
  final entered = Completer<void>();
  @override
  Future<Map<String, dynamic>> snapshot(String childId) async {
    if (!entered.isCompleted) entered.complete();
    return super.snapshot(childId);
  }
}

class _UnusedClient extends Fake implements SupabaseClient {}

class _PollingAccess extends FamilyAccessRepository {
  _PollingAccess(OfflineStore store)
    : super(
        store: store,
        accountId: () => 'parent',
        load: () async => throw StateError('Polling test does not query data'),
        cancelNotifications: (_) async {},
      );
  int calls = 0;
  @override
  Future<void> refresh() async {
    calls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineStore store;
  setUp(() async {
    store = OfflineStore(NativeDatabase.memory());
    await store.customSelect('SELECT 1').get();
  });
  tearDown(() => store.close());
  testWidgets(
    'membership polling also runs without children, pauses in background and refreshes on resume',
    (tester) async {
      final access = _PollingAccess(store);
      final family = OfflineFamilyRepository(
        _UnusedClient(),
        store,
        () => 'parent',
        access: access,
      );
      final container = ProviderContainer(
        overrides: [familyRepositoryProvider.overrideWithValue(family)],
      );
      final subscription = container.listen(
        familyAccessChangesProvider,
        (_, _) {},
      );
      var released = false;
      Future<void> release() async {
        if (released) return;
        released = true;
        subscription.close();
        container.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await access.dispose();
      }

      addTearDown(release);
      await tester.pump();
      expect(access.calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(access.calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(access.calls, 2);
      await tester.pump(const Duration(seconds: 15));
      expect(access.calls, 3);
      await release();
      await tester.pump(const Duration(seconds: 30));
      expect(access.calls, 3);
    },
  );
  test(
    'online family refresh accepts first then reconciles access; stale family rows are filtered before caching',
    () async {
      final backend = MockSupabase();
      addTearDown(backend.close);
      await backend.signIn();
      final owner = backend.client.auth.currentUser!.id;
      final calls = <String>[];
      backend.handle = (request) {
        final path = request.url.path.split('/').last;
        calls.add(path);
        return MockSupabase.json(request, switch (path) {
          'accept_family_invitations' => 0,
          'families' => [
            {'id': 'family', 'name': '家', 'timezone': 'Asia/Shanghai'},
          ],
          'children' => [
            {
              'id': 'child',
              'family_id': 'family',
              'nickname': '小星',
              'grade': 2,
            },
          ],
          'family_membership_access' => accessJson(2, owner: owner),
          _ => <dynamic>[],
        });
      };
      final access = FamilyAccessRepository(
        store: store,
        accountId: () => owner,
        load: () => FamilyAccessRepository.fetch(backend.client),
        cancelNotifications: (_) async {},
      );
      addTearDown(access.dispose);
      final family = OfflineFamilyRepository(
        backend.client,
        store,
        () => owner,
        access: access,
      );
      expect(await family.loadFamilies(), isEmpty);
      expect(
        calls.indexOf('accept_family_invitations'),
        lessThan(calls.indexOf('family_membership_access')),
      );
      expect((await store.read(owner, 'families'))!['items'], isEmpty);
      backend.handle = (_) => throw const SocketException('offline');
      expect(await family.loadFamilies(), isEmpty);
    },
  );
  testWidgets(
    'access change closes protected route only for the current account and clears its family PIN',
    (tester) async {
      final family = fixture.FakeFamilyRepository()
        ..families.addAll(fixture.FakeFamilyRepository.withChild().families);
      final events = StreamController<FamilyAccessChange>.broadcast();
      final container = ProviderContainer(
        overrides: [
          familyRepositoryProvider.overrideWithValue(family),
          authRepositoryProvider.overrideWithValue(
            fixture.FakeAuthRepository(const AuthSession(userId: 'parent-1')),
          ),
          taskRepositoryProvider.overrideWithValue(
            fixture.FakeTaskRepository(),
          ),
          familyAccessChangesProvider.overrideWith((ref) => events.stream),
          authorizationClockProvider.overrideWith(
            (ref) => Stream.value(DateTime.now()),
          ),
        ],
      );
      addTearDown(events.close);
      addTearDown(container.dispose);
      container.read(parentModeProvider.notifier).state = true;
      container.read(parentFamilyIdProvider.notifier).state = 'family-1';
      container.read(parentAuthorizedUntilProvider.notifier).state =
          DateTime.now().add(const Duration(minutes: 5));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FamilyGate()),
        ),
      );
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(FamilyGate))).push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('protected-route')),
        ),
      );
      await tester.pumpAndSettle();
      events.add(FamilyAccessChange('other', 'family-1', 2, {'child-1'}));
      await tester.pumpAndSettle();
      expect(find.text('protected-route'), findsOneWidget);
      expect(container.read(parentModeProvider), true);
      family.families.clear();
      events.add(FamilyAccessChange('parent-1', 'family-1', 2, {'child-1'}));
      await tester.pumpAndSettle();
      expect(find.text('protected-route'), findsNothing);
      expect(container.read(parentModeProvider), false);
      expect(container.read(selectedChildIdProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  Future<void> seed() async {
    for (final owner in ['parent', 'other']) {
      await store.write(owner, 'families', {
        'items': [
          {
            'id': 'family',
            'children': [
              {'id': 'child'},
            ],
          },
          {
            'id': 'kept-family',
            'children': [
              {'id': 'kept-child'},
            ],
          },
        ],
      });
      for (final child in ['child', 'kept-child']) {
        await store.write(owner, 'tasks:$child', {'private': '$owner/$child'});
        await store.enqueue(owner, child, {
          'command_id': '$owner-$child',
          'task_id': 'task-$child',
          'kind': 'start',
        });
      }
      await store.writeImageDraft(
        owner,
        'child',
        'family',
        'image',
        {'consent': false},
        Uint8List.fromList([1, 2, 3]),
        null,
      );
      await store.write(owner, 'review-task:review', {
        'task': {'child_id': 'child'},
        'answer': 'private',
      });
      await store.write(owner, 'invitation-command:family', {
        'family_id': 'family',
        'private_email': 'private@example.test',
      });
      await store.write(owner, 'configuration-time-v1', {
        'events': [
          {'family_id': 'family'},
          {'family_id': 'kept-family'},
        ],
      });
      await store.write(owner, 'parent-notification-mode:family', {
        'enabled': true,
      });
      await store.write(owner, 'parent-notification-mode:kept-family', {
        'enabled': true,
      });
    }
  }

  test(
    'revocation removes only this owner and family, preserving shared children and other unsynced work',
    () async {
      await seed();
      await store.applyFamilyAccess('parent', [state(1, active: true)]);
      final changes = await store.applyFamilyAccess('parent', [state(2)]);
      expect(changes.single.owner, 'parent');
      expect(changes.single.childIds, {'child'});
      expect(await store.isChildDeleted('child'), false);
      expect(await store.read('parent', 'tasks:child'), isNull);
      expect(await store.read('parent', 'review-task:review'), isNull);
      expect(await store.read('parent', 'invitation-command:family'), isNull);
      expect(
        await store.read('parent', 'parent-notification-mode:family'),
        isNull,
      );
      expect(
        await store.read('parent', 'parent-notification-mode:kept-family'),
        isNotNull,
      );
      expect(await store.imageDraft('parent', 'image'), isNull);
      expect(await store.imageDraft('other', 'image'), isNotNull);
      expect(await store.read('other', 'tasks:child'), {
        'private': 'other/child',
      });
      expect((await store.commands('parent')).single['child_id'], 'kept-child');
      expect(await store.commands('other'), hasLength(2));
      expect((await store.read('parent', 'configuration-time-v1'))!['events'], [
        {'family_id': 'kept-family'},
      ]);
      expect(
        (await store.read('other', 'configuration-time-v1'))!['events'],
        hasLength(2),
      );
      expect((await store.read('parent', 'families'))!['items'], [
        {
          'id': 'kept-family',
          'children': [
            {'id': 'kept-child'},
          ],
        },
      ]);
      expect((await store.read('other', 'families'))!['items'], hasLength(2));
    },
  );
  test(
    'revoked writes and stale family snapshots cannot reintroduce cache commands or images',
    () async {
      await seed();
      await store.applyFamilyAccess('parent', [state(2)]);
      await expectLater(
        store.write('parent', 'tasks:child', {'private': 'late'}),
        throwsStateError,
      );
      await expectLater(
        store.write('parent', 'creation:child:family', {
          'command': {'family_id': 'family'},
        }),
        throwsStateError,
      );
      await expectLater(
        store.enqueue('parent', 'child', {
          'task_id': 't',
          'command_id': 'new',
          'kind': 'start',
        }),
        throwsStateError,
      );
      await expectLater(
        store.writeImageDraft(
          'parent',
          'child',
          'family',
          'late',
          {},
          Uint8List.fromList([1]),
          null,
        ),
        throwsStateError,
      );
      await store.write('parent', 'families', {
        'items': [
          {
            'id': 'family',
            'children': [
              {'id': 'child'},
            ],
          },
        ],
      });
      expect((await store.read('parent', 'families'))!['items'], isEmpty);
      await store.write('parent', 'configuration-time-v1', {
        'events': [
          {'family_id': 'family'},
          {'family_id': 'kept-family'},
        ],
      });
      expect((await store.read('parent', 'configuration-time-v1'))!['events'], [
        {'family_id': 'kept-family'},
      ]);
    },
  );
  test(
    'rejoin purges previous membership once, retains image UUID barriers, and ignores late older states',
    () async {
      await seed();
      // The first response may already describe a rejoined membership.
      await store.applyFamilyAccess('parent', [
        state(3, active: true, revoked: 2),
      ]);
      expect(await store.read('parent', 'tasks:child'), isNull);
      expect(
        await store.familyAccessRevoked('parent', childId: 'child'),
        false,
      );
      await store.write('parent', 'tasks:child', {'fresh': true});
      await store.applyFamilyAccess('parent', [state(2)]);
      await store.applyFamilyAccess('parent', [
        state(3, active: true, revoked: 2),
      ]);
      expect(await store.read('parent', 'tasks:child'), {'fresh': true});
      await expectLater(
        store.writeImageDraft(
          'parent',
          'child',
          'family',
          'image',
          {},
          Uint8List.fromList([1]),
          null,
        ),
        throwsStateError,
      );
      await store.writeImageDraft(
        'parent',
        'child',
        'family',
        'fresh-image',
        {},
        Uint8List.fromList([1]),
        null,
      );
      expect(await store.imageDraft('parent', 'fresh-image'), isNotNull);
      final old = (await store.pendingFamilyAccessChanges('parent')).single;
      await store.applyFamilyAccess('parent', [state(4)]);
      await store.acknowledgeFamilyAccessChange(old);
      expect(
        (await store.pendingFamilyAccessChanges('parent')).single.version,
        4,
      );
    },
  );
  test(
    'invalid state batch rolls back cache deletion and membership changes atomically',
    () async {
      await seed();
      await store.applyFamilyAccess('parent', [
        state(3, active: true, revoked: 2),
      ]);
      await store.write('parent', 'tasks:child', {'fresh': true});
      await expectLater(
        store.applyFamilyAccess('parent', [
          state(4),
          state(5, active: true, revoked: 1),
        ]),
        throwsStateError,
      );
      expect(
        await store.familyAccessRevoked('parent', childId: 'child'),
        false,
      );
      expect(await store.read('parent', 'tasks:child'), {'fresh': true});
      expect(() => state(0), throwsFormatException);
    },
  );
  test(
    'schema four upgrade preserves drafts and queues; revocation survives SQLite reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('family-access-');
      final file = File('${directory.path}/cache.sqlite');
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      await seed();
      await store.customStatement('DROP TABLE family_access');
      await store.customStatement('PRAGMA user_version=4');
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      expect(await store.imageDraft('parent', 'image'), isNotNull);
      expect(await store.commands('parent'), hasLength(2));
      expect(
        (await store.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        5,
      );
      await store.applyFamilyAccess('parent', [state(2)]);
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      expect(await store.familyAccessRevoked('parent', childId: 'child'), true);
      expect(await store.pendingFamilyAccessChanges('parent'), hasLength(1));
      expect(await store.imageDraft('other', 'image'), isNotNull);
      await store.close();
      store = OfflineStore(NativeDatabase.memory());
      await directory.delete(recursive: true);
    },
  );
  test(
    'native cleanup retry is durable and runs before network after repository restart',
    () async {
      await seed();
      var fail = true, calls = 0;
      final repository = FamilyAccessRepository(
        store: store,
        accountId: () => 'parent',
        load: () async => accessJson(2),
        cancelNotifications: (change) async {
          calls++;
          if (fail) throw StateError('native unavailable');
        },
      );
      final seen = <FamilyAccessChange>[];
      final subscription = repository.changes.listen(seen.add);
      await expectLater(repository.refresh(), throwsStateError);
      expect(await store.read('parent', 'tasks:child'), isNull);
      expect(await store.pendingFamilyAccessChanges('parent'), hasLength(1));
      await repository.dispose();
      await subscription.cancel();
      fail = false;
      final restarted = FamilyAccessRepository(
        store: store,
        accountId: () => 'parent',
        load: () async => throw const SocketException('offline'),
        cancelNotifications: (change) async {
          calls++;
          expect(change.familyId, 'family');
        },
      );
      await expectLater(restarted.refresh(), throwsA(isA<SocketException>()));
      expect(calls, 2);
      expect(await store.pendingFamilyAccessChanges('parent'), isEmpty);
      expect(seen, hasLength(1));
      await restarted.dispose();
    },
  );
  test(
    'wrong owner and account change during access response never purge another account',
    () async {
      await seed();
      String? owner = 'parent';
      var response = accessJson(2, owner: 'other');
      Completer<Map<String, dynamic>>? wait;
      final repository = FamilyAccessRepository(
        store: store,
        accountId: () => owner,
        load: () async => wait == null ? response : await wait.future,
        cancelNotifications: (_) async => fail('no native cleanup expected'),
      );
      await expectLater(repository.refresh(), throwsStateError);
      expect(await store.read('parent', 'tasks:child'), isNotNull);
      wait = Completer();
      final future = repository.refresh();
      final assertion = expectLater(future, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      owner = 'other';
      wait.complete(accessJson(2));
      await assertion;
      expect(await store.read('other', 'tasks:child'), isNotNull);
      expect(await store.read('parent', 'tasks:child'), isNotNull);
      await repository.dispose();
    },
  );
  test(
    'old task outbox is erased before replay when membership is revoked',
    () async {
      final now = DateTime.utc(2026, 9, 16, 12),
          remote = FakeTaskRemote(() => DateTime.utc(2026, 9, 16, 12))
            ..seed('child');
      await store.write(
        'parent',
        'tasks:child',
        await remote.snapshot('child'),
      );
      await store.enqueue('parent', 'child', {
        'command_id': 'queued',
        'task_id': 'task-child',
        'kind': 'start',
        'occurred_at': now.toIso8601String(),
        'expected_version': 0,
      });
      final repository = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        autoSync: false,
        refreshFamilyAccess: () async {
          await store.applyFamilyAccess('parent', [state(2)]);
        },
      );
      await repository.synchronize('child');
      expect(remote.requests, isEmpty);
      expect(await store.commands('parent'), isEmpty);
      await expectLater(repository.loadTasks('child'), throwsStateError);
      await repository.dispose();
    },
  );
  test(
    'late task snapshot cannot resurrect cache after remove and rejoin',
    () async {
      final remote = _WaitingTasks(() => DateTime.utc(2026, 9, 16, 12))
        ..seed('child')
        ..snapshotBarrier = Completer<void>();
      final repository = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        autoSync: false,
      );
      final future = repository.synchronize('child');
      await remote.entered.future;
      await store.applyFamilyAccess('parent', [
        state(2),
        state(3, active: true, revoked: 2),
      ]);
      remote.snapshotBarrier!.complete();
      await future;
      expect(await store.read('parent', 'tasks:child'), isNull);
      expect(remote.requests, isEmpty);
      await repository.dispose();
    },
  );
}

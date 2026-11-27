import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/auth_family/data/family_access_repository.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'email_login_test.dart' show Harness, session;
import 'support/mock_supabase.dart' show MockSupabase;

class DirectoryStore extends OfflineStore {
  DirectoryStore() : super(NativeDatabase.memory());
  int familyWrites = 0;
  Completer<void>? entered, resume;

  @override
  Future<void> write(String owner, String key, Map<String, dynamic> data) {
    if (key == 'families') familyWrites++;
    return super.write(owner, key, data);
  }

  @override
  Future<bool> matchesVerifiedFamilyDirectory(
    String owner,
    Map<String, dynamic> snapshot,
    Iterable<String> children,
  ) async {
    final same = await super.matchesVerifiedFamilyDirectory(
      owner,
      snapshot,
      children,
    );
    if (same && entered != null && !entered!.isCompleted) {
      entered!.complete();
      await resume!.future;
    }
    return same;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late DirectoryStore store;
  late OfflineTaskRepository tasks;
  late ProviderContainer container;
  setUp(() {
    h = Harness();
    store = DirectoryStore();
    String? owner() => h.client.auth.currentUser?.id;
    tasks = OfflineTaskRepository(
      store: store,
      remote: SupabaseTaskSyncRemote(h.client),
      live: SupabaseTaskRepository(h.client),
      accountId: owner,
      autoSync: false,
    );
    container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(h.repository),
        familyRepositoryProvider.overrideWithValue(
          OfflineFamilyRepository(h.client, store, owner),
        ),
        accountDeletionRepositoryProvider.overrideWithValue(
          SupabaseAccountDeletionRepository(h.client, offline: tasks),
        ),
      ],
    );
    h.handle = (r) {
      if (r.url.path.endsWith('/token')) return Harness.reply(session());
      if (r.url.path.endsWith('account_deletion_status') ||
          r.url.path.endsWith('accept_family_invitations')) {
        return MockSupabase.json(r, null);
      }
      return MockSupabase.json(r, []);
    };
  });
  tearDown(() async {
    container.dispose();
    await tasks.dispose();
    await store.close();
    await h.close();
  });

  Future<void> restore({bool expired = true}) async {
    await h.client.auth.setInitialSession(
      jsonEncode(session(seconds: expired ? -3600 : 3600)),
    );
    await container.read(authSessionProvider.future);
    await store.write('parent', 'families', {
      'items': [
        {'id': 'old', 'name': 'Cached', 'timezone': 'UTC', 'children': []},
      ],
    });
  }

  void recordFailure() => container
      .read(familyEntryRefreshProvider)
      .record(h.client.auth.currentSession!, AuthRetryableFetchException());

  test(
    'one expired-session refresh covers the two offline entry checks',
    () async {
      await restore();
      final whenOnline = h.handle;
      h.handle = (_) => throw http.ClientException('offline');
      expect(
        await container.read(accountDeletionStatusProvider.future),
        isNull,
      );
      final attempts = h.calls.length;
      expect(attempts, greaterThan(1));
      expect(h.calls.every((r) => r.url.path.endsWith('/token')), isTrue);
      final families = await container.read(familiesProvider.future);
      expect(families.single.name, 'Cached');
      expect(
        h.calls,
        hasLength(attempts),
        reason: 'the failed session was retried during the same boot',
      );

      h.handle = whenOnline;
      expect(
        await container.refresh(accountDeletionStatusProvider.future),
        isNull,
      );
      expect(await container.read(familiesProvider.future), isEmpty);
      expect(
        h.calls.any((r) => r.url.path.endsWith('accept_family_invitations')),
        isTrue,
      );
      final calls = h.calls.length;
      expect(
        await container.refresh(accountDeletionStatusProvider.future),
        isNull,
      );
      expect(await container.read(familiesProvider.future), isEmpty);
      expect(
        h.calls.length,
        calls + 1,
        reason: 'a later healthy poll must leave the family list alone',
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'explicit family retry asks the server and honors a rejection',
    () async {
      await restore();
      recordFailure();
      expect(
        (await container.read(familiesProvider.future)).single.name,
        'Cached',
      );
      final online = h.handle;
      h.handle = (r) => r.url.path.endsWith('accept_family_invitations')
          ? MockSupabase.denied(r)
          : online(r);
      await expectLater(
        container.refresh(familiesProvider.future),
        throwsA(isA<PostgrestException>()),
      );
      expect(h.calls.map((r) => r.url.path), [
        '/auth/v1/token',
        '/rest/v1/rpc/accept_family_invitations',
      ]);
      expect(await store.read('parent', 'families'), isNull);
    },
  );

  Future<void> prepareDirectory(String Function() nickname) async {
    await restore(expired: false);
    await store.remove('parent', 'families');
    final other = h.handle;
    h.handle = (r) => r.url.path.endsWith('/families')
        ? MockSupabase.json(r, [
            {
              'id': 'family',
              'name': 'Family',
              'timezone': 'UTC',
              'children': [
                {
                  'id': 'child',
                  'family_id': 'family',
                  'nickname': nickname(),
                  'grade': 2,
                },
              ],
            },
          ])
        : other(r);
  }

  test(
    'an identical verified directory avoids a rewrite while changes and pending invitations reconcile',
    () async {
      var nickname = 'first';
      await prepareDirectory(() => nickname);
      var membershipChecks = 0, allowMembership = true;
      final access = FamilyAccessRepository(
        store: store,
        accountId: () => 'parent',
        load: () async {
          membershipChecks++;
          if (!allowMembership) {
            throw const PostgrestException(message: 'denied', code: '42501');
          }
          return {'owner_id': 'parent', 'states': []};
        },
        cancelNotifications: (_) async {},
      );
      addTearDown(access.dispose);
      final repository = OfflineFamilyRepository(
        h.client,
        store,
        () => 'parent',
        access: access,
      );
      await repository.loadFamilies();
      final written = store.familyWrites;
      final calls = h.calls.length;
      expect(
        (await repository.loadFamilies()).single.children.single.nickname,
        'first',
      );
      expect(store.familyWrites, written);
      expect(membershipChecks, 2);
      expect(h.calls.skip(calls).map((r) => r.url.pathSegments.last), [
        'accept_family_invitations',
        'families',
        'child_deletion_tombstones',
        'family_access_revocations',
      ]);
      await store.write('parent', 'invitation-command:gone', {
        'request': 'pending',
      });
      await repository.loadFamilies();
      expect(await store.read('parent', 'invitation-command:gone'), isNull);
      expect(store.familyWrites, greaterThan(written));
      nickname = 'changed';
      expect(
        (await repository.loadFamilies()).single.children.single.nickname,
        'changed',
      );
      final cached = await store.read('parent', 'families');
      expect(cached!['items'].single['children'].single['nickname'], 'changed');
      allowMembership = false;
      await expectLater(
        repository.loadFamilies(),
        throwsA(isA<PostgrestException>()),
      );
      expect(await store.read('parent', 'families'), isNull);
    },
  );

  for (final change in ['account', 'child', 'membership', 'newer-directory']) {
    test(
      'a delayed unchanged-directory result cannot survive $change',
      () async {
        var nickname = 'first';
        await prepareDirectory(() => nickname);
        final repository = OfflineFamilyRepository(
          h.client,
          store,
          () => 'parent',
        );
        await repository.loadFamilies();
        store.entered = Completer<void>();
        store.resume = Completer<void>();
        final stale = expectLater(repository.loadFamilies(), throwsStateError);
        await store.entered!.future;
        switch (change) {
          case 'account':
            await store.removeAccountData('parent', 'job');
          case 'child':
            await store.removeChildData('child');
          case 'membership':
            await store.applyFamilyAccess('parent', [
              FamilyAccessState(
                familyId: 'family',
                version: 2,
                active: false,
                lastRevokedVersion: 2,
                childIds: {'child'},
              ),
            ]);
          case 'newer-directory':
            nickname = 'newer';
            expect(
              (await repository.loadFamilies()).single.children.single.nickname,
              'newer',
            );
        }
        store.resume!.complete();
        await stale;
        if (change == 'newer-directory') {
          final cached = await store.read('parent', 'families');
          expect(
            cached!['items'].single['children'].single['nickname'],
            'newer',
          );
        }
      },
    );
  }

  test(
    'reopening the database compares the stored payload and durable access markers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'family-directory-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/family.sqlite');
      final snapshot = {
        'items': [
          {
            'id': 'family',
            'name': 'Family',
            'timezone': 'UTC',
            'children': [
              {'id': 'child'},
            ],
          },
        ],
      };
      final first = OfflineStore(NativeDatabase(file));
      await first.write('parent', 'families', snapshot);
      await first.close();
      final reopened = OfflineStore(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        await reopened.matchesVerifiedFamilyDirectory('parent', snapshot, [
          'child',
        ]),
        true,
      );
      expect(
        await reopened.matchesVerifiedFamilyDirectory('different', snapshot, [
          'child',
        ]),
        false,
      );
      expect(
        await reopened.matchesVerifiedFamilyDirectory('parent', {
          'items': [],
        }, []),
        false,
      );
      await reopened.write('parent', 'directory-hidden:child:child', {
        'family_id': 'family',
      });
      expect(
        await reopened.matchesVerifiedFamilyDirectory('parent', snapshot, [
          'child',
        ]),
        false,
      );
      await reopened.remove('parent', 'directory-hidden:child:child');
      await reopened.customStatement('INSERT INTO deleted_children VALUES(?)', [
        'child',
      ]);
      expect(
        await reopened.matchesVerifiedFamilyDirectory('parent', snapshot, [
          'child',
        ]),
        false,
      );
    },
  );

  test('a denied embedded family read discards the cached list', () async {
    await restore(expired: false);
    final online = h.handle;
    h.handle = (r) =>
        r.url.path.endsWith('/families') ? MockSupabase.denied(r) : online(r);
    await expectLater(
      container.read(familiesProvider.future),
      throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '42501')),
    );
    expect(h.calls.map((r) => r.url.pathSegments.last), [
      'accept_family_invitations',
      'families',
    ]);
    expect(await store.read('parent', 'families'), isNull);
  });

  for (final user in ['parent', 'different']) {
    test(
      'a prepared deletion check is discarded on a new session for $user',
      () async {
        await restore(expired: false);
        final repository = SupabaseAccountDeletionRepository(
          h.client,
          offline: tasks,
        );
        repository.prepareEntryCheck();
        await Future<void>.delayed(Duration.zero);
        expect(h.calls, hasLength(1));
        await h.client.auth.setInitialSession(jsonEncode(session(user: user)));
        h.handle = (r) =>
            MockSupabase.json(r, {'id': 'job', 'status': 'pending'});
        expect((await repository.status())?['id'], 'job');
        expect(h.calls, hasLength(2));
        expect(await store.accountDeletionJob(user), 'job');
      },
    );

    test('a replacement session for $user rechecks the server', () async {
      await restore();
      recordFailure();
      await h.client.auth.setInitialSession(jsonEncode(session(user: user)));
      expect(await container.read(familiesProvider.future), isEmpty);
      expect(
        h.calls.any((r) => r.url.path.endsWith('accept_family_invitations')),
        isTrue,
      );
    });
  }

  test(
    'the prepared account check is used once and local deletion still wins',
    () async {
      await restore(expired: false);
      final repository = SupabaseAccountDeletionRepository(
        h.client,
        offline: tasks,
      )..prepareEntryCheck();
      await store.removeAccountData('parent', 'local-job');
      expect((await repository.status())?['id'], 'local-job');
      expect(h.calls, hasLength(1));
      expect((await repository.status())?['id'], 'local-job');
      expect(h.calls, hasLength(2));
    },
  );

  for (final offline in [false, true]) {
    test(
      'a pending account status respects a newer local deletion, offline=$offline',
      () async {
        await restore(expired: false);
        final entered = Completer<void>();
        final release = Completer<void>();
        h.handle = (request) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          if (offline) throw http.ClientException('offline');
          return MockSupabase.json(request, null);
        };
        final repo = SupabaseAccountDeletionRepository(
          h.client,
          offline: tasks,
        );
        var cleared = false;
        final result = repo.status(onOnlineClear: (_) => cleared = true);
        await entered.future;
        await store.removeAccountData('parent', 'accepted-locally');
        release.complete();
        expect((await result)?['id'], 'accepted-locally');
        expect(cleared, isFalse);
      },
    );
  }

  test(
    'a denied membership discards the cache even when tombstones time out',
    () async {
      await restore(expired: false);
      final online = h.handle;
      h.handle = (r) => r.url.path.endsWith('/child_deletion_tombstones')
          ? throw http.ClientException('offline')
          : online(r);
      final membership = FamilyAccessRepository(
        store: store,
        accountId: () => h.client.auth.currentUser?.id,
        load: () async =>
            throw const PostgrestException(message: 'denied', code: '42501'),
        cancelNotifications: (_) async {},
      );
      addTearDown(membership.dispose);
      final repository = OfflineFamilyRepository(
        h.client,
        store,
        () => h.client.auth.currentUser?.id,
        access: membership,
      );
      await expectLater(
        repository.loadFamilies(),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      expect(await store.read('parent', 'families'), isNull);
    },
  );

  test(
    'an unreachable business RPC with a valid token still checks families',
    () async {
      await restore(expired: false);
      final online = h.handle;
      h.handle = (r) => r.url.path.endsWith('account_deletion_status')
          ? throw http.ClientException('business endpoint unreachable')
          : online(r);
      expect(
        await container.read(accountDeletionStatusProvider.future),
        isNull,
      );
      expect(await container.read(familiesProvider.future), isEmpty);
      expect(h.calls.first.url.path, endsWith('account_deletion_status'));
      expect(h.calls[1].url.path, endsWith('accept_family_invitations'));
    },
  );

  test(
    'a reachable child tombstone is honored during a membership outage',
    () async {
      await restore(expired: false);
      await store.write('parent', 'families', {
        'items': [
          {
            'id': 'old',
            'name': 'Cached',
            'timezone': 'UTC',
            'children': [
              {'id': 'removed'},
            ],
          },
        ],
      });
      final online = h.handle;
      h.handle = (r) => r.url.path.endsWith('/child_deletion_tombstones')
          ? MockSupabase.json(r, [
              {'child_id': 'removed'},
            ])
          : online(r);
      final membership = FamilyAccessRepository(
        store: store,
        accountId: () => h.client.auth.currentUser?.id,
        load: () async => throw http.ClientException('offline'),
        cancelNotifications: (_) async {},
      );
      addTearDown(membership.dispose);
      final repository = OfflineFamilyRepository(
        h.client,
        store,
        () => h.client.auth.currentUser?.id,
        access: membership,
      );
      expect(await repository.loadFamilies(), isEmpty);
      expect(await store.isChildDeleted('removed'), isTrue);
    },
  );

  test(
    'a complete directory restricts families, children and queued work before an offline fallback',
    () async {
      await restore(expired: false);
      Map<String, dynamic> family(String id, List<String> children) => {
        'id': id,
        'name': id,
        'timezone': 'UTC',
        'children': [
          for (final child in children)
            {'id': child, 'family_id': id, 'nickname': child, 'grade': 2},
        ],
      };
      final initial = [
        family('old', ['lost']),
        family('kept', ['left', 'stays']),
      ];
      await store.write('parent', 'families', {'items': initial});
      for (final child in ['left', 'stays', 'lost']) {
        final familyId = child == 'lost' ? 'old' : 'kept';
        for (final account in ['parent', 'other']) {
          await store.write(account, 'tasks:$child', {
            'family_id': familyId,
            'tasks': [],
          });
          await store.writeImageDraft(
            account,
            child,
            familyId,
            'draft-$child',
            {},
            Uint8List(4),
            null,
          );
          await store.enqueue(account, child, {
            'command_id': 'command-$child',
            'task_id': child,
          });
        }
      }
      final online = h.handle;
      var directory = [
        family('kept', ['stays']),
      ];
      var partial = true;
      h.handle = (r) => r.url.path.endsWith('/families')
          ? MockSupabase.json(r, directory)
          : online(r);
      final membership = FamilyAccessRepository(
        store: store,
        accountId: () => h.client.auth.currentUser?.id,
        load: () async {
          if (partial) throw http.ClientException('membership unavailable');
          return {'owner_id': 'parent', 'states': []};
        },
        cancelNotifications: (_) async {},
      );
      addTearDown(membership.dispose);
      final repository = OfflineFamilyRepository(
        h.client,
        store,
        () => h.client.auth.currentUser?.id,
        access: membership,
      );
      Future<void> checkRestricted() async {
        final families = await repository.loadFamilies();
        expect(families.single.id, 'kept');
        expect(families.single.children.single.id, 'stays');
        for (final child in ['lost', 'left']) {
          expect(await store.read('parent', 'tasks:$child'), isNull);
          expect(await store.readTaskSummary('parent', child), isNull);
          expect(await store.imageDraft('parent', 'draft-$child'), isNull);
          expect(await store.read('other', 'tasks:$child'), isNotNull);
          expect(await store.imageDraft('other', 'draft-$child'), isNotNull);
          expect(await store.isChildDeleted(child), isFalse);
        }
        expect((await store.commands('parent')).single['child_id'], 'stays');
        expect((await store.imageDrafts('parent')).single['child_id'], 'stays');
      }

      await checkRestricted();
      final fetch = h.handle;
      h.handle = (_) => throw http.ClientException('offline');
      await checkRestricted();
      h.handle = fetch;
      directory = initial;
      await checkRestricted();
      partial = false;
      expect(
        (await repository.loadFamilies()).expand((f) => f.children).length,
        3,
      );
      expect(await store.commands('parent'), hasLength(3));
      expect(await store.imageDrafts('parent'), hasLength(3));
    },
  );

  test('a later family page failure cannot revoke a cached family', () async {
    await restore(expired: false);
    final online = h.handle;
    var pages = 0;
    h.handle = (r) {
      if (!r.url.path.endsWith('/families')) return online(r);
      if (++pages > 1) throw http.ClientException('page unavailable');
      return MockSupabase.json(
        r,
        List.generate(
          1000,
          (i) => {
            'id': 'new-$i',
            'created_at': '2026-11-01T00:00:00Z',
            'name': 'New',
            'timezone': 'UTC',
            'children': [],
          },
        ),
      );
    };
    expect((await container.read(familiesProvider.future)).single.id, 'old');
    expect(pages, greaterThanOrEqualTo(2));
    expect(await store.familyAccessRevoked('parent', familyId: 'old'), isFalse);
  });

  test('a late older directory cannot reopen a missing family', () async {
    await restore(expired: false);
    final online = h.handle;
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    late http.Request first;
    h.handle = (r) {
      if (!r.url.path.endsWith('/families')) return online(r);
      if (entered.isCompleted) return MockSupabase.json(r, []);
      first = r;
      entered.complete();
      return reply.future;
    };
    final repository = OfflineFamilyRepository(
      h.client,
      store,
      () => h.client.auth.currentUser?.id,
    );
    final older = repository.loadFamilies();
    await entered.future;
    expect(await repository.loadFamilies(), isEmpty);
    reply.complete(
      MockSupabase.json(first, [
        {'id': 'old', 'name': 'Stale', 'timezone': 'UTC', 'children': []},
      ]),
    );
    await expectLater(older, throwsStateError);
    expect(await store.familyAccessRevoked('parent', familyId: 'old'), isTrue);
    expect((await store.read('parent', 'families'))!['items'], isEmpty);
  });

  test(
    'a deletion marker still blocks the cached family during handoff',
    () async {
      await restore();
      recordFailure();
      await store.removeAccountData('parent', 'job');
      await expectLater(
        container.read(familiesProvider.future),
        throwsA(isA<AuthRetryableFetchException>()),
      );
      expect(h.calls, isEmpty);
    },
  );

  test(
    'revoked memberships and deleted children stay removed during handoff',
    () async {
      await restore();
      await store.write('parent', 'families', {
        'items': [
          {'id': 'old', 'name': 'Revoked', 'timezone': 'UTC', 'children': []},
          {
            'id': 'kept',
            'name': 'Kept',
            'timezone': 'UTC',
            'children': [
              {'id': 'child'},
            ],
          },
        ],
      });
      recordFailure();
      await store.applyFamilyAccess('parent', [
        FamilyAccessState(
          familyId: 'old',
          version: 2,
          active: false,
          lastRevokedVersion: 2,
          childIds: {},
        ),
      ]);
      await store.removeChildData('child');
      final families = await container.read(familiesProvider.future);
      expect(families.single.name, 'Kept');
      expect(families.single.children, isEmpty);
      expect(h.calls, isEmpty);
    },
  );

  test(
    'confirmed account deletion on reconnect does not restart family queries',
    () async {
      await restore();
      recordFailure();
      expect(
        (await container.read(familiesProvider.future)).single.name,
        'Cached',
      );
      final online = h.handle;
      h.handle = (r) => r.url.path.endsWith('account_deletion_status')
          ? MockSupabase.json(r, {'id': 'job', 'status': 'running'})
          : online(r);
      expect(
        (await container.read(accountDeletionStatusProvider.future))?['id'],
        'job',
      );
      expect(await store.read('parent', 'families'), isNull);
      expect(h.calls.map((r) => r.url.path), [
        '/auth/v1/token',
        '/rest/v1/rpc/account_deletion_status',
      ]);
    },
  );
}

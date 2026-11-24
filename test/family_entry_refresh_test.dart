import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'email_login_test.dart' show Harness, session;
import 'support/mock_supabase.dart' show MockSupabase;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late OfflineStore store;
  late OfflineTaskRepository tasks;
  late ProviderContainer container;
  setUp(() {
    h = Harness();
    store = OfflineStore(NativeDatabase.memory());
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

  for (final user in ['parent', 'different']) {
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

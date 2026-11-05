import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/data_management/data/child_deletion_repository.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/worksheets/data/worksheet_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/cleanup_repository.dart';
import 'support/mock_supabase.dart';

void main() {
  late MockSupabase backend;
  setUp(() async {
    backend = MockSupabase();
    await backend.signIn();
  });
  tearDown(() async {
    await backend.close();
  });
  const child = 'child', job = 'job', worksheet = 'sheet';
  test(
    'cleanup freezes confirmed selection, clears related drafts, and starts only the original job',
    () async {
      final cacheEntered = Completer<void>(),
          release = Completer<void>(),
          cleared = <List<Object>>[];
      final repo = SupabaseCleanupRepository(
        backend.client,
        clearReviewCache: (child, scope, ids, drafts) async {
          cleared.add([child, scope, ids, drafts]);
          if (cleared.length == 1) {
            cacheEntered.complete();
            await release.future;
          }
        },
      );
      backend.handle = (request) {
        final body = MockSupabase.body(request);
        if (request.url.path.endsWith('/preview_question_cleanup')) {
          return MockSupabase.json(request, {'questions': 2, 'images': 1});
        }
        if (request.url.path.endsWith('/request_question_cleanup')) {
          return MockSupabase.json(request, body['request_id']);
        }
        if (request.url.path.endsWith('/cleanup_jobs')) {
          return MockSupabase.json(request, {
            'child_id': child,
            'scope': 'questions',
            'question_ids': ['q1', 'q2'],
            'draft_ids': ['draft'],
          });
        }
        return MockSupabase.json(request, {
          'job_id': body['job_id'],
          'status': 'running',
        }, status: 202);
      };
      expect(
        (await repo.preview(child, 'questions', ['q1', 'q2']))['questions'],
        2,
      );
      final ids = ['q1', 'q2'],
          pending = repo.request(child, 'questions', ids, job, '永久删除');
      await cacheEntered.future;
      ids.clear();
      release.complete();
      await pending;
      final requested = MockSupabase.body(
        backend.calls.firstWhere(
          (r) => r.url.path.endsWith('/request_question_cleanup'),
        ),
      );
      expect(requested['ids'], ['q1', 'q2']);
      expect(requested['confirmation'], '永久删除');
      expect(requested['request_id'], job);
      expect(cleared.last, [
        child,
        'questions',
        ['q1', 'q2'],
        ['draft'],
      ]);
      expect(MockSupabase.body(backend.calls.last), {'job_id': job});
    },
  );
  test(
    'cleanup rejects mismatched receipts, failed workers and stale-account preview or completion',
    () async {
      final repo = SupabaseCleanupRepository(backend.client);
      backend.handle = (r) => MockSupabase.json(r, 'other-job');
      await expectLater(
        repo.request(child, 'questions', ['q'], job, '永久删除'),
        throwsStateError,
      );
      expect(
        backend.calls.where((r) => r.url.path.contains('/functions/')),
        isEmpty,
      );
      backend.handle = (r) =>
          MockSupabase.json(r, {'job_id': job, 'status': 'failed'});
      await expectLater(repo.retry(job), throwsStateError);
      for (final preview in [true, false]) {
        await backend.signIn();
        final entered = Completer<void>(), hold = Completer<void>();
        backend.handle = (r) async {
          entered.complete();
          await hold.future;
          return MockSupabase.json(
            r,
            preview ? {'questions': 1} : {'job_id': job, 'status': 'completed'},
          );
        };
        final pending = preview
            ? repo.preview(child, 'questions', ['q'])
            : repo.retry(job);
        final rejected = expectLater(pending, throwsStateError);
        await entered.future;
        await backend.signIn(MockSupabase.secondUser);
        hold.complete();
        await rejected;
      }
    },
  );
  test(
    'cleanup and worksheet history page every 500 rows with child scope and stable order',
    () async {
      final cleanup = SupabaseCleanupRepository(backend.client),
          sheets = SupabaseWorksheetRepository(backend.client);
      backend.handle = (r) {
        expect(r.url.queryParameters['child_id'], 'eq.$child');
        final order = r.url.queryParameters['order']!.split(',');
        expect(order.first, startsWith('created_at.desc'));
        expect(order.last, startsWith('id.'));
        final offset = int.parse(r.url.queryParameters['offset'] ?? '0');
        expect(r.url.queryParameters['limit'], '500');
        if (r.url.path.endsWith('/cleanup_jobs')) {
          expect(r.url.queryParameters['select'], isNot(contains('manifest')));
        }
        return MockSupabase.json(
          r,
          List.generate(
            offset == 0 ? 500 : 1,
            (i) => {'id': '${offset + i}', 'status': 'completed'},
          ),
        );
      };
      expect(await cleanup.jobs(child), hasLength(501));
      expect(await sheets.history(child), hasLength(501));
      expect(backend.calls, hasLength(4));
    },
  );
  test(
    'child deletion forgets local data only after matching acceptance and checks retry worker identity',
    () async {
      final forgotten = <String>[],
          repo = SupabaseChildDeletionRepository(
            backend.client,
            forgetChild: (id) async => forgotten.add(id),
          );
      bool mismatch = true, failed = false;
      backend.handle = (r) {
        if (r.url.path.endsWith('/preview_child_deletion')) {
          return MockSupabase.json(r, {
            'counts': {'tasks': 3},
          });
        }
        if (r.url.path.endsWith('/request_child_deletion')) {
          return MockSupabase.json(r, mismatch ? 'other' : job);
        }
        if (r.url.path.endsWith('/child_deletion_history')) {
          return MockSupabase.json(r, [
            {'id': job, 'status': 'running'},
          ]);
        }
        return MockSupabase.json(r, {
          'job_id': job,
          'status': failed ? 'failed' : 'completed',
        });
      };
      final preview = await repo.preview(child);
      await expectLater(
        repo.request(
          child,
          job,
          Map<String, dynamic>.from(preview['counts'] as Map),
        ),
        throwsStateError,
      );
      expect(forgotten, isEmpty);
      mismatch = false;
      await repo.request(child, job, {'tasks': 3});
      expect(forgotten, [child]);
      final body = MockSupabase.body(backend.calls.last);
      expect(body['expected_counts'], {'tasks': 3});
      expect(body['confirmation'], '永久删除孩子');
      expect((await repo.history('family')).single['id'], job);
      await repo.retry(job);
      failed = true;
      await expectLater(repo.retry(job), throwsStateError);
      await backend.client.auth.signOut(scope: SignOutScope.local);
      await expectLater(repo.preview(child), throwsStateError);
    },
  );
  test(
    'worksheet retries keep request identity and content; wrong acknowledgements cannot dispatch another render or cleanup',
    () async {
      final repo = SupabaseWorksheetRepository(backend.client);
      bool unknown = true, mismatch = false;
      backend.handle = (r) {
        final body = MockSupabase.body(r);
        if (r.url.path.endsWith('/request_worksheet')) {
          if (unknown) {
            unknown = false;
            throw const SocketException('reply lost after commit');
          }
          return MockSupabase.json(r, mismatch ? 'other' : worksheet);
        }
        if (r.url.path.endsWith('/request_worksheet_cleanup')) {
          return MockSupabase.json(r, mismatch ? 'other' : job);
        }
        if (r.url.path.endsWith('/worksheet-render')) {
          return MockSupabase.json(r, {
            'id': body['worksheet_id'],
            'status': 'running',
          }, status: 202);
        }
        return MockSupabase.json(r, {
          'job_id': body['job_id'],
          'status': 'completed',
        });
      };
      const config = {'include_answers': false, 'include_explanations': true};
      await expectLater(
        repo.create(child, ['q2', 'q1'], config, worksheet),
        throwsA(isA<SocketException>()),
      );
      expect(backend.calls, hasLength(1));
      await repo.create(child, ['q2', 'q1'], config, worksheet);
      final bodies = backend.calls
          .where((r) => r.url.path.endsWith('/request_worksheet'))
          .map(MockSupabase.body)
          .toList();
      expect(bodies[0], bodies[1]);
      expect(bodies[1]['question_ids'], ['q2', 'q1']);
      mismatch = true;
      final before = backend.calls.length;
      await expectLater(
        repo.create(child, ['q2', 'q1'], config, worksheet),
        throwsStateError,
      );
      expect(backend.calls.length, before + 1);
      await expectLater(repo.delete(worksheet, job), throwsStateError);
      mismatch = false;
      await repo.delete(worksheet, job);
      expect(MockSupabase.body(backend.calls.last), {'job_id': job});
      backend.handle = (r) =>
          MockSupabase.json(r, {'id': worksheet, 'status': 'failed'});
      await expectLater(repo.generate(worksheet), throwsStateError);
    },
  );
  test(
    'an account switch after worksheet creation or during rendering cannot confirm success or continue dispatch',
    () async {
      final repo = SupabaseWorksheetRepository(backend.client);
      for (final create in [true, false]) {
        await backend.signIn();
        backend.calls.clear();
        final entered = Completer<void>(), hold = Completer<void>();
        backend.handle = (r) async {
          entered.complete();
          await hold.future;
          return MockSupabase.json(
            r,
            create ? worksheet : {'id': worksheet, 'status': 'ready'},
          );
        };
        final pending = create
            ? repo.create(child, ['q'], {}, worksheet)
            : repo.generate(worksheet);
        final rejection = expectLater(pending, throwsStateError);
        await entered.future;
        await backend.signIn(MockSupabase.secondUser);
        hold.complete();
        await rejection;
        expect(backend.calls, hasLength(1));
      }
    },
  );
  test(
    'PDF download verifies retained status and bytes, and account changes block fetching the previous path',
    () async {
      final repo = SupabaseWorksheetRepository(backend.client),
          bytes = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF'));
      bool expired = false, tampered = false;
      Map<String, Object> metadata() => {
        'status': 'ready',
        'pdf_path': 'family/child/job.pdf',
        'byte_size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'expires_at': DateTime.now()
            .add(Duration(days: expired ? -1 : 1))
            .toIso8601String(),
      };
      backend.handle = (r) => r.url.path.contains('/storage/')
          ? http.Response.bytes(
              tampered ? [...bytes, 1] : bytes,
              200,
              request: r,
            )
          : MockSupabase.json(r, metadata());
      expect(await repo.download(worksheet), bytes);
      expect(
        backend.calls.last.url.path,
        contains('/worksheets/family/child/job.pdf'),
      );
      tampered = true;
      await expectLater(repo.download(worksheet), throwsStateError);
      expired = true;
      backend.calls.clear();
      await expectLater(repo.download(worksheet), throwsStateError);
      expect(backend.calls, hasLength(1));
      expired = false;
      final entered = Completer<void>(), hold = Completer<void>();
      backend.calls.clear();
      backend.handle = (r) async {
        entered.complete();
        await hold.future;
        return MockSupabase.json(r, metadata());
      };
      final pending = repo.download(worksheet);
      final rejection = expectLater(pending, throwsStateError);
      await entered.future;
      await backend.signIn(MockSupabase.secondUser);
      hold.complete();
      await rejection;
      expect(backend.calls, hasLength(1));
    },
  );
  test(
    'account deletion recovers an accepted request, persists a local barrier and retains it offline',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final offline = OfflineTaskRepository(
        store: store,
        remote: SupabaseTaskSyncRemote(backend.client),
        live: SupabaseTaskRepository(backend.client),
        accountId: () => backend.client.auth.currentUser?.id,
        autoSync: false,
      );
      final repo = SupabaseAccountDeletionRepository(
        backend.client,
        offline: offline,
      );
      bool lost = true, networkDown = false, mismatch = false;
      backend.handle = (r) {
        if (r.url.path.endsWith('/account_deletion_context')) {
          return MockSupabase.json(r, [
            {'family_id': 'family'},
          ]);
        }
        if (r.url.path.endsWith('/preview_account_deletion')) {
          return MockSupabase.json(r, {
            'child_ids': [child],
          });
        }
        if (r.url.path.endsWith('/request_account_deletion')) {
          if (lost) {
            lost = false;
            throw const SocketException('lost receipt');
          }
          return MockSupabase.json(r, mismatch ? 'other' : job);
        }
        if (r.url.path.endsWith('/account_deletion_status')) {
          if (networkDown) throw const SocketException('offline');
          return MockSupabase.json(r, {'id': job, 'status': 'running'});
        }
        return MockSupabase.json(r, {'status': 'accepted'}, status: 202);
      };
      try {
        await store.write(MockSupabase.firstUser, 'ai-request:$child', {
          'private': 'fixture',
        });
        expect(await repo.context(), hasLength(1));
        final scope = await repo.preview();
        await expectLater(
          repo.request(job, scope),
          throwsA(isA<SocketException>()),
        );
        expect(await store.accountDeletionJob(MockSupabase.firstUser), isNull);
        mismatch = true;
        await expectLater(repo.request(job, scope), throwsStateError);
        expect(await store.accountDeletionJob(MockSupabase.firstUser), isNull);
        mismatch = false;
        await repo.request(job, scope);
        expect(await store.accountDeletionJob(MockSupabase.firstUser), job);
        expect(await store.isChildDeleted(child), isTrue);
        expect(
          await store.read(MockSupabase.firstUser, 'ai-request:$child'),
          isNull,
        );
        expect((await repo.status())?['id'], job);
        networkDown = true;
        expect((await repo.status())?['offline'], isTrue);
        await repo.retry();
        backend.handle = (r) => MockSupabase.denied(r);
        await expectLater(repo.status(), throwsA(isA<PostgrestException>()));
        await backend.client.auth.signOut(scope: SignOutScope.local);
        expect(await repo.status(), isNull);
      } finally {
        await offline.dispose();
        await store.close();
      }
    },
  );
  test(
    'family loading groups child profiles correctly and purges all pages of deletion and revocation notices',
    () async {
      final repo = SupabaseFamilyRepository(backend.client);
      backend.handle = (r) {
        if (r.url.path.endsWith('/families')) {
          return MockSupabase.json(r, [
            {'id': 'f1', 'name': 'One', 'timezone': 'Asia/Shanghai'},
            {'id': 'f2', 'name': 'Two', 'timezone': 'UTC'},
          ]);
        }
        if (r.url.path.endsWith('/children')) {
          return MockSupabase.json(r, [
            {'id': 'c2', 'family_id': 'f2', 'nickname': 'B', 'grade': 2},
            {'id': 'c1', 'family_id': 'f1', 'nickname': 'A', 'grade': 1},
          ]);
        }
        if (r.url.path.endsWith('/child_deletion_tombstones')) {
          return MockSupabase.json(
            r,
            List.generate(
              (r.url.queryParameters['offset'] ?? '0') == '0' ? 500 : 1,
              (i) => {'child_id': 'deleted-$i'},
            ),
          );
        }
        if (r.url.path.endsWith('/family_access_revocations')) {
          return MockSupabase.json(r, [
            {
              'family_id': 'old',
              'child_ids': ['revoked-child'],
            },
          ]);
        }
        if (r.url.path.endsWith('/verify_parent_pin')) {
          return MockSupabase.json(r, [
            {
              'verified': true,
              'authorized_until': DateTime.now()
                  .add(const Duration(minutes: 5))
                  .toIso8601String(),
              'retry_at': null,
              'remaining_attempts': 5,
            },
          ]);
        }
        return MockSupabase.json(r, null);
      };
      final families = await repo.loadFamilies();
      expect(families[0].children.single.id, 'c1');
      expect(families[1].children.single.id, 'c2');
      expect(
        backend.calls.first.url.path,
        endsWith('/accept_family_invitations'),
      );
      expect(await repo.loadDeletedChildIds(), hasLength(502));
      await repo.setParentPin(familyId: 'f1', pin: '1234');
      await repo.inviteParent(familyId: 'f1', email: 'other@example.test');
      expect(
        (await repo.verifyParentPin(familyId: 'f1', pin: '1234')).verified,
        isTrue,
      );
      await repo.revokeParentAuthorization();
      backend.handle = (r) => MockSupabase.denied(r);
      await expectLater(
        repo.updateChild(
          childId: 'c1',
          nickname: 'A',
          grade: 2,
          expectedVersion: 3,
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(MockSupabase.body(backend.calls.last)['expected_version'], 3);
    },
  );
  test(
    'live task reads preserve server balances, child filters, priority order and automatic review generation',
    () async {
      final repo = SupabaseTaskRepository(backend.client);
      Map<String, Object> task(String id, String status, String priority) => {
        'id': id,
        'child_id': child,
        'title': id,
        'status': status,
        'task_priority': priority,
        'coin_reward': 10,
        'xp_reward': 20,
        'due_date': '2026-03-08',
        'accumulated_seconds': 60,
        'minimum_seconds': 0,
      };
      backend.handle = (r) {
        if (r.url.path.endsWith('/wallets')) {
          expect(r.url.queryParameters['child_id'], 'eq.$child');
          return MockSupabase.json(r, {
            'coin_balance': 100,
            'frozen_balance': 25,
            'xp': 200,
          });
        }
        if (r.url.path.endsWith('/generate_scheduled_tasks')) {
          return MockSupabase.json(r, 0);
        }
        if (r.url.path.endsWith('/task_instances')) {
          expect(r.url.queryParameters['child_id'], 'eq.$child');
          return MockSupabase.json(r, [
            task('ended', 'completed', 'required'),
            task('optional', 'ready', 'challenge'),
            task('must', 'ready', 'required'),
          ]);
        }
        return MockSupabase.json(r, null);
      };
      final wallet = await repo.loadWallet(child);
      expect(wallet.coins, 100);
      expect(wallet.frozen, 25);
      expect(wallet.xp, 200);
      final tasks = await repo.loadTasks(child);
      expect(tasks.map((t) => t.id), ['must', 'optional', 'ended']);
      expect(tasks.first.coinReward, 10);
      expect(backend.calls.skip(1).map((r) => r.url.path.split('/').last), [
        'generate_daily_wrong_review_task',
        'generate_scheduled_tasks',
        'task_instances',
      ]);
      expect(
        backend.calls.where((r) => r.url.path.contains('complete_task')),
        isEmpty,
      );
    },
  );
  test(
    'task mutations use RPCs and server rejections cannot be treated as successful local rewards',
    () async {
      final repo = SupabaseTaskRepository(backend.client);
      backend.handle = (r) => MockSupabase.json(r, null);
      await repo.createOneTimeTask(
        childId: child,
        title: '阅读',
        dueDate: DateTime(2026, 3, 8, 23, 59),
        coinReward: 10,
        xpReward: 20,
      );
      final config = MockSupabase.body(backend.calls.single)['config'] as Map;
      expect(config['starts_on'], '2026-03-08');
      expect(config['ends_on'], '2026-03-08');
      expect(config['recurrence'], 'once');
      await repo.start('task');
      await repo.pause('task');
      await repo.resume('task');
      await repo.abandon('task');
      await repo.complete('task');
      await repo.manualComplete('task', '家长已检查');
      final completion = MockSupabase.body(backend.calls[5]),
          manual = MockSupabase.body(backend.calls[6]);
      expect(completion['completion_key'], startsWith('task:task:'));
      expect(completion.containsKey('coin_reward'), isFalse);
      expect(manual['parent_reason'], '家长已检查');
      backend.handle = (r) => MockSupabase.denied(r);
      await expectLater(
        repo.complete('task'),
        throwsA(isA<PostgrestException>()),
      );
    },
  );
}

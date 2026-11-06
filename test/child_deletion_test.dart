import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/data_management/data/child_deletion_repository.dart';
import 'package:learning_planet/features/data_management/presentation/child_deletion_screen.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';

class FakeDeletion implements ChildDeletionRepository {
  int previews = 0, histories = 0;
  final requests = <String>[];
  Object? failure;
  Completer<void>? gate;
  String? retried;
  String status = 'queued';
  @override
  Future<Map<String, dynamic>> preview(String childId) async {
    previews++;
    if (gate != null) await gate!.future;
    return {
      'child_id': childId,
      'family_id': 'family',
      'counts': {'tasks': 2, 'files': 3, 'coins': 10},
    };
  }

  @override
  Future<void> request(
    String childId,
    String requestId,
    Map<String, dynamic> counts,
  ) async {
    requests.add(requestId);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> retry(String jobId) async {
    retried = jobId;
    status = 'completed';
  }

  @override
  Future<List<Map<String, dynamic>>> history(String familyId) async {
    histories++;
    return [
      {
        'id': 'persisted-job',
        'child_id': 'deleted-child',
        'status': status,
        'created_at': '2026-11-04',
        'next_attempt_at': '2026-11-04',
        'completed_at': '2026-11-04',
      },
    ];
  }
}

void main() {
  test(
    'schema one upgrades without losing cached data or pending actions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-upgrade-',
      );
      final file = File('${directory.path}/cache.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      await store.write('parent', 'tasks:child', {'value': 'keep'});
      await store.enqueue('parent', 'child', {
        'command_id': 'pending',
        'task_id': 'task',
      });
      await store.customStatement('DROP TABLE deleted_children');
      await store.customStatement('DROP TABLE deleted_accounts');
      await store.customStatement('DROP TABLE family_access');
      await store.customStatement('PRAGMA user_version = 1');
      await store.customStatement('DROP TABLE image_drafts');
      await store.customStatement('DROP TABLE discarded_image_drafts');
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      try {
        expect(await store.isChildDeleted('child'), false);
        expect(await store.read('parent', 'tasks:child'), {'value': 'keep'});
        expect(
          (await store.commands('parent')).single['command_id'],
          'pending',
        );
        await store.removeChildData('child');
        expect(await store.commands('parent'), isEmpty);
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'family reconnect purges remote deletion markers and excludes a stale family response',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      await store.write('parent', 'tasks:deleted', {'private': 'stale'});
      await store.write('parent', 'tasks:revoked', {
        'private': 'dissolved family',
      });
      await store.enqueue('parent', 'deleted', {
        'command_id': 'pending',
        'task_id': 'task',
      });
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        httpClient: MockClient((request) async {
          final value = switch (request.url.path.split('/').last) {
            'accept_family_invitations' => null,
            'families' => [
              {'id': 'family', 'name': '家庭', 'timezone': 'Asia/Shanghai'},
            ],
            'children' => [
              for (final id in ['deleted', 'revoked', 'keep'])
                {'id': id, 'family_id': 'family', 'nickname': id, 'grade': 1},
            ],
            'child_deletion_tombstones' => [
              {'child_id': 'deleted'},
            ],
            'family_access_revocations' => [
              {
                'family_id': 'family',
                'child_ids': ['revoked'],
              },
            ],
            _ => throw StateError('Unexpected route'),
          };
          return http.Response(
            jsonEncode(value),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final repo = OfflineFamilyRepository(client, store, () => 'parent');
      expect((await repo.loadFamilies()).single.children.single.id, 'keep');
      expect(await store.read('parent', 'tasks:deleted'), isNull);
      expect(await store.commands('parent'), isEmpty);
      expect(await store.isChildDeleted('deleted'), true);
      expect(await store.isChildDeleted('revoked'), true);
      expect(await store.read('parent', 'tasks:revoked'), isNull);
    },
  );
  test(
    'child purge removes every local account copy and pending command while preserving siblings',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final staleFamilies = {
        'items': [
          {
            'id': 'family',
            'children': [
              {'id': 'deleted'},
              {'id': 'keep'},
            ],
          },
        ],
      };
      for (final owner in ['one', 'two']) {
        await store.write(owner, 'families', staleFamilies);
        await store.write(owner, 'tasks:deleted', {
          'tasks': [],
          'wallet': {'coins': 100},
        });
        await store.write(owner, 'tasks:keep', {
          'wallet': {'coins': 42},
        });
        await store.write(owner, 'review-questions:deleted', {
          'items': ['private'],
        });
        await store.write(owner, 'review-task:t', {
          'task': {'child_id': 'deleted'},
          'items': ['private'],
        });
        await store.write(owner, 'review-task:k', {
          'task': {'child_id': 'keep'},
          'items': ['keep'],
        });
        await store.enqueue(owner, 'deleted', {
          'command_id': 'gone',
          'task_id': 't',
        });
        await store.enqueue(owner, 'keep', {
          'command_id': 'keep',
          'task_id': 'k',
        });
      }
      final before = store.reviewGeneration('one');
      await store.removeChildData('deleted');
      for (final owner in ['one', 'two']) {
        expect(await store.read(owner, 'tasks:deleted'), isNull);
        expect(await store.read(owner, 'review-questions:deleted'), isNull);
        expect(await store.read(owner, 'review-task:t'), isNull);
        expect((await store.read(owner, 'tasks:keep'))!['wallet'], {
          'coins': 42,
        });
        expect(await store.read(owner, 'review-task:k'), isNotNull);
        expect((await store.commands(owner)).single['child_id'], 'keep');
        expect(
          ((await store.read(owner, 'families'))!['items'] as List)
              .single['children'],
          [
            {'id': 'keep'},
          ],
        );
      }
      await expectLater(
        store.writeReviewCache('one', 'review-task:t', {
          'task': {'child_id': 'deleted'},
        }, before),
        throwsStateError,
      );
      await expectLater(
        store.write('one', 'tasks:deleted', {
          'tasks': ['late'],
        }),
        throwsStateError,
      );
      await expectLater(
        store.enqueue('one', 'deleted', {'command_id': 'late', 'task_id': 't'}),
        throwsStateError,
      );
      await store.write('one', 'families', staleFamilies);
      expect(
        ((await store.read('one', 'families'))!['items'] as List)
            .single['children'],
        [
          {'id': 'keep'},
        ],
      );
    },
  );
  test(
    'deletion tombstones survive restart and block stale task cache reconstruction',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-deletion-',
      );
      final file = File('${directory.path}/cache.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      await store.write('parent', 'tasks:child', {'private': 'content'});
      await store.removeChildData('child');
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      try {
        expect(await store.isChildDeleted('child'), true);
        expect(await store.read('parent', 'tasks:child'), isNull);
        await expectLater(
          store.write('parent', 'tasks:child', {'private': 'late'}),
          throwsStateError,
        );
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  Future<ProviderContainer> mount(
    WidgetTester tester,
    FakeDeletion repo, {
    bool parent = true,
    bool historyOnly = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        authorizationClockProvider.overrideWith(
          (ref) => Stream.value(DateTime.now()),
        ),
        childDeletionRepositoryProvider.overrideWithValue(repo),
        notificationSchedulerProvider.overrideWithValue(
          const DisabledNotificationScheduler(),
        ),
      ],
    );
    container.read(parentModeProvider.notifier).state = parent;
    container.read(parentFamilyIdProvider.notifier).state = parent
        ? 'family'
        : null;
    container.read(parentAuthorizedUntilProvider.notifier).state =
        DateTime.now().add(const Duration(minutes: 5));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: ChildDeletionScreen(
            familyId: 'family',
            childId: historyOnly ? null : 'child',
            nickname: '小明',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> preview(WidgetTester tester) async {
    await tester.tap(find.text('预览删除范围'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('永久删除孩子'));
    await tester.tap(find.text('永久删除孩子'));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), '永久删除孩子');
    await tester.tap(find.text('确认永久删除'));
    await tester.pumpAndSettle();
  }

  testWidgets('child mode cannot preview deletion or read history', (
    tester,
  ) async {
    final repo = FakeDeletion();
    await mount(tester, repo, parent: false);
    expect(repo.histories, 0);
    expect(repo.previews, 0);
    expect(find.text('预览删除范围'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'deletion requires range preview and exact confirmation and never treats acceptance as file completion',
    (tester) async {
      final repo = FakeDeletion();
      await mount(tester, repo);
      await preview(tester);
      await tester.tap(find.text('确认永久删除'));
      await tester.pumpAndSettle();
      expect(repo.requests, isEmpty);
      await confirm(tester);
      expect(repo.requests.length, 1);
      expect(find.text('文件清理完成'), findsNothing);
      expect(find.text('永久删除孩子'), findsNothing);
      expect(find.textContaining('孩子业务数据已移除'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unknown acknowledgement retries the same UUID while changed scope requires new preview',
    (tester) async {
      final repo = FakeDeletion()..failure = TimeoutException('unknown result');
      await mount(tester, repo);
      await preview(tester);
      await confirm(tester);
      await tester.ensureVisible(find.text('重试同一删除请求'));
      await tester.tap(find.text('重试同一删除请求'));
      await tester.pumpAndSettle();
      expect(repo.requests.length, 2);
      expect(repo.requests.toSet().length, 1);
      repo.failure = const PostgrestException(
        message: 'changed range',
        code: '40001',
      );
      await tester.tap(find.text('重试同一删除请求'));
      await tester.pumpAndSettle();
      expect(find.text('重试同一删除请求'), findsNothing);
      expect(find.text('预览删除范围'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('PIN expiration during preview discards late private counts', (
    tester,
  ) async {
    final repo = FakeDeletion()..gate = Completer();
    final container = await mount(tester, repo);
    await tester.tap(find.text('预览删除范围'));
    await tester.pump();
    container.read(parentModeProvider.notifier).state = false;
    repo.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('永久删除孩子'), findsNothing);
    expect(repo.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'history remains available without any child and retries the persisted file job',
    (tester) async {
      final repo = FakeDeletion();
      await mount(tester, repo, historyOnly: true);
      expect(find.text('预览删除范围'), findsNothing);
      await tester.ensureVisible(find.text('重试/查询'));
      await tester.tap(find.text('重试/查询'));
      await tester.pumpAndSettle();
      expect(repo.retried, 'persisted-job');
      expect(repo.requests, isEmpty);
      expect(find.text('文件清理完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

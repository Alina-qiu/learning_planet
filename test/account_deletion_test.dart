import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/data_management/presentation/account_deletion_screen.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';

class FakeAccountDeletion implements AccountDeletionRepository {
  final requests = <String>[];
  Object? failure;
  Map<String, dynamic>? current;
  int retries = 0, previews = 0;
  bool pin = true;
  @override
  Future<List<Map<String, dynamic>>> context() async => [
    {
      'id': 'family',
      'name': '我的家庭',
      'owned': true,
      'authorized': pin,
      'authorized_until': DateTime.now()
          .add(const Duration(minutes: 5))
          .toIso8601String(),
    },
  ];
  @override
  Future<Map<String, dynamic>> preview() async {
    previews++;
    return {
      'scope': {
        'owned_family_ids': ['family'],
        'child_ids': ['child'],
        'children': [
          {
            'nickname': '小星',
            'counts': {'tasks': 2, 'coins': 100},
          },
        ],
        'files': 3,
        'shared_uploads': 1,
        'shared_worksheets': 0,
      },
    };
  }

  @override
  Future<void> request(String id, Map<String, dynamic> scope) async {
    requests.add(id);
    if (failure != null) throw failure!;
    current = {'id': id, 'status': 'queued', 'phase': 'files'};
  }

  @override
  Future<Map<String, dynamic>?> status() async => current;
  @override
  Future<void> retry() async {
    retries++;
    current = {...current!, 'status': 'completed', 'phase': 'done'};
  }
}

void main() {
  test(
    'account purge survives restart and rejects late writes without deleting another account',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-account-test-',
      );
      final file = File('${directory.path}/cache.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      for (final owner in ['removed', 'keep']) {
        await store.write(owner, 'tasks:child', {'private': owner});
        await store.write(owner, 'review-overview:child', {'private': owner});
        await store.enqueue(owner, 'child', {
          'command_id': 'pending',
          'task_id': 'task',
        });
      }
      await store.removeAccountData('removed', 'job');
      expect(await store.read('removed', 'tasks:child'), isNull);
      expect(await store.commands('removed'), isEmpty);
      expect(await store.read('keep', 'tasks:child'), {'private': 'keep'});
      expect(await store.commands('keep'), hasLength(1));
      await expectLater(
        store.write('removed', 'tasks:child', {'late': true}),
        throwsStateError,
      );
      await expectLater(
        store.enqueue('removed', 'child', {
          'command_id': 'late',
          'task_id': 'task',
        }),
        throwsStateError,
      );
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      try {
        expect(await store.accountDeletionJob('removed'), 'job');
        expect(await store.read('removed', 'review-overview:child'), isNull);
        await expectLater(
          store.acknowledge('removed', 'child', 'pending', {'late': true}),
          throwsStateError,
        );
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'schema two upgrade preserves child markers and existing queues',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-schema3-test-',
      );
      final file = File('${directory.path}/cache.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      await store.removeChildData('deleted-child');
      await store.enqueue('parent', 'keep-child', {
        'command_id': 'pending',
        'task_id': 'task',
      });
      await store.customStatement('DROP TABLE deleted_accounts');
      await store.customStatement('DROP TABLE family_access');
      await store.customStatement('PRAGMA user_version=2');
      await store.customStatement('DROP TABLE image_drafts');
      await store.customStatement('DROP TABLE discarded_image_drafts');
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      try {
        expect(await store.isChildDeleted('deleted-child'), true);
        expect(await store.commands('parent'), hasLength(1));
        await store.removeAccountData('parent', 'job');
        expect(await store.commands('parent'), isEmpty);
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  Future<void> mount(
    WidgetTester tester,
    FakeAccountDeletion repo, {
    Map<String, dynamic>? status,
    Stream<DateTime>? clock,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountDeletionRepositoryProvider.overrideWithValue(repo),
          authorizationClockProvider.overrideWith(
            (ref) => clock ?? Stream.value(DateTime.now()),
          ),
          notificationSchedulerProvider.overrideWithValue(
            const DisabledNotificationScheduler(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: AccountDeletionScreen(initialStatus: status),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester) async {
    await tester.ensureVisible(find.text('预览注销范围'));
    await tester.tap(find.text('预览注销范围'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, {bool retry = false}) async {
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '永久注销我的账号');
    await tester.pump();
    final button = find.widgetWithText(
      FilledButton,
      retry ? '重试同一注销申请' : '永久注销我的账号',
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('unverified family blocks account preview', (tester) async {
    final repo = FakeAccountDeletion()..pin = false;
    await mount(tester, repo);
    await preview(tester);
    expect(repo.previews, 0);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('PIN expiration hides preview and disables confirmation', (
    tester,
  ) async {
    final clock = StreamController<DateTime>();
    final repo = FakeAccountDeletion();
    await mount(tester, repo, clock: clock.stream);
    clock.add(DateTime.now());
    await tester.pumpAndSettle();
    await preview(tester);
    expect(find.byType(TextField), findsOneWidget);
    clock.add(DateTime.now().add(const Duration(minutes: 11)));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(repo.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    unawaited(clock.close());
  });
  testWidgets(
    'account preview requires exact phrase and acceptance is distinct from completion',
    (tester) async {
      final repo = FakeAccountDeletion();
      await mount(tester, repo);
      await preview(tester);
      final button = find.widgetWithText(FilledButton, '永久注销我的账号');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(repo.requests, isEmpty);
      expect(find.textContaining('将解散 1 个家庭'), findsOneWidget);
      await submit(tester);
      expect(repo.requests, hasLength(1));
      expect(find.text('注销已受理，正在清理'), findsOneWidget);
      expect(find.text('账号注销已完成'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unknown result reuses UUID and changed scope requires new preview',
    (tester) async {
      final repo = FakeAccountDeletion()..failure = TimeoutException('unknown');
      await mount(tester, repo);
      await preview(tester);
      await submit(tester);
      await submit(tester, retry: true);
      expect(repo.requests.toSet(), hasLength(1));
      repo.failure = const PostgrestException(
        message: 'scope changed',
        code: '40001',
      );
      await submit(tester, retry: true);
      expect(find.byType(TextField), findsNothing);
      repo.failure = null;
      await preview(tester);
      await submit(tester);
      expect(repo.requests.toSet(), hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'pending status survives without family data and shows completion only after query',
    (tester) async {
      final repo = FakeAccountDeletion()
        ..current = {'id': 'persisted', 'status': 'failed', 'phase': 'auth'};
      await mount(tester, repo, status: repo.current);
      expect(find.text('预览注销范围'), findsNothing);
      expect(repo.previews, 0);
      await tester.ensureVisible(find.text('重试处理'));
      await tester.tap(find.text('重试处理'));
      await tester.pumpAndSettle();
      expect(repo.retries, 1);
      expect(find.text('账号注销已完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

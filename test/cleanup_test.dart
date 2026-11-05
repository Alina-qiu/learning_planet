import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/cleanup_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/cleanup_screen.dart';

class FakeCleanup implements CleanupRepository {
  int requests = 0;
  String? retried, confirmation;
  String status = 'failed';
  @override
  Future<Map<String, dynamic>> preview(
    String child,
    String scope,
    List<String> ids,
  ) async => {
    'questions': ids.length,
    'drafts': 1,
    'files': 2,
    'unfinished_reviews': 1,
  };
  @override
  Future<void> request(
    String child,
    String scope,
    List<String> ids,
    String key,
    String confirmation,
  ) async {
    requests++;
    this.confirmation = confirmation;
    status = 'completed';
  }

  @override
  Future<void> retry(String jobId) async {
    retried = jobId;
    status = 'completed';
  }

  @override
  Future<List<Map<String, dynamic>>> jobs(String child) async => [
    {
      'id': 'same-persisted-job',
      'scope': 'questions',
      'status': status,
      'attempts': 1,
      'created_at': '2026-09-17',
    },
  ];
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeCleanup repo, {
    bool parent = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cleanupRepositoryProvider.overrideWithValue(repo),
          activeParentFamilyProvider.overrideWithValue(
            parent ? 'family' : null,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const CleanupScreen(
            childId: 'child',
            familyId: 'family',
            questionIds: ['q'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('permanent cleanup is unavailable without current family PIN', (
    tester,
  ) async {
    final repo = FakeCleanup();
    await mount(tester, repo, parent: false);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '永久删除所选 1 道题'),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('重试 / 查询'), findsNothing);
    expect(repo.requests, 0);
  });
  testWidgets(
    'preview requires exact irreversible confirmation before requesting deletion',
    (tester) async {
      final repo = FakeCleanup();
      await mount(tester, repo);
      await tester.tap(find.text('永久删除所选 1 道题'));
      await tester.pumpAndSettle();
      expect(find.textContaining('将作废 1 个未完成复习'), findsOneWidget);
      await tester.tap(find.text('确认永久删除'));
      await tester.pumpAndSettle();
      expect(repo.requests, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField), '永久删除');
      await tester.tap(find.text('确认永久删除'));
      await tester.pumpAndSettle();
      expect(repo.requests, 1);
      expect(repo.confirmation, '永久删除');
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    },
  );
  testWidgets(
    'failed cleanup retries persisted job instead of duplicating the request',
    (tester) async {
      final repo = FakeCleanup();
      await mount(tester, repo);
      await tester.tap(find.text('重试 / 查询'));
      await tester.pumpAndSettle();
      expect(repo.retried, 'same-persisted-job');
      expect(repo.requests, 0);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    },
  );
  test(
    'privacy purge clears review caches only for the current account',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      try {
        await store.write('a', 'review-task:task', {'prompt': 'private'});
        await store.write('a', 'review-questions:child', {
          'items': ['private'],
        });
        await store.write('a', 'wallet:child', {'coins': 20});
        await store.write('b', 'review-task:task', {'prompt': 'other account'});
        await store.removeReviewCache('a');
        expect(await store.read('a', 'review-task:task'), isNull);
        expect(await store.read('a', 'review-questions:child'), isNull);
        expect(await store.read('a', 'wallet:child'), {'coins': 20});
        expect(await store.read('b', 'review-task:task'), {
          'prompt': 'other account',
        });
      } finally {
        await store.close();
      }
    },
  );
}

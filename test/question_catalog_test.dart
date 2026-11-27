import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_catalog.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_hub_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'review_module_test.dart' show FakeReviewRepository;
import 'support/mock_supabase.dart';

QuestionCatalogScope scope({
  String keyword = '',
  String child = 'child',
  String family = 'family',
  String kind = 'question',
}) => (
  child: child,
  family: family,
  kind: kind,
  subject: 'all',
  mastery: 'all',
  archive: 'all',
  keyword: keyword,
);
Map<String, dynamic> row(
  int index, {
  String child = 'child',
  String kind = 'question',
}) => {
  'id': 'question-$index',
  'child_id': child,
  'review_kind': kind,
  'final_text': '题目 $index',
  'archived': false,
  'subject': 'math',
  'mastery_status': 'practicing',
  'wrong_count': 1,
  'review_attempts': 0,
  'review_due_at': null,
};
Map<String, dynamic> response(
  QuestionCatalogScope s, {
  int count = 1,
  int start = 0,
  bool more = false,
  String owner = MockSupabase.firstUser,
}) => {
  'owner_id': owner,
  'child_id': s.child,
  'family_id': s.family,
  'filters': catalogFilters(s),
  'server_time': '2026-11-05T01:02:03Z',
  'items': [
    for (var i = start; i < start + count; i++)
      row(i, child: s.child, kind: s.kind),
  ],
  'next_cursor': more
      ? {
          'id': 'question-${start + count - 1}',
          'archived': false,
          'due_at': null,
        }
      : null,
};
const denied = PostgrestException(message: 'denied', code: '42501');

class CatalogTransactionStore extends OfflineStore {
  CatalogTransactionStore() : super(NativeDatabase.memory());
  void Function()? afterEviction;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (statement.contains('OFFSET 12')) afterEviction?.call();
  }
}

class ScriptedCatalog implements QuestionCatalogRepository {
  ScriptedCatalog(this.read);
  final Future<QuestionCatalogPage> Function(
    QuestionCatalogScope,
    Map<String, dynamic>?,
  )
  read;
  @override
  Future<QuestionCatalogPage> page(
    QuestionCatalogScope scope, [
    Map<String, dynamic>? cursor,
  ]) => read(scope, cursor);
  @override
  void dispose() {}
}

void main() {
  test(
    'production provider reads only bounded RPC with filters and exact continuation',
    () async {
      final api = MockSupabase();
      await api.signIn();
      final s = scope(keyword: '  题目  ');
      api.handle = (request) {
        expect(request.url.path, '/rest/v1/rpc/question_catalog_page');
        final body = MockSupabase.body(request);
        expect(body['target_child_id'], 'child');
        expect(body['filters'], catalogFilters(s));
        return MockSupabase.json(
          request,
          response(
            s,
            start: body['cursor'] == null ? 0 : 50,
            count: body['cursor'] == null ? 50 : 1,
            more: body['cursor'] == null,
          ),
        );
      };
      final container = ProviderContainer(
        overrides: [
          reviewRepositoryProvider.overrideWithValue(
            SupabaseReviewRepository(api.client),
          ),
        ],
      );
      try {
        final repository = container.read(questionCatalogRepositoryProvider);
        final first = await repository.page(s);
        expect(first.items.length, 50);
        final second = await repository.page(s, first.next);
        expect(second.items.single['id'], 'question-50');
        expect(MockSupabase.body(api.calls.last)['cursor'], first.next);
        expect(api.calls.length, 2);
      } finally {
        container.dispose();
        await api.close();
      }
    },
  );

  test(
    'first page persists across reopen and offline results never offer uncached continuation',
    () async {
      final directory = await Directory.systemTemp.createTemp('catalog-test-');
      final file = File('${directory.path}/catalog.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      final s = scope();
      try {
        final online = ScopedQuestionCatalog(
          store: store,
          owner: () => MockSupabase.firstUser,
          fetch: (_, _, _) async => response(s, count: 50, more: true),
        );
        await online.page(s);
        online.dispose();
        await store.close();
        store = OfflineStore(NativeDatabase(file));
        final offline = ScopedQuestionCatalog(
          store: store,
          owner: () => MockSupabase.firstUser,
          fetch: (_, _, _) async => throw const SocketException('offline'),
        );
        final restored = await offline.page(s);
        expect(restored.items.length, 50);
        expect(restored.offline, isTrue);
        expect(restored.next, isNull);
        expect(restored.syncedAt, DateTime.utc(2026, 11, 5, 1, 2, 3));
        await expectLater(
          offline.page(scope(keyword: 'new filter')),
          throwsA(isA<SocketException>()),
        );
        await expectLater(
          offline.page(s, {'id': 'question-49'}),
          throwsA(isA<SocketException>()),
        );
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'permission and malformed replies discard cached first pages instead of offline fallback',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final s = scope();
      Object? failure;
      var data = response(s);
      final repository = ScopedQuestionCatalog(
        store: store,
        owner: () => MockSupabase.firstUser,
        fetch: (_, _, _) async {
          if (failure != null) throw failure;
          return data;
        },
      );
      try {
        for (final error in [denied, StateError('invalid response')]) {
          failure = null;
          data = response(s);
          await repository.page(s);
          if (error is PostgrestException) {
            failure = error;
          } else {
            data = {...data, 'family_id': 'foreign'};
          }
          await expectLater(
            repository.page(s),
            throwsA(
              error is PostgrestException
                  ? isA<PostgrestException>()
                  : isA<StateError>(),
            ),
          );
          expect(
            await store.read(MockSupabase.firstUser, repository.cacheKey(s)),
            isNull,
          );
        }
      } finally {
        await store.close();
      }
    },
  );

  test(
    'catalog validates identity filters duplicate rows deletion and continuation metadata',
    () async {
      final s = scope();
      final variants = <Map<String, dynamic>>[
        {...response(s), 'owner_id': 'foreign'},
        {...response(s), 'child_id': 'other'},
        {...response(s), 'family_id': 'other'},
        {
          ...response(s),
          'filters': {...catalogFilters(s), 'archive': 'active'},
        },
        {
          ...response(s),
          'filters': {...catalogFilters(s), 'unknown': true},
        },
        {
          ...response(s),
          'items': [row(0), row(0)],
        },
        {
          ...response(s),
          'items': [
            {...row(0), 'deleting': true},
          ],
        },
        {
          ...response(s),
          'items': [row(0, kind: 'pinyin')],
        },
        {
          ...response(s),
          'items': [row(0, child: 'other')],
        },
        {...response(s), 'server_time': 'not-a-date'},
        response(s, count: 51),
        response(s, more: true),
        {
          ...response(s, count: 50),
          'next_cursor': {
            'id': 'question-0',
            'archived': false,
            'due_at': null,
          },
        },
      ];
      for (final invalid in variants) {
        final repository = ScopedQuestionCatalog(
          store: null,
          owner: () => MockSupabase.firstUser,
          fetch: (_, _, _) async => invalid,
        );
        await expectLater(repository.page(s), throwsStateError);
      }
    },
  );

  test(
    'cache retains only twelve filter first pages and scoped cleanup removes them',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final repository = ScopedQuestionCatalog(
        store: store,
        owner: () => MockSupabase.firstUser,
        fetch: (child, filters, _) async => {
          ...response(
            scope(
              keyword: filters['keyword'] as String,
              child: child,
              family: child == 'other' ? 'other-family' : 'family',
            ),
            count: 0,
          ),
          'server_time': DateTime.utc(
            2026,
            11,
            5,
            0,
            0,
            int.tryParse(filters['keyword'] as String) ?? 0,
          ).toIso8601String(),
        },
      );
      try {
        await repository.page(scope(child: 'other', family: 'other-family'));
        for (var i = 0; i < 15; i++) {
          await repository.page(scope(keyword: '$i'));
        }
        final rows = await store
            .customSelect('SELECT cache_key FROM offline_cache')
            .get();
        expect(rows.length, 13);
        expect(
          await store.read(
            MockSupabase.firstUser,
            repository.cacheKey(scope(keyword: '0')),
          ),
          isNull,
        );
        expect(
          await store.read(
            MockSupabase.firstUser,
            repository.cacheKey(scope(keyword: '14')),
          ),
          isNotNull,
        );
        await store.removeReviewCache(MockSupabase.firstUser, childId: 'child');
        expect(
          (await store
                  .customSelect('SELECT cache_key FROM offline_cache')
                  .get())
              .length,
          1,
        );
        await repository.page(scope());
        await store.removeChildData('child');
        expect(
          (await store
                  .customSelect('SELECT cache_key FROM offline_cache')
                  .get())
              .length,
          1,
        );
        await expectLater(repository.page(scope()), throwsStateError);
        await store.applyFamilyAccess(MockSupabase.firstUser, [
          FamilyAccessState(
            familyId: 'other-family',
            version: 2,
            active: false,
            lastRevokedVersion: 2,
            childIds: {'other'},
          ),
        ]);
        expect(
          await store.read(
            MockSupabase.firstUser,
            repository.cacheKey(scope(child: 'other', family: 'other-family')),
          ),
          isNull,
        );
        await expectLater(
          repository.page(scope(child: 'other', family: 'other-family')),
          throwsStateError,
        );
      } finally {
        await store.close();
      }
    },
  );

  test(
    'delayed responses cannot restore snapshots after owner disposal child or membership changes',
    () async {
      for (final change in [
        'owner',
        'dispose',
        'review',
        'child',
        'family',
        'account',
      ]) {
        final store = OfflineStore(NativeDatabase.memory());
        String? owner = MockSupabase.firstUser;
        final started = Completer<void>(),
            reply = Completer<Map<String, dynamic>>();
        final repository = ScopedQuestionCatalog(
          store: store,
          owner: () => owner,
          fetch: (_, _, _) {
            started.complete();
            return reply.future;
          },
        );
        try {
          final pending = repository.page(scope());
          final rejected = expectLater(pending, throwsStateError);
          await started.future;
          switch (change) {
            case 'owner':
              owner = MockSupabase.secondUser;
            case 'dispose':
              repository.dispose();
            case 'review':
              await store.removeReviewCache(MockSupabase.firstUser);
            case 'child':
              await store.removeChildData('child');
            case 'account':
              await store.removeAccountData(MockSupabase.firstUser, 'job');
            case 'family':
              await store.applyFamilyAccess(MockSupabase.firstUser, [
                FamilyAccessState(
                  familyId: 'family',
                  version: 2,
                  active: false,
                  lastRevokedVersion: 2,
                  childIds: {'child'},
                ),
              ]);
          }
          reply.complete(response(scope()));
          await rejected;
          expect(
            await store.read(
              MockSupabase.firstUser,
              repository.cacheKey(scope()),
            ),
            isNull,
          );
        } finally {
          await store.close();
        }
      }
    },
  );

  test(
    'an owner change during eviction rolls back the new first page and restores the evicted page',
    () async {
      final store = CatalogTransactionStore();
      String owner = MockSupabase.firstUser;
      final repository = ScopedQuestionCatalog(
        store: store,
        owner: () => owner,
        fetch: (_, filters, _) async {
          final keyword = filters['keyword'] as String;
          return {
            ...response(scope(keyword: keyword), count: 0),
            'server_time': DateTime.utc(
              2026,
              11,
              5,
              0,
              int.parse(keyword),
            ).toIso8601String(),
          };
        },
      );
      try {
        for (var i = 0; i < 12; i++) {
          await repository.page(scope(keyword: '$i'));
        }
        store.afterEviction = () {
          owner = MockSupabase.secondUser;
        };
        await expectLater(
          repository.page(scope(keyword: '12')),
          throwsStateError,
        );
        final rows = await store
            .customSelect('SELECT cache_key FROM offline_cache')
            .get();
        expect(rows.map((r) => r.read<String>('cache_key')).toSet(), {
          for (var i = 0; i < 12; i++)
            repository.cacheKey(scope(keyword: '$i')),
        });
      } finally {
        await store.close();
      }
    },
  );

  test(
    'an older filter request cannot overwrite the refreshed page cache',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final started = Completer<void>(),
          oldReply = Completer<Map<String, dynamic>>();
      var call = 0;
      final repository = ScopedQuestionCatalog(
        store: store,
        owner: () => MockSupabase.firstUser,
        fetch: (_, _, _) {
          if (++call == 1) {
            started.complete();
            return oldReply.future;
          }
          return Future.value(response(scope(), start: 10));
        },
      );
      try {
        final old = repository.page(scope());
        final rejected = expectLater(old, throwsStateError);
        await started.future;
        expect(
          (await repository.page(scope())).items.single['id'],
          'question-10',
        );
        oldReply.complete(response(scope()));
        await rejected;
        expect(
          (await store.read(
            MockSupabase.firstUser,
            repository.cacheKey(scope()),
          ))!['items'][0]['id'],
          'question-10',
        );
      } finally {
        await store.close();
      }
    },
  );

  test(
    'load more retains records on transport failure retries deduplicates and hides denied data',
    () async {
      var call = 0;
      final firstRead = Completer<QuestionCatalogPage>();
      final repository = ScriptedCatalog((_, cursor) async {
        call++;
        if (call == 1) return firstRead.future;
        if (call == 2) throw const SocketException('offline');
        if (call == 4) throw denied;
        expect(cursor, {'id': 'question-49'});
        return QuestionCatalogPage(
          items: [row(49), row(50)],
          syncedAt: DateTime.utc(2026),
          next: {'id': 'question-50'},
        );
      });
      final controller = QuestionCatalogController(repository, scope());
      firstRead.complete(
        QuestionCatalogPage(
          items: [for (var i = 0; i < 50; i++) row(i)],
          syncedAt: DateTime.utc(2026),
          next: {'id': 'question-49'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await controller.load(more: true);
      expect(controller.state.value!.items.length, 50);
      expect(controller.state.value!.error, isNotNull);
      await controller.load(more: true);
      expect(controller.state.value!.items.length, 51);
      expect(controller.state.value!.error, isNull);
      await controller.load(more: true);
      expect(controller.state.hasError, isTrue);
      controller.dispose();
    },
  );

  test('controller refresh and disposal fence late continuations', () async {
    final replies = <Completer<QuestionCatalogPage>>[];
    final controller = QuestionCatalogController(
      ScriptedCatalog((_, _) {
        final reply = Completer<QuestionCatalogPage>();
        replies.add(reply);
        return reply.future;
      }),
      scope(),
    );
    final refresh = controller.load();
    replies[1].complete(
      QuestionCatalogPage(items: [row(10)], syncedAt: DateTime.utc(2026)),
    );
    await refresh;
    replies[0].complete(
      QuestionCatalogPage(items: [row(0)], syncedAt: DateTime.utc(2026)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.value!.items.single['id'], 'question-10');
    final last = controller.load();
    controller.dispose();
    replies[2].complete(
      QuestionCatalogPage(items: [], syncedAt: DateTime.utc(2026)),
    );
    await last;
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'a late overview leaves the first question tappable at the same point at scale $scale',
      (tester) async {
        tester.view.physicalSize = Size(
          scale == 1 ? 400 : 320,
          scale == 1 ? 960 : 780,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final overview = Completer<Map<String, dynamic>>();
        final catalog = ScriptedCatalog(
          (scope, _) async => QuestionCatalogPage(
            items: [for (var i = 0; i < 5; i++) row(i, child: scope.child)],
            syncedAt: DateTime.utc(2026),
          ),
        );
        await mountCatalog(
          tester,
          catalog,
          scale: scale,
          authorized: false,
          overview: (_) => overview.future,
          settle: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        final first = find.widgetWithText(ListTile, '题目 0');
        if (first.hitTestable().evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            first,
            120,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(first);
          await tester.pump();
        }
        expect(first.hitTestable(), findsOneWidget);
        final before = tester.getRect(first);
        overview.complete({
          'due': 8,
          'backlog': 23,
          'task_id': 'task',
          'reminder': {'allowed': true, 'remind_local': '明天 13:00'},
        });
        await tester.pumpAndSettle();
        expect(tester.getRect(first), before);
        await tester.tapAt(before.center);
        await tester.pumpAndSettle();
        expect(find.text('错题详情'), findsOneWidget);
        expect(find.text('题目 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'today review opens and retries while the catalog is waiting; offline reminders remain disabled',
    (tester) async {
      final page = Completer<QuestionCatalogPage>();
      final children = <String>[];
      await mountCatalog(
        tester,
        ScriptedCatalog((_, _) => page.future),
        authorized: false,
        settle: false,
        overview: (child) async {
          children.add(child);
          if (children.length == 1) throw StateError('概览暂不可用');
          return {
            'due': 4,
            'backlog': 9,
            'task_id': 'saved-task',
            'offline_cache': true,
            'reminder': {'allowed': true},
          };
        },
      );
      await tester.pump();
      expect(children, isEmpty);
      await tester.tap(find.text('今日复习'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(children, ['child']);
      expect(find.textContaining('概览暂不可用'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump();
      expect(children, ['child', 'child']);
      expect(find.text('今日待复习 4 题 · 积压 9 题'), findsOneWidget);
      expect(find.text('离线缓存；已缓存题目可作答，判定与奖励联网确认'), findsOneWidget);
      expect(find.text('去复习'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '联网后可设置稍后提醒'))
            .onPressed,
        isNull,
      );
      page.complete(
        QuestionCatalogPage(items: [row(0)], syncedAt: DateTime.utc(2026)),
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('离线 · 待复习 4 题 · 积压 9 题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'switching child before the sheet first paints never subscribes to the old overview',
    (tester) async {
      final child = ValueNotifier('first'),
          firstPage = Completer<QuestionCatalogPage>();
      addTearDown(child.dispose);
      final requested = <String>[];
      await mountCatalog(
        tester,
        ScriptedCatalog(
          (s, _) async => s.child == 'first'
              ? firstPage.future
              : QuestionCatalogPage(
                  items: [row(0, child: s.child)],
                  syncedAt: DateTime.utc(2026),
                ),
        ),
        currentChild: child,
        settle: false,
        authorized: false,
        overview: (id) async {
          requested.add(id);
          return {'due': 2, 'backlog': 0};
        },
      );
      await tester.pump();
      expect(requested, isEmpty);
      await tester.tap(find.text('今日复习'));
      child.value = 'second';
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(requested, ['second']);
      firstPage.complete(
        QuestionCatalogPage(items: [], syncedAt: DateTime.utc(2026)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a child change resets visible filters and cancels the old pending search',
    (tester) async {
      final child = ValueNotifier('first'), calls = <QuestionCatalogScope>[];
      addTearDown(child.dispose);
      await mountCatalog(
        tester,
        ScriptedCatalog((scope, _) async {
          calls.add(scope);
          return QuestionCatalogPage(
            items: [row(0, child: scope.child)],
            syncedAt: DateTime.utc(2026),
          );
        }),
        currentChild: child,
        authorized: false,
      );
      await tester.enterText(find.byType(TextField), '已提交的关键词');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      final subjects = find.byType(DropdownButton<String>).first;
      await tester.ensureVisible(subjects);
      await tester.tap(subjects);
      await tester.pumpAndSettle();
      await tester.tap(find.text('数学').last);
      await tester.pumpAndSettle();
      expect(calls.last.subject, 'math');
      expect(calls.last.keyword, '已提交的关键词');
      await tester.enterText(find.byType(TextField), '尚在等待的关键词');
      child.value = 'second';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final second = calls.where((s) => s.child == 'second').toList();
      expect(second, isNotEmpty);
      expect(
        second.every(
          (s) =>
              s.keyword.isEmpty &&
              s.subject == 'all' &&
              s.mastery == 'all' &&
              s.archive == 'all',
        ),
        isTrue,
      );
      expect(calls.where((s) => s.keyword == '尚在等待的关键词'), isEmpty);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(tester.widget<DropdownButton<String>>(subjects).value, 'all');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'changing children dismisses the old overview and goes to the new child review',
    (tester) async {
      final currentChild = ValueNotifier('first');
      addTearDown(currentChild.dispose);
      await mountCatalog(
        tester,
        ScriptedCatalog(
          (scope, _) async => QuestionCatalogPage(
            items: [row(0, child: scope.child)],
            syncedAt: DateTime.utc(2026),
          ),
        ),
        currentChild: currentChild,
        authorized: false,
        overview: (child) async => {
          'due': child == 'first' ? 3 : 7,
          'backlog': 0,
          'task_id': 'task-$child',
        },
      );
      await tester.tap(find.text('今日复习'));
      await tester.pumpAndSettle();
      expect(find.text('今日待复习 3 题 · 积压 0 题'), findsOneWidget);
      currentChild.value = 'second';
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('今日复习'));
      await tester.pumpAndSettle();
      expect(find.text('今日待复习 7 题 · 积压 0 题'), findsOneWidget);
      await tester.tap(find.text('去复习'));
      await tester.pumpAndSettle();
      final session = tester.widget<ReviewSessionScreen>(
        find.byType(ReviewSessionScreen),
      );
      expect(
        (session.childId, session.familyId, session.taskId),
        ('second', 'family', 'task-second'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'thousand-record hub builds visible cards only and remains scrollable at double text size',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = ScriptedCatalog(
        (s, _) async => QuestionCatalogPage(
          items: s.kind == 'pinyin'
              ? []
              : [for (var i = 0; i < 1000; i++) row(i)],
          syncedAt: DateTime.utc(2026),
          offline: true,
        ),
      );
      await mountCatalog(tester, repository, scale: 2);
      expect(find.text('题目 999'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('题目 0'),
        220,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 25,
      );
      expect(find.byType(Card).evaluate().length, lessThan(12));
      expect(find.textContaining('仅包含该筛选最近同步'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'search debounces and the unopened tab reads the current filters on entry',
    (tester) async {
      final calls = <QuestionCatalogScope>[];
      final repository = ScriptedCatalog((s, _) async {
        calls.add(s);
        return QuestionCatalogPage(items: [], syncedAt: DateTime.utc(2026));
      });
      await mountCatalog(tester, repository);
      expect(calls.map((s) => s.kind), ['question']);
      await tester.enterText(find.byType(TextField), '银行');
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls.where((s) => s.keyword == '银行'), isEmpty);
      await tester.pump(const Duration(milliseconds: 110));
      await tester.pumpAndSettle();
      expect(calls.where((s) => s.keyword == '银行').map((s) => s.kind), [
        'question',
      ]);
      await tester.tap(find.text('拼音词库'));
      await tester.pumpAndSettle();
      expect(calls.where((s) => s.keyword == '银行').map((s) => s.kind), [
        'question',
        'pinyin',
      ]);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'pending');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(calls.where((s) => s.keyword == 'pending'), isEmpty);
    },
  );

  testWidgets(
    'list footer loads next page without replacing first page records',
    (tester) async {
      var continued = false;
      final repository = ScriptedCatalog((s, cursor) async {
        if (s.kind == 'pinyin') {
          return QuestionCatalogPage(items: [], syncedAt: DateTime.utc(2026));
        }
        continued |= cursor != null;
        return QuestionCatalogPage(
          items: cursor == null ? [row(0)] : [row(1)],
          syncedAt: DateTime.utc(2026),
          next: cursor == null ? {'id': 'question-0'} : null,
        );
      });
      await mountCatalog(tester, repository);
      await tester.scrollUntilVisible(
        find.text('继续查看（已加载1条）'),
        200,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      await tester.tap(find.text('继续查看（已加载1条）'));
      await tester.pumpAndSettle();
      expect(continued, isTrue);
      expect(find.text('题目 0'), findsOneWidget);
      expect(find.text('题目 1'), findsOneWidget);
      expect(find.text('继续查看（已加载1条）'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> mountCatalog(
  WidgetTester tester,
  QuestionCatalogRepository repository, {
  double scale = 1,
  bool authorized = true,
  Future<Map<String, dynamic>> Function(String)? overview,
  bool settle = true,
  ValueNotifier<String>? currentChild,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        questionCatalogRepositoryProvider.overrideWithValue(repository),
        reviewRepositoryProvider.overrideWithValue(FakeReviewRepository()),
        taskRepositoryProvider.overrideWithValue(
          const UnconfiguredTaskRepository(),
        ),
        activeParentFamilyProvider.overrideWithValue(
          authorized ? 'family' : null,
        ),
        if (overview != null)
          reviewOverviewProvider.overrideWith((_, child) => overview(child)),
      ],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: currentChild == null
            ? const ReviewHubScreen(childId: 'child', familyId: 'family')
            : ValueListenableBuilder<String>(
                valueListenable: currentChild,
                builder: (_, child, _) =>
                    ReviewHubScreen(childId: child, familyId: 'family'),
              ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/domain/economy_page.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'economy_test.dart' show FakeEconomy;
import 'support/mock_supabase.dart';

Map<String, dynamic> entry(int n) => {
  'id': n.toString().padLeft(4, '0'),
  'created_at': '2026-11-05T00:00:00Z',
  'child_id': 'child',
  'family_id': 'family',
};
Map<String, dynamic> receipt({
  String section = 'ledger',
  bool inactive = false,
  List<Map<String, dynamic>>? items,
  bool more = false,
}) {
  final rows = items ?? [entry(3), entry(2)];
  return {
    'owner_id': MockSupabase.firstUser,
    'child_id': 'child',
    'family_id': 'family',
    'section': section,
    'include_inactive': inactive,
    'family_today': '2026-11-05',
    'items': rows,
    'next_cursor': more
        ? {'id': rows.last['id'], 'created_at': rows.last['created_at']}
        : null,
  };
}

EconomyPage parse(Map<String, dynamic> value, {Map<String, dynamic>? after}) =>
    EconomyPage.fromJson(
      value,
      owner: MockSupabase.firstUser,
      child: 'child',
      family: 'family',
      section: 'ledger',
      includeInactive: false,
      after: after,
    );

class PagedFake extends FakeEconomy implements PagedEconomyRepository {
  final pageCalls = <String>[];
  Future<EconomyPage> Function(String)? next;
  int initialCount = 1;
  @override
  Future<Map<String, dynamic>> load(String childId, String familyId) async {
    final data = await super.load(childId, familyId),
        reward =
            (await super.load(childId, familyId))['rewards'][0]
                as Map<String, dynamic>;
    return {
      ...data,
      'rewards': [
        for (var i = 0; i < initialCount; i++)
          {...reward, 'id': 'reward-$i', 'title': '奖励 $i'},
      ],
      'cursors': {
        for (final s in ['rewards', 'redemptions', 'pending', 'ledger'])
          s: entry(2),
      },
      'page_days': {
        for (final s in ['rewards', 'redemptions', 'pending', 'ledger'])
          s: '2026-11-05',
      },
    };
  }

  @override
  Future<EconomyPage> page(
    String childId,
    String familyId,
    String section, {
    Map<String, dynamic>? after,
  }) async {
    pageCalls.add(section);
    expect(after?['id'], '0002');
    return next?.call(section) ??
        EconomyPage(items: [], nextCursor: null, familyToday: '2026-11-05');
  }
}

void main() {
  test(
    'economy receipts reject foreign ownership, mixed rows, invalid dates and oversized pages',
    () {
      expect(parse(receipt()).items.length, 2);
      for (final patch in [
        {'owner_id': 'other'},
        {'child_id': 'other'},
        {'family_id': 'other'},
        {'section': 'rewards'},
        {'include_inactive': true},
        {'family_today': '2026-02-30'},
        {
          'items': [
            entry(3),
            {...entry(2), 'child_id': 'other'},
          ],
        },
        {
          'items': [for (var n = 51; n > 0; n--) entry(n)],
        },
      ]) {
        expect(() => parse({...receipt(), ...patch}), throwsFormatException);
      }
    },
  );
  test(
    'economy receipts enforce descending tie-breaks, forward progress and exact final-row cursors',
    () {
      for (final rows in [
        [entry(2), entry(3)],
        [entry(3), entry(3)],
        [
          {...entry(3), 'created_at': 'broken'},
        ],
      ]) {
        expect(() => parse(receipt(items: rows)), throwsFormatException);
      }
      expect(() => parse(receipt(), after: entry(3)), throwsFormatException);
      expect(parse(receipt(), after: entry(4)).items.length, 2);
      expect(
        () => parse({...receipt(more: true), 'next_cursor': entry(1)}),
        throwsFormatException,
      );
      expect(parse(receipt(more: true)).nextCursor?['id'], '0002');
      expect(parse(receipt(items: [])).nextCursor, isNull);
    },
  );
  test(
    'explicit next page sends the cursor and parent filter without reading other lists',
    () async {
      final api = MockSupabase();
      addTearDown(api.close);
      await api.signIn();
      api.handle = (r) => MockSupabase.json(
        r,
        receipt(section: 'rewards', inactive: true, items: [entry(1)]),
      );
      final repository = SupabaseEconomyRepository(
        api.client,
        includeInactive: (_) => true,
      );
      final page = await repository.page(
        'child',
        'family',
        'rewards',
        after: entry(2),
      );
      expect(page.items.single['id'], '0001');
      expect(api.calls.length, 1);
      expect(MockSupabase.body(api.calls.single), {
        'target_child_id': 'child',
        'target_family_id': 'family',
        'section': 'rewards',
        'page_size': 50,
        'after_created_at': entry(2)['created_at'],
        'after_id': '0002',
        'include_inactive': true,
      });
    },
  );
  for (final change in [
    'owner',
    'child',
    'account',
    'membership',
    'dispose',
    'parent',
  ]) {
    test('economy late reads cannot reappear after $change changes', () async {
      final api = MockSupabase(), store = OfflineStore(NativeDatabase.memory());
      addTearDown(api.close);
      addTearDown(store.close);
      await api.signIn();
      var parent = false;
      final repository = SupabaseEconomyRepository(
        api.client,
        store: store,
        includeInactive: (_) => parent,
      );
      final entered = Completer<void>(), delayed = Completer<http.Response>();
      late http.Request request;
      api.handle = (r) {
        request = r;
        entered.complete();
        return delayed.future;
      };
      final rejected = expectLater(
        repository.page('child', 'family', 'ledger'),
        throwsStateError,
      );
      await entered.future;
      switch (change) {
        case 'owner':
          await api.signIn(MockSupabase.secondUser);
        case 'child':
          await store.removeChildData('child');
        case 'account':
          await store.removeAccountData(MockSupabase.firstUser, 'job');
        case 'membership':
          await store.applyFamilyAccess(MockSupabase.firstUser, [
            FamilyAccessState(
              familyId: 'family',
              version: 2,
              active: false,
              lastRevokedVersion: 2,
              childIds: {'child'},
            ),
          ]);
        case 'dispose':
          repository.dispose();
        case 'parent':
          parent = true;
      }
      delayed.complete(MockSupabase.json(request, receipt()));
      await rejected;
    });
  }
  test(
    'unauthenticated and locally deleted scopes never send a page request; wallet owner is checked',
    () async {
      final api = MockSupabase(), store = OfflineStore(NativeDatabase.memory());
      addTearDown(api.close);
      addTearDown(store.close);
      final repository = SupabaseEconomyRepository(api.client, store: store);
      await expectLater(repository.load('child', 'family'), throwsStateError);
      expect(api.calls, isEmpty);
      await api.signIn();
      api.handle = (r) => MockSupabase.json(r, {'child_id': 'foreign'});
      await expectLater(
        repository.load('child', 'family'),
        throwsFormatException,
      );
      expect(api.calls.length, 1);
      await store.removeChildData('child');
      await expectLater(
        repository.page('child', 'family', 'ledger'),
        throwsStateError,
      );
      expect(api.calls.length, 1);
    },
  );

  Future<void> mount(
    WidgetTester tester,
    PagedFake live, {
    int tab = 0,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          economyRepositoryProvider.overrideWithValue(live),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          activeParentFamilyProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: EconomyScreen(
            childId: 'child',
            familyId: 'family',
            initialTab: tab,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> showMore(WidgetTester tester, String section) async {
    final list = find.byKey(
      PageStorageKey(
        'economy:child:${section == 'pending' ? 'ledger' : section}',
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('more:$section')),
      200,
      scrollable: find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first,
      maxScrolls: 100,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'next-page failure preserves rows and retry stops when history ends',
    (tester) async {
      final live = PagedFake();
      live.next = (_) => throw const SocketException('offline');
      await mount(tester, live);
      await showMore(tester, 'rewards');
      await tester.tap(find.byKey(const ValueKey('more:rewards')));
      await tester.pumpAndSettle();
      expect(find.text('重试加载奖励'), findsOneWidget);
      expect(live.pageCalls, ['rewards']);
      live.next = (_) async =>
          EconomyPage(items: [], nextCursor: null, familyToday: '2026-11-05');
      await tester.tap(find.byKey(const ValueKey('more:rewards')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('more:rewards')), findsNothing);
      expect(find.text('奖励 0 · 120金币'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('refresh discards a delayed next page and resets its cursor', (
    tester,
  ) async {
    final live = PagedFake(), delayed = Completer<EconomyPage>();
    live.next = (_) => delayed.future;
    await mount(tester, live);
    await showMore(tester, 'rewards');
    await tester.tap(find.byKey(const ValueKey('more:rewards')));
    await tester.pump();
    await tester.tap(find.byTooltip('刷新钱包与申请'));
    await tester.pumpAndSettle();
    delayed.complete(
      EconomyPage(
        items: [
          {'id': 'stale', 'title': '迟到奖励'},
        ],
        nextCursor: null,
        familyToday: '2026-11-05',
      ),
    );
    await tester.pumpAndSettle();
    await showMore(tester, 'rewards');
    expect(find.textContaining('迟到奖励'), findsNothing);
    expect(find.byKey(const ValueKey('more:rewards')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'catalog rollover requires refresh instead of mixing quota dates',
    (tester) async {
      final live = PagedFake();
      live.next = (_) async =>
          EconomyPage(items: [], nextCursor: null, familyToday: '2026-11-06');
      await mount(tester, live);
      await showMore(tester, 'rewards');
      await tester.tap(find.byKey(const ValueKey('more:rewards')));
      await tester.pumpAndSettle();
      expect(find.text('重试加载奖励'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('permission denial hides previously loaded financial records', (
    tester,
  ) async {
    final live = PagedFake();
    live.next = (_) async =>
        throw const PostgrestException(message: 'revoked', code: '42501');
    await mount(tester, live);
    await showMore(tester, 'rewards');
    await tester.tap(find.byKey(const ValueKey('more:rewards')));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂不可访问'), findsOneWidget);
    expect(find.text('奖励 0 · 120金币'), findsNothing);
    expect(find.textContaining('可用 300'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'redemption confirmation fences a page read started before the balance changed',
    (tester) async {
      final live = PagedFake(), delayed = Completer<EconomyPage>();
      live.next = (_) => delayed.future;
      await mount(tester, live);
      await showMore(tester, 'rewards');
      await tester.tap(find.byKey(const ValueKey('more:rewards')));
      await tester.pump();
      await tester.ensureVisible(find.text('申请'));
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认申请'));
      await tester.pumpAndSettle();
      expect(live.requests, 1);
      delayed.complete(
        EconomyPage(
          items: [
            {'id': 'stale', 'title': '旧余额奖励'},
          ],
          nextCursor: null,
          familyToday: '2026-11-05',
        ),
      );
      await tester.pumpAndSettle();
      await showMore(tester, 'rewards');
      expect(find.textContaining('旧余额奖励'), findsNothing);
      expect(find.byKey(const ValueKey('more:rewards')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'redemption pages append history and reject duplicates without losing the prior rows',
    (tester) async {
      final live = PagedFake();
      final original =
          (await live.load('child', 'family'))['redemptions'][0]
              as Map<String, dynamic>;
      live.next = (_) async => EconomyPage(
        items: [original],
        nextCursor: null,
        familyToday: '2026-11-05',
      );
      await mount(tester, live, tab: 1);
      await showMore(tester, 'redemptions');
      await tester.tap(find.byKey(const ValueKey('more:redemptions')));
      await tester.pumpAndSettle();
      expect(find.text('重试加载兑换记录'), findsOneWidget);
      live.next = (_) async => EconomyPage(
        items: [
          {...original, 'id': 'older', 'reward_title': '更早的兑换'},
        ],
        nextCursor: null,
        familyToday: '2026-11-05',
      );
      await tester.tap(find.byKey(const ValueKey('more:redemptions')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('更早的兑换'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('economy:child:redemptions')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('更早的兑换'), findsOneWidget);
      expect(live.pageCalls, ['redemptions', 'redemptions']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('long reward history builds visible cards only', (tester) async {
    final live = PagedFake()..initialCount = 1000;
    await mount(tester, live);
    expect(find.byType(Card).evaluate().length, lessThan(12));
    expect(find.text('奖励 999 · 120金币'), findsNothing);
    expect(live.pageCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'ledger and pending have independent controls at double text size',
    (tester) async {
      final live = PagedFake();
      await mount(tester, live, tab: 2, scale: 2);
      await showMore(tester, 'pending');
      await tester.tap(find.byKey(const ValueKey('more:pending')));
      await tester.pumpAndSettle();
      await showMore(tester, 'ledger');
      await tester.tap(find.byKey(const ValueKey('more:ledger')));
      await tester.pumpAndSettle();
      expect(live.pageCalls, ['pending', 'ledger']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

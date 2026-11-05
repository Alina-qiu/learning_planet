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
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/economy/data/economy_commands.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/domain/economy_page.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/domain/task_sync_state.dart';
import 'economy_test.dart' show FakeEconomy;
import 'widget_test.dart' show FakeTaskRepository;
import 'support/mock_supabase.dart';

const owner = MockSupabase.firstUser;
const cachedKey = 'economy-view:child:family:child';

class EconomyHarness {
  EconomyHarness([OfflineStore? database])
    : store = database ?? OfflineStore(NativeDatabase.memory()) {
    repository = SupabaseEconomyRepository(
      api.client,
      store: store,
      includeInactive: (_) => parent,
    );
    api.handle = respond;
  }
  final api = MockSupabase();
  final OfflineStore store;
  late final SupabaseEconomyRepository repository;
  bool parent = false;
  int balance = 300;
  Future<http.Response> respond(http.Request r) async {
    final args = MockSupabase.body(r);
    final child = args['target_child_id'] ?? 'child';
    final family = args['target_family_id'] ?? 'family';
    final base = await FakeEconomy().load(child as String, family as String);
    if (r.url.path.endsWith('wallet_overview')) {
      return MockSupabase.json(r, {
        ...base['overview'] as Map,
        'child_id': child,
        'coin_balance': balance,
      });
    }
    if (!r.url.path.endsWith('economy_page')) return MockSupabase.json(r, null);
    final section = args['section'] as String;
    final rows = [
      for (final row in base[section] as List)
        {
          ...row as Map<String, dynamic>,
          'child_id': child,
          'family_id': family,
          'created_at': '2026-11-06T00:00:00Z',
        },
    ];
    return MockSupabase.json(r, {
      'owner_id': api.client.auth.currentUser!.id,
      'child_id': child,
      'family_id': family,
      'section': section,
      'include_inactive': args['include_inactive'],
      'family_today': '2026-11-06',
      'fetched_at': '2026-11-06T00:00:00Z',
      'items': rows,
      'next_cursor': null,
    });
  }

  Future<Map<String, dynamic>> load() => repository.load('child', 'family');
  void disconnect() {
    api.handle = (_) => throw const SocketException('offline');
  }

  Future<void> close() async {
    repository.dispose();
    await api.close();
    await store.close();
  }
}

class SnapshotEconomy extends FakeEconomy implements PagedEconomyRepository {
  bool offline = true;
  int reads = 0, pageReads = 0;
  @override
  Future<Map<String, dynamic>> load(String childId, String familyId) async {
    reads++;
    final base = await super.load(childId, familyId);
    return {
      ...base,
      'offline': offline,
      'fetched_at': '2026-11-06T00:00:00Z',
      'cursors': {
        for (final section in ['rewards', 'redemptions', 'pending', 'ledger'])
          section: {'id': 'older', 'created_at': '2026-11-05T00:00:00Z'},
      },
      'redemptions': [
        ...base['redemptions'] as List,
        {
          'id': 'approved',
          'reward_title': '待履约奖励',
          'status': 'approved',
          'frozen_amount': 60,
          'expires_at': '2026-11-07',
        },
      ],
      'pending': [
        {
          'id': 'pending',
          'status': 'pending',
          'amount': 10,
          'source_type': 'task',
          'created_at': '2026-11-05',
        },
      ],
      'ledger': [
        {
          'id': 'ledger',
          'amount': 120,
          'asset_type': 'coin',
          'source_type': 'task',
          'created_at': '2026-11-05',
        },
      ],
    };
  }

  @override
  Future<EconomyPage> page(
    String childId,
    String familyId,
    String section, {
    Map<String, dynamic>? after,
  }) async {
    pageReads++;
    throw StateError('Offline page request must not be sent');
  }
}

class LostCommandReply implements EconomyCommandRemote {
  @override
  Future<Map<String, dynamic>> resolve(
    EconomyCommand request,
    String operation,
  ) => Future.error(const SocketException('reply lost'));
}

class HoldingEconomyStore extends OfflineStore {
  HoldingEconomyStore() : super(NativeDatabase.memory());
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> write(
    String owner,
    String key,
    Map<String, dynamic> data,
  ) async {
    await super.write(owner, key, data);
    if (key.startsWith('economy-view:')) {
      entered.complete();
      await release.future;
    }
  }
}

Future<void> pumpEconomy(
  WidgetTester tester,
  SnapshotEconomy live, {
  int tab = 0,
  bool parent = true,
  StreamController<TaskSyncState>? sync,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        economyRepositoryProvider.overrideWithValue(live),
        taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
        activeParentFamilyProvider.overrideWithValue(parent ? 'family' : null),
        if (sync != null)
          taskSyncStateProvider.overrideWith((ref) => sync.stream),
      ],
      child: MaterialApp(
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

void main() {
  test(
    'permission failure wins over a concurrent page network failure',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      h.api.handle = (r) {
        final section = MockSupabase.body(r)['section'];
        if (section == 'rewards') throw const SocketException('offline page');
        if (section == 'ledger') return MockSupabase.denied(r);
        return h.respond(r);
      };
      await expectLater(h.load(), throwsA(isA<PostgrestException>()));
      expect(await h.store.read(owner, cachedKey), isNull);
    },
  );

  test(
    'disposing during SQLite snapshot write rolls back the pending cache',
    () async {
      final store = HoldingEconomyStore();
      final current = EconomyHarness(store);
      addTearDown(current.close);
      await current.api.signIn();
      final rejected = expectLater(current.load(), throwsStateError);
      await store.entered.future;
      current.repository.dispose();
      store.release.complete();
      await rejected;
      expect(await store.read(owner, cachedKey), isNull);
    },
  );

  test(
    'complete economy snapshot survives file reopen with original server time and balances',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lp-economy-cache-',
      );
      final file = File('${directory.path}/cache.sqlite');
      final first = EconomyHarness(OfflineStore(NativeDatabase(file)));
      await first.api.signIn();
      final online = await first.load();
      expect(online['offline'], false);
      await first.store.write(owner, 'wallet:child', {'coin_balance': 999999});
      await first.close();
      final second = EconomyHarness(OfflineStore(NativeDatabase(file)));
      try {
        await second.api.signIn();
        second.disconnect();
        final restored = await second.load();
        expect(restored['offline'], true);
        expect(restored['overview']['coin_balance'], 300);
        expect(restored['overview']['frozen_balance'], 120);
        expect(restored['fetched_at'], '2026-11-06T00:00:00Z');
        expect(restored['rewards'], online['rewards']);
        expect(restored['redemptions'], online['redemptions']);
      } finally {
        await second.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'partial network failure preserves the prior complete snapshot without mixing new wallet data',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      h.balance = 700;
      h.api.handle = (r) => MockSupabase.body(r)['section'] == 'ledger'
          ? throw const SocketException('partial')
          : h.respond(r);
      final fallback = await h.load();
      expect(fallback['overview']['coin_balance'], 300);
      expect(fallback['offline'], true);
      expect(
        (await h.store.read(owner, cachedKey))!['overview']['coin_balance'],
        300,
      );
    },
  );

  test(
    'cache is separate for account child family and parent visibility',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      h.disconnect();
      await expectLater(
        h.repository.load('other', 'family'),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        h.repository.load('child', 'other'),
        throwsA(isA<SocketException>()),
      );
      h.parent = true;
      await expectLater(h.load(), throwsA(isA<SocketException>()));
      h.parent = false;
      await h.api.signIn(MockSupabase.secondUser);
      await expectLater(h.load(), throwsA(isA<SocketException>()));
    },
  );

  test(
    'permission denial purges both role views and cannot become offline success',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      h.parent = true;
      await h.load();
      h.api.handle = MockSupabase.denied;
      await expectLater(h.load(), throwsA(isA<PostgrestException>()));
      expect(await h.store.read(owner, cachedKey), isNull);
      expect(
        await h.store.read(owner, 'economy-view:child:family:parent'),
        isNull,
      );
      h.disconnect();
      await expectLater(h.load(), throwsA(isA<SocketException>()));
    },
  );

  test(
    'malformed online data is not hidden by cache and corrupt cache is rejected',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      h.api.handle = (r) => MockSupabase.json(r, {'child_id': 'foreign'});
      await expectLater(h.load(), throwsFormatException);
      final old = (await h.store.read(owner, cachedKey))!;
      for (final patch in [
        {'schema': 2},
        {'family_id': 'other'},
        {'fetched_at': 'broken'},
        {'family_timezone': 123},
        {
          'overview': {...old['overview'] as Map, 'coin_balance': -1},
        },
        {
          'rewards': [
            {...((old['rewards'] as List).first as Map), 'family_id': 'other'},
          ],
        },
      ]) {
        await h.store.write(owner, cachedKey, {...old, ...patch});
        h.disconnect();
        await expectLater(h.load(), throwsFormatException);
      }
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
    test(
      'late economy snapshot cannot return or persist after $change changes',
      () async {
        final h = EconomyHarness();
        addTearDown(h.close);
        await h.api.signIn();
        final entered = Completer<void>(), reply = Completer<http.Response>();
        late http.Request request;
        h.api.handle = (r) {
          request = r;
          entered.complete();
          return reply.future;
        };
        final rejected = expectLater(h.load(), throwsStateError);
        await entered.future;
        switch (change) {
          case 'owner':
            await h.api.signIn(MockSupabase.secondUser);
          case 'child':
            await h.store.removeChildData('child');
          case 'account':
            await h.store.removeAccountData(owner, 'job');
          case 'membership':
            await h.store.applyFamilyAccess(owner, [
              FamilyAccessState(
                familyId: 'family',
                version: 2,
                active: false,
                lastRevokedVersion: 2,
                childIds: {'child'},
              ),
            ]);
          case 'dispose':
            h.repository.dispose();
          case 'parent':
            h.parent = true;
        }
        h.api.handle = h.respond;
        reply.complete(await h.respond(request));
        await rejected;
        expect(await h.store.read(owner, cachedKey), isNull);
      },
    );
  }

  test(
    'newer loads and mutations through another repository fence delayed old reads',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      for (final mutate in [false, true]) {
        final entered = Completer<void>(), reply = Completer<http.Response>();
        late http.Request request;
        h.api.handle = (r) {
          request = r;
          entered.complete();
          return reply.future;
        };
        final rejected = expectLater(h.load(), throwsStateError);
        await entered.future;
        h.api.handle = h.respond;
        h.balance = 700;
        if (mutate) {
          await SupabaseEconomyRepository(
            h.api.client,
            store: h.store,
          ).limit('child', 200);
        } else {
          await h.load();
        }
        reply.complete(await h.respond(request));
        await rejected;
        final saved = await h.store.read(owner, cachedKey);
        expect(
          saved == null ? null : saved['overview']['coin_balance'],
          mutate ? null : 700,
        );
      }
    },
  );

  test(
    'all economy writes retire snapshots even when the server reply is lost',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      final mutations = <Future<void> Function()>[
        () => h.repository.saveReward('family', {}),
        () => h.repository.request('child', 'reward', 'key', 1),
        () => h.repository.transition('redemption', 'approve', 'reason'),
        () => h.repository.adjust('child', {}),
        () => h.repository.limit('child', 200),
        () => h.repository.decide('pending', true, 'reason'),
        () => h.repository.reconcile('child'),
      ];
      for (final mutate in mutations) {
        h.api.handle = h.respond;
        await h.load();
        h.disconnect();
        await expectLater(mutate(), throwsA(isA<SocketException>()));
        expect(await h.store.read(owner, cachedKey), isNull);
        await expectLater(h.load(), throwsA(isA<SocketException>()));
      }
    },
  );

  test(
    'durable command retires cached balances but preserves the original pending request on lost reply',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      final commands = EconomyCommands(
        store: h.store,
        remote: LostCommandReply(),
        owner: () => owner,
        authorized: (_) => true,
        authorizationRevision: () => 1,
      );
      final request = await commands.prepare(
        'child',
        'family',
        {'kind': 'redeem', 'reward_id': 'reward', 'expected_version': 1},
        {'title': '家庭电影', 'cost': 120},
      );
      await expectLater(
        commands.resolve('child', 'family', request.requestId, 'submit'),
        throwsA(isA<SocketException>()),
      );
      expect(await h.store.read(owner, cachedKey), isNull);
      expect(
        (await commands.pending('child', 'family'))!.requestId,
        request.requestId,
      );
    },
  );

  test(
    'child deletion erases its economy views while preserving sibling and command isolation',
    () async {
      final h = EconomyHarness();
      addTearDown(h.close);
      await h.api.signIn();
      await h.load();
      await h.repository.load('sibling', 'family');
      await h.store.removeChildData('child');
      expect(await h.store.read(owner, cachedKey), isNull);
      expect(
        await h.store.read(owner, 'economy-view:sibling:family:child'),
        isNotNull,
      );
    },
  );

  for (var tab = 0; tab < 3; tab++) {
    testWidgets(
      'offline economy tab $tab stays readable and disables mutations at double phone text',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final live = SnapshotEconomy();
        await pumpEconomy(tester, live, tab: tab);
        expect(find.textContaining('离线上次记录'), findsOneWidget);
        final section = ['rewards', 'redemptions', 'ledger'][tab];
        final scroll = find
            .descendant(
              of: find.byKey(PageStorageKey('economy:child:$section')),
              matching: find.byType(Scrollable),
            )
            .first;
        final actions = [
          ['新增奖励', '申请'],
          ['取消申请', '批准', '拒绝并退款', '确认已履约'],
          ['家长调账', '配置软上限', '按账本重算钱包'],
        ][tab];
        for (final label in actions) {
          await tester.scrollUntilVisible(
            find.text(label),
            200,
            scrollable: scroll,
          );
          await tester.pumpAndSettle();
          final button = find
              .ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              )
              .first;
          expect(
            tester.widget<ButtonStyleButton>(button).onPressed,
            isNull,
            reason: label,
          );
        }
        expect(live.pageReads, 0);
        expect(live.requests, 0);
        expect(live.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a successful task sync refreshes an open offline economy view', (
    tester,
  ) async {
    final live = SnapshotEconomy(),
        sync = StreamController<TaskSyncState>.broadcast();
    addTearDown(sync.close);
    await pumpEconomy(tester, live, sync: sync, parent: false);
    sync.add(const TaskSyncState(phase: TaskSyncPhase.offline));
    await tester.pumpAndSettle();
    live.offline = false;
    sync.add(const TaskSyncState(phase: TaskSyncPhase.synced));
    await tester.pumpAndSettle();
    expect(live.reads, 2);
    expect(find.textContaining('离线上次记录'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('申请'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('economy:child:rewards')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '申请'))
          .onPressed,
      isNotNull,
    );
  });
}

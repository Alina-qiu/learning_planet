import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/domain/wallet_adjustment_details.dart';
import 'package:learning_planet/features/economy/presentation/economy_text.dart';
import 'package:learning_planet/features/economy/presentation/wallet_adjustment_screen.dart';
import 'economy_test.dart' show FakeEconomy;
import 'support/mock_supabase.dart';

const owner = MockSupabase.firstUser;
const scope = (child: 'child', family: 'family', entryId: 'entry');
Map<String, dynamic> record({bool audit = true}) => {
  'owner_id': owner,
  'child_id': 'child',
  'family_id': 'family',
  'family_timezone': 'Asia/Shanghai',
  'entry': {
    'id': 'entry',
    'child_id': 'child',
    'asset_type': 'coin',
    'amount': 300,
    'frozen_delta': 0,
    'source_type': 'parent_adjustment',
    'created_at': '2026-11-05T17:00:00Z',
  },
  'audit': audit
      ? {
          'coins': 300,
          'xp': 20,
          'reason': '完成家务，补记奖励',
          'created_at': '2026-11-05T17:00:00Z',
          'actor': {
            'is_self': true,
            'status': 'member',
            'email': 'parent@example.test',
          },
        }
      : null,
};
WalletAdjustmentDetails parsed([bool audit = true]) =>
    WalletAdjustmentDetails.fromJson(
      record(audit: audit),
      owner: owner,
      child: 'child',
      family: 'family',
      entryId: 'entry',
    );

class AuditHarness {
  final api = MockSupabase(), store = OfflineStore(NativeDatabase.memory());
  bool parent = true;
  int revision = 0;
  late final repository = SupabaseEconomyRepository(
    api.client,
    store: store,
    includeInactive: (_) => parent,
    authorizationRevision: () => revision,
  );
  Future<WalletAdjustmentDetails> load() =>
      repository.adjustmentDetails('child', 'family', 'entry');
  Future<void> close() async {
    repository.dispose();
    await api.close();
    await store.close();
  }
}

class FakeAudit extends FakeEconomy implements AuditedEconomyRepository {
  Future<WalletAdjustmentDetails> Function()? response;
  int reads = 0;
  @override
  Future<WalletAdjustmentDetails> adjustmentDetails(
    String child,
    String family,
    String entryId,
  ) {
    expect((child: child, family: family, entryId: entryId), scope);
    reads++;
    return response?.call() ?? Future.value(parsed());
  }
}

void main() {
  test(
    'SDK audit read carries only the target child and entry and does not persist explanations',
    () async {
      final h = AuditHarness();
      addTearDown(h.close);
      await h.api.signIn();
      h.api.handle = (r) {
        expect(r.url.path.endsWith('/wallet_adjustment_details'), true);
        expect(MockSupabase.body(r), {
          'target_child_id': 'child',
          'target_ledger_id': 'entry',
        });
        return MockSupabase.json(r, record());
      };
      final value = await h.load();
      expect(value.audit!['reason'], '完成家务，补记奖励');
      expect(
        (await h.store.customSelect('select * from offline_cache').get()),
        isEmpty,
      );
      h.parent = false;
      await expectLater(h.load(), throwsStateError);
      expect(h.api.calls, hasLength(1));
    },
  );
  for (final change in [
    'owner',
    'child',
    'account',
    'membership',
    'dispose',
    'parent',
    'revision',
  ]) {
    test('late audit is discarded after $change changes', () async {
      final h = AuditHarness();
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
          h.parent = false;
        case 'revision':
          h.revision++;
      }
      reply.complete(MockSupabase.json(request, record()));
      await rejected;
    });
  }
  test(
    'wrong entry, child, actor shape and mismatched audit amounts cannot appear as valid details',
    () {
      final base = record();
      for (final patch in [
        {'owner_id': 'other'},
        {'child_id': 'other'},
        {
          'entry': {...base['entry'] as Map, 'id': 'other'},
        },
        {
          'audit': {...base['audit'] as Map, 'coins': 301},
        },
        {
          'audit': {
            ...base['audit'] as Map,
            'actor': {'email': 'other'},
          },
        },
      ]) {
        expect(
          () => WalletAdjustmentDetails.fromJson(
            {...base, ...patch},
            owner: owner,
            child: 'child',
            family: 'family',
            entryId: 'entry',
          ),
          throwsFormatException,
        );
      }
      expect(parsed(false).audit, isNull);
    },
  );
  test(
    'family time converts offset timestamps across days and labels old cache fallback',
    () {
      final shanghai = EconomyTime('Asia/Shanghai');
      expect(shanghai.format('2026-11-05T17:00:00Z'), '2026-11-06 01:00');
      expect(shanghai.format('2026-11-06T01:00:00+08:00'), '2026-11-06 01:00');
      expect(
        EconomyTime('America/New_York').format('2026-03-08T07:30:00Z'),
        '2026-03-08 03:30',
      );
      expect(shanghai.format('2026-11-06'), '2026-11-06');
      expect(EconomyTime(null).label, '本机时间');
      expect(EconomyTime('unknown').label, '本机时间');
      expect(shanghai.format('malformed'), '未记录');
      expect(shanghai.format('malformed', empty: '不限'), '未记录');
    },
  );

  Future<ProviderContainer> mount(
    WidgetTester tester,
    FakeAudit repo, {
    bool doubleText = false,
  }) async {
    final parent = StateProvider<String?>((ref) => 'family');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          economyRepositoryProvider.overrideWithValue(repo),
          activeParentFamilyProvider.overrideWith((ref) => ref.watch(parent)),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: TextScaler.linear(doubleText ? 2 : 1),
            ),
            child: const WalletAdjustmentScreen(scope: scope),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalletAdjustmentScreen)),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    container.listen(activeParentFamilyProvider, (_, _) {});
    // Store the controller for authorization-expiry tests without replacing the app.
    parentState = () => container.read(parent.notifier).state = null;
    return container;
  }

  testWidgets(
    'double text details show original actor reason and family date with readable bottom content',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, FakeAudit(), doubleText: true);
      await tester.pumpAndSettle();
      expect(find.textContaining('2026-11-06 01:00'), findsWidgets);
      final scroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('完成家务，补记奖励'),
        240,
        scrollable: scroll,
      );
      expect(find.text('完成家务，补记奖励'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('历史账本不能修改'),
        240,
        scrollable: scroll,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('PIN expiry hides already displayed audit and a late response', (
    tester,
  ) async {
    final repo = FakeAudit();
    final result = Completer<WalletAdjustmentDetails>();
    repo.response = () => result.future;
    await mount(tester, repo);
    parentState!();
    await tester.pump();
    result.complete(parsed());
    await tester.pumpAndSettle();
    expect(find.textContaining('家长授权已结束'), findsOneWidget);
    expect(find.text('完成家务，补记奖励'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await mount(tester, FakeAudit());
    await tester.pumpAndSettle();
    expect(find.text('完成家务，补记奖励'), findsOneWidget);
    parentState!();
    await tester.pumpAndSettle();
    expect(find.text('完成家务，补记奖励'), findsNothing);
  });
  testWidgets(
    'network retry does not replay any financial operation and missing historical audit is explicit',
    (tester) async {
      final repo = FakeAudit()
        ..response = () => throw const SocketException('offline');
      final container = await mount(tester, repo);
      await tester.pumpAndSettle();
      expect(find.textContaining('需联网读取'), findsOneWidget);
      repo.response = () => Future.value(parsed(false));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('历史调账的操作说明已不可用'), findsOneWidget);
      expect(repo.reads, 2);
      expect(repo.calls, isEmpty);
      expect(container.read(walletAdjustmentProvider(scope)).hasError, false);
    },
  );
}

void Function()? parentState;

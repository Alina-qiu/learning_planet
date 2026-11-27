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
import 'package:learning_planet/features/growth/data/growth_repository.dart';
import 'package:learning_planet/features/growth/data/growth_snapshots.dart';
import 'package:learning_planet/features/growth/presentation/growth_screen.dart';
import 'package:learning_planet/features/growth/presentation/growth_portrait.dart';
import 'package:learning_planet/features/home/presentation/home_screen.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'growth_test.dart' show FakeGrowth;
import 'widget_test.dart' show FakeTaskRepository;
import 'support/mock_supabase.dart';

Future<Map<String, dynamic>> growthValue({
  String child = 'child',
  String family = 'family',
  int xp = 1000,
}) async => {
  ...await FakeGrowth().load(child),
  'schema': 1,
  'child_id': child,
  'family_id': family,
  'fetched_at': '2026-11-05T00:00:00Z',
  'xp': xp,
};

class SnapshotGrowth extends FakeGrowth {
  bool offline = true;
  @override
  Future<Map<String, dynamic>> load(String childId) async => {
    ...await super.load(childId),
    'child_id': childId,
    'family_id': 'family',
    'fetched_at': '2026-11-05T00:00:00Z',
    'offline': offline,
  };
}

class GrowthHarness {
  GrowthHarness([OfflineStore? database])
    : store = database ?? OfflineStore(NativeDatabase.memory()) {
    snapshots = GrowthSnapshots(
      api.client,
      store: store,
      accountId: () => owner,
    );
    api.handle = (r) async => MockSupabase.json(
      r,
      await growthValue(
        child: MockSupabase.body(r)['target_child_id'] as String? ?? 'child',
      ),
    );
  }
  final OfflineStore store;
  final api = MockSupabase();
  late final GrowthSnapshots snapshots;
  String? owner = 'owner';
  Future<void> close() async {
    snapshots.dispose();
    await api.client.dispose();
    await store.close();
  }
}

void main() {
  test(
    'growth cache survives a real database reopen and keeps only server-confirmed XP and unlocked assets',
    () async {
      final dir = await Directory.systemTemp.createTemp('growth-cache-');
      final databaseFile = File('${dir.path}/growth.sqlite');
      final first = GrowthHarness(OfflineStore(NativeDatabase(databaseFile)));
      final online = await first.snapshots.load('child');
      expect(online['offline'], false);
      expect(MockSupabase.body(first.api.calls.single), {
        'target_child_id': 'child',
      });
      await first.store.write('owner', 'wallet:child', {'xp': 99999});
      await first.close();
      final next = GrowthHarness(OfflineStore(NativeDatabase(databaseFile)));
      next.api.handle = (r) => throw const SocketException('offline');
      final cached = await next.snapshots.load('child');
      expect(cached['offline'], true);
      expect(cached['xp'], 1000);
      expect((cached['assets'] as List).last['unlocked'], false);
      expect(cached['today'], '2026-11-04');
      expect(cached['fetched_at'], '2026-11-05T00:00:00Z');
      await next.close();
      await dir.delete(recursive: true);
    },
  );
  test(
    'permission denial purges growth; malformed scope or assets cannot fall back as network success',
    () async {
      final h = GrowthHarness();
      addTearDown(h.close);
      await h.snapshots.load('child');
      h.api.handle = (r) async =>
          MockSupabase.json(r, await growthValue(child: 'foreign'));
      await expectLater(h.snapshots.load('child'), throwsFormatException);
      h.api.handle = (r) async => MockSupabase.json(r, {
        ...await growthValue(),
        'appearance': {'avatar': 'explorer', 'pet': 'locked'},
      });
      await expectLater(h.snapshots.load('child'), throwsFormatException);
      h.api.handle = MockSupabase.denied;
      await expectLater(
        h.snapshots.load('child'),
        throwsA(isA<PostgrestException>()),
      );
      expect(await h.store.read('owner', 'growth:child'), isNull);
      h.api.handle = (r) => throw const SocketException('offline');
      await expectLater(
        h.snapshots.load('child'),
        throwsA(isA<SocketException>()),
      );
    },
  );
  for (final change in ['owner', 'child', 'account', 'membership', 'dispose']) {
    test('late growth read is discarded after $change changes', () async {
      final h = GrowthHarness();
      addTearDown(h.close);
      final entered = Completer<void>(), delayed = Completer<http.Response>();
      late http.Request request;
      h.api.handle = (r) {
        request = r;
        entered.complete();
        return delayed.future;
      };
      final loading = h.snapshots.load('child');
      final rejected = expectLater(loading, throwsStateError);
      await entered.future;
      switch (change) {
        case 'owner':
          h.owner = 'other';
        case 'child':
          await h.store.removeChildData('child');
        case 'account':
          await h.store.removeAccountData('owner', 'job');
        case 'membership':
          await h.store.applyFamilyAccess('owner', [
            FamilyAccessState(
              familyId: 'family',
              version: 2,
              active: false,
              lastRevokedVersion: 2,
              childIds: {'child'},
            ),
          ]);
        case 'dispose':
          h.snapshots.dispose();
      }
      delayed.complete(MockSupabase.json(request, await growthValue()));
      await rejected;
      expect(await h.store.read('owner', 'growth:child'), isNull);
    });
  }
  test(
    'newer reads win and a cosmetic write fences cached and in-flight older appearances even after lost reply',
    () async {
      final h = GrowthHarness();
      addTearDown(h.close);
      final delayed = Completer<http.Response>(), entered = Completer<void>();
      late http.Request first;
      h.api.handle = (r) {
        first = r;
        entered.complete();
        return delayed.future;
      };
      final old = h.snapshots.load('child'),
          rejected = expectLater(old, throwsStateError);
      await entered.future;
      h.api.handle = (r) async =>
          MockSupabase.json(r, await growthValue(xp: 2000));
      expect((await h.snapshots.load('child'))['xp'], 2000);
      delayed.complete(MockSupabase.json(first, await growthValue(xp: 0)));
      await rejected;
      h.api.handle = (r) => throw const SocketException('offline');
      expect((await h.snapshots.load('child'))['xp'], 2000);
      await expectLater(
        h.snapshots.change(
          'child',
          () async => throw const SocketException('reply lost'),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(await h.store.read('owner', 'growth:child'), isNull);
      await expectLater(
        h.snapshots.load('child'),
        throwsA(isA<SocketException>()),
      );
    },
  );
  test(
    'concurrent mutations are rejected and reads begun during mutation cannot cache intermediate state',
    () async {
      final h = GrowthHarness();
      addTearDown(h.close);
      await h.snapshots.load('child');
      final entered = Completer<void>(), release = Completer<void>();
      final saving = h.snapshots.change('child', () {
        entered.complete();
        return release.future;
      });
      await entered.future;
      await expectLater(
        h.snapshots.change('child', () async {}),
        throwsStateError,
      );
      await expectLater(h.snapshots.load('child'), throwsStateError);
      release.complete();
      await saving;
      expect(await h.store.read('owner', 'growth:child'), isNull);
      expect((await h.snapshots.load('child'))['offline'], false);
    },
  );
  test(
    'child and membership cleanup remove both growth snapshot and mutation version',
    () async {
      final h = GrowthHarness();
      addTearDown(h.close);
      await h.snapshots.change('child', () async {});
      await h.snapshots.load('child');
      await h.snapshots.load('other-child');
      await h.store.removeChildData('child');
      expect(await h.store.read('owner', 'growth:child'), isNull);
      expect(await h.store.read('owner', 'growth-version:child'), isNull);
      expect(await h.store.read('owner', 'growth:other-child'), isNotNull);
      await h.store.applyFamilyAccess('owner', [
        FamilyAccessState(
          familyId: 'family',
          version: 2,
          active: false,
          lastRevokedVersion: 2,
          childIds: {'other-child'},
        ),
      ]);
      expect(await h.store.read('owner', 'growth:other-child'), isNull);
    },
  );
  test(
    'production repository invalidates cached growth for equipment and awards, including failed acknowledgements',
    () async {
      final h = GrowthHarness();
      addTearDown(h.close);
      final repository = SupabaseGrowthRepository(
        h.api.client,
        store: h.store,
        accountId: () => h.owner,
      );
      for (final kind in ['equip', 'award']) {
        h.api.handle = (r) async => MockSupabase.json(r, await growthValue());
        await repository.load('child');
        h.api.handle = (r) => throw const SocketException('lost reply');
        await expectLater(
          kind == 'equip'
              ? repository.equip('child', 'pet', 'starter_rabbit')
              : repository.award('child', 'request', {'kind': 'praise'}),
          throwsA(isA<SocketException>()),
        );
        expect(await h.store.read('owner', 'growth:child'), isNull);
      }
      h.owner = null;
      await expectLater(repository.load('child'), throwsStateError);
      await expectLater(
        repository.equip('child', 'pet', null),
        throwsStateError,
      );
    },
  );
  test(
    'without local storage valid online snapshots work and disposed repositories cannot return late content',
    () async {
      final api = MockSupabase();
      addTearDown(api.client.dispose);
      await api.signIn();
      api.handle = (r) async => MockSupabase.json(r, await growthValue());
      final snapshots = GrowthSnapshots(api.client);
      await snapshots.change('child', () async {});
      expect((await snapshots.load('child'))['offline'], false);
      snapshots.dispose();
      await expectLater(snapshots.load('child'), throwsStateError);
    },
  );
  testWidgets(
    'offline growth names the old date, disables equipment and resumes online without optimistic rewards',
    (tester) async {
      final growth = SnapshotGrowth();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            growthRepositoryProvider.overrideWithValue(growth),
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
            activeParentFamilyProvider.overrideWithValue('family'),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const GrowthScreen(
              childId: 'child',
              familyId: 'family',
              nickname: '小星',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('离线成长记录'), findsOneWidget);
      expect(find.text('今天已经留下成长记录'), findsNothing);
      await tester.scrollUntilVisible(find.text('自然观察员'), 250);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '自然观察员'))
            .onSelected,
        isNull,
      );
      expect(find.text('家长成长奖励'), findsNothing);
      growth.offline = false;
      ProviderScope.containerOf(
        tester.element(find.byType(GrowthScreen)),
      ).invalidate(growthProvider('child'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('自然观察员'), 250);
      await tester.tap(find.text('自然观察员'));
      await tester.pumpAndSettle();
      expect(growth.equipment, [('avatar', 'explorer')]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'adventure home presents equipped character and pet with semantic labels and marks offline streak',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final growth = SnapshotGrowth()
        ..appearance['avatar'] = 'explorer'
        ..appearance['badge'] = 'level5';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            growthRepositoryProvider.overrideWithValue(growth),
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
          ],
          child: MaterialApp(
            home: HomeScreen(
              childNickname: '星宝',
              children: const [
                ChildProfile(
                  id: 'child',
                  familyId: 'family',
                  nickname: '星宝',
                  grade: 2,
                ),
              ],
              selectedChildId: 'child',
              onChildSelected: (_) {},
              onManageFamily: () {},
              onManageTasks: () {},
              isParentMode: false,
              onParentMode: () {},
              onSignOut: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GrowthPortrait), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('我的角色：自然观察员.*星星徽章.*小星伙伴')),
        findsOneWidget,
      );
      expect(find.text('我的角色与成长\n上次记录：连续 7 天'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/economy/data/economy_commands.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'support/mock_supabase.dart';
import 'economy_test.dart' show FakeEconomy;

class UnavailableEconomy extends FakeEconomy {
  @override
  Future<Map<String, dynamic>> load(String childId, String familyId) async =>
      throw const SocketException('offline');
}

Future<void> databaseAction(
  WidgetTester tester,
  Future<void> Function() action,
) => tester.runAsync(() async {
  await action();
  var quiet = 0;
  for (var i = 0; i < 150; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
    final loading = find
        .byWidgetPredicate(
          (w) =>
              w is LinearProgressIndicator && w.value == null ||
              w is CircularProgressIndicator && w.value == null,
        )
        .evaluate()
        .isNotEmpty;
    final acting =
        find.text('操作处理中，请完成确认或等待结果…').evaluate().isNotEmpty &&
        find.byType(AlertDialog).evaluate().isEmpty;
    if (!loading && !acting) {
      if (++quiet == 3) return;
    } else {
      quiet = 0;
    }
  }
  throw StateError('Economic request UI did not settle');
});

const redeem = {'kind': 'redeem', 'reward_id': 'reward', 'version': 1};
const display = {'title': '家庭电影', 'cost': 120};
const adjust = {
  'kind': 'adjust',
  'coins': 700,
  'xp_amount': 20,
  'reason': '私有调账原因',
  'large_amount_confirmed': true,
};

class CommandRemote implements EconomyCommandRemote {
  final calls = <(String, String, Map<String, dynamic>)>[];
  final receipts = <String, Map<String, dynamic>>{};
  bool loseReply = false, wrongReceipt = false;
  int applied = 0;
  Completer<void>? waiting;
  @override
  Future<Map<String, dynamic>> resolve(
    EconomyCommand request,
    String operation,
  ) async {
    calls.add((request.requestId, operation, request.command));
    await waiting?.future;
    final result =
        receipts[request.requestId] ??
        {
          'owner_id': 'owner',
          'request_id': request.requestId,
          'child_id': request.childId,
          'family_id': request.familyId,
          'kind': request.kind,
          'status': operation == 'inspect'
              ? 'unknown'
              : operation == 'cancel'
              ? 'abandoned'
              : 'applied',
        };
    if (operation != 'inspect' && !receipts.containsKey(request.requestId)) {
      receipts[request.requestId] = result;
      if (result['status'] == 'applied') applied++;
    }
    if (loseReply) {
      loseReply = false;
      throw const SocketException('lost response');
    }
    return {...result, if (wrongReceipt) 'owner_id': 'other'};
  }
}

class CommandHarness {
  CommandHarness([OfflineStore? database])
    : store = database ?? OfflineStore(NativeDatabase.memory()) {
    repository = EconomyCommands(
      store: store,
      remote: remote,
      owner: () => owner,
      authorized: (_) => parent,
      authorizationRevision: () => revision,
    );
  }
  final OfflineStore store;
  final remote = CommandRemote();
  late EconomyCommands repository;
  String? owner = 'owner';
  bool parent = true;
  int revision = 0;
  Future<EconomyCommand> prepare([Map<String, dynamic> command = redeem]) =>
      repository.prepare('child', 'family', command, display);
  Future<EconomyCommand?> pending() => repository.pending('child', 'family');
  Future<EconomyCommand> resolve(EconomyCommand r, String operation) =>
      repository.resolve('child', 'family', r.requestId, operation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'file restart preserves frozen redemption and adjustment intents after lost replies',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'planet-economy-',
      );
      final file = File('${directory.path}/cache.sqlite');
      final remote = CommandRemote();
      OfflineStore store = OfflineStore(NativeDatabase(file));
      EconomyCommands repo() => EconomyCommands(
        store: store,
        remote: remote,
        owner: () => 'owner',
        authorized: (_) => true,
        authorizationRevision: () => 0,
      );
      try {
        for (final command in [redeem, adjust]) {
          var repository = repo();
          final request = await repository.prepare(
            'child',
            'family',
            command,
            display,
          );
          remote.loseReply = true;
          await expectLater(
            repository.resolve('child', 'family', request.requestId, 'submit'),
            throwsA(isA<SocketException>()),
          );
          await store.close();
          store = OfflineStore(NativeDatabase(file));
          repository = repo();
          final recovered = (await repository.pending('child', 'family'))!;
          expect(recovered.requestId, request.requestId);
          expect(recovered.command, command);
          expect(recovered.display, display);
          final appliedBefore = remote.applied;
          expect(
            (await repository.resolve(
              'child',
              'family',
              recovered.requestId,
              'inspect',
            )).status,
            'applied',
          );
          expect(remote.applied, appliedBefore);
          await repository.acknowledge('child', 'family', recovered.requestId);
          expect(await repository.pending('child', 'family'), isNull);
        }
        expect(remote.applied, 2);
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'concurrent prepare admits one intent and freezes caller-owned values',
    () async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      final command = Map<String, dynamic>.from(redeem),
          copy = Map<String, dynamic>.from(display);
      final first = h.repository.prepare('child', 'family', command, copy);
      final second = h.prepare(adjust);
      final rejected = expectLater(second, throwsStateError);
      command['version'] = 99;
      copy['cost'] = 999;
      final request = await first;
      await rejected;
      expect(request.command, redeem);
      expect(request.display, display);
      request.command['version'] = 50;
      expect((await h.pending())!.command, redeem);
      expect(h.remote.calls, isEmpty);
    },
  );
  test(
    'unknown inspect and wrong receipt retain the request; cancellation blocks original retry',
    () async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      final request = await h.prepare();
      expect((await h.resolve(request, 'inspect')).status, 'pending');
      await expectLater(
        h.repository.acknowledge('child', 'family', request.requestId),
        throwsStateError,
      );
      h.remote.wrongReceipt = true;
      await expectLater(h.resolve(request, 'inspect'), throwsStateError);
      h.remote.wrongReceipt = false;
      expect((await h.resolve(request, 'cancel')).status, 'abandoned');
      expect((await h.resolve(request, 'submit')).status, 'abandoned');
      expect(h.remote.applied, 0);
      await h.repository.acknowledge('child', 'family', request.requestId);
      expect((await h.prepare()).requestId, isNot(request.requestId));
    },
  );
  test(
    'adjustment details are redacted without PIN and cannot be sent or acknowledged',
    () async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      final request = await h.prepare(adjust);
      h.parent = false;
      h.revision++;
      final locked = (await h.pending())!;
      expect(locked.locked, true);
      expect(locked.command, isEmpty);
      expect(locked.display, isEmpty);
      await expectLater(h.resolve(request, 'inspect'), throwsStateError);
      expect(h.remote.calls, isEmpty);
      h.parent = true;
      expect((await h.resolve(request, 'submit')).status, 'applied');
      h.parent = false;
      await expectLater(
        h.repository.acknowledge('child', 'family', request.requestId),
        throwsStateError,
      );
      h.parent = true;
      expect((await h.pending())!.command['reason'], adjust['reason']);
    },
  );
  test(
    'account, PIN revision and privacy changes reject late results without overwriting pending intent',
    () async {
      for (final change in ['owner', 'pin', 'privacy']) {
        final h = CommandHarness();
        try {
          final request = await h.prepare(adjust);
          final waiting = h.remote.waiting = Completer<void>();
          final running = h.resolve(request, 'submit');
          final rejected = expectLater(running, throwsStateError);
          for (var i = 0; i < 100 && h.remote.calls.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(h.remote.calls, hasLength(1));
          if (change == 'owner') {
            h.owner = 'other';
          } else if (change == 'pin') {
            h.revision++;
          } else {
            h.store.privacyGeneration++;
          }
          waiting.complete();
          await rejected;
          h.owner = 'owner';
          expect((await h.pending())!.status, 'pending');
        } finally {
          await h.store.close();
        }
      }
    },
  );
  test(
    'child, membership and account cleanup remove only their scoped financial intents and forbid late restoration',
    () async {
      for (final mode in ['child', 'membership', 'account']) {
        final h = CommandHarness();
        try {
          await h.repository.prepare(
            'other-child',
            'other-family',
            redeem,
            display,
          );
          final request = await h.prepare();
          await h.store.write('other-owner', 'economy-command:other-child', {
            'child_id': 'other-child',
            'family_id': 'family',
            'keep': true,
          });
          final waiting = h.remote.waiting = Completer<void>(),
              running = h.resolve(request, 'submit');
          final rejected = expectLater(running, throwsStateError);
          for (var i = 0; i < 100 && h.remote.calls.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          if (mode == 'child') {
            await h.store.removeChildData('child');
          }
          if (mode == 'membership') {
            await h.store.applyFamilyAccess('owner', [
              FamilyAccessState(
                familyId: 'family',
                version: 2,
                active: false,
                lastRevokedVersion: 2,
                childIds: {'child'},
              ),
            ]);
          }
          if (mode == 'account') {
            await h.store.removeAccountData('owner', 'job');
          }
          waiting.complete();
          await rejected;
          expect(
            await h.store.read('other-owner', 'economy-command:other-child'),
            containsPair('keep', true),
          );
          if (mode != 'account') {
            expect(
              await h.store.read('owner', 'economy-command:other-child'),
              isNotNull,
            );
          }
          final rows = await h.store
              .customSelect(
                "SELECT * FROM offline_cache WHERE owner='owner' AND cache_key='economy-command:child'",
              )
              .get();
          expect(rows, isEmpty);
        } finally {
          await h.store.close();
        }
      }
    },
  );
  test(
    'SDK sends only immutable command fields and binds server receipt to account child and family',
    () async {
      final backend = MockSupabase();
      addTearDown(backend.close);
      final request = EconomyCommand({
        'request_id': 'request',
        'child_id': 'child',
        'family_id': 'family',
        'kind': 'redeem',
        'status': 'pending',
        'command': redeem,
        'display': display,
      });
      backend.handle = (r) {
        expect(r.url.path, '/rest/v1/rpc/resolve_economy_command');
        expect(MockSupabase.body(r), {
          'target_child_id': 'child',
          'request_id': 'request',
          'command': redeem,
          'operation': 'inspect',
        });
        expect(r.body, isNot(contains('家庭电影')));
        return MockSupabase.json(r, {'status': 'unknown'});
      };
      await SupabaseEconomyCommandRemote(
        backend.client,
      ).resolve(request, 'inspect');
    },
  );

  Future<ProviderContainer> mount(
    WidgetTester tester,
    CommandHarness h, {
    bool parent = false,
    int tab = 0,
    bool unavailable = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        economyCommandsProvider.overrideWithValue(h.repository),
        economyRepositoryProvider.overrideWithValue(
          unavailable ? UnavailableEconomy() : FakeEconomy(),
        ),
        taskRepositoryProvider.overrideWithValue(
          const UnconfiguredTaskRepository(),
        ),
        authorizationClockProvider.overrideWith(
          (ref) => Stream.value(DateTime.now()),
        ),
      ],
    );
    container.read(parentModeProvider.notifier).state = parent;
    container.read(parentFamilyIdProvider.notifier).state = parent
        ? 'family'
        : null;
    container.read(parentAuthorizedUntilProvider.notifier).state =
        DateTime.now().add(const Duration(minutes: 10));
    h.parent = parent;
    await databaseAction(
      tester,
      () => tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: EconomyScreen(
              childId: 'child',
              familyId: 'family',
              initialTab: tab,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> tap(WidgetTester tester, String text) =>
      databaseAction(tester, () async {
        await tester.ensureVisible(find.text(text));
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      });
  testWidgets(
    'lost redemption reply survives page recreation and can inspect without resubmitting',
    (tester) async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      var container = await mount(tester, h);
      h.remote.loseReply = true;
      await tap(tester, '申请');
      await tap(tester, '确认申请');
      expect(h.remote.applied, 1);
      expect(find.text('核对结果'), findsOneWidget);
      final first = h.remote.calls.single.$1;
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await mount(tester, h);
      expect(h.remote.calls, hasLength(1));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '申请'))
            .onPressed,
        isNull,
      );
      await tap(tester, '核对结果');
      expect(h.remote.calls.last.$1, first);
      expect(h.remote.calls.last.$2, 'inspect');
      expect(h.remote.applied, 1);
      await tap(tester, '我已了解');
      expect(await tester.runAsync(h.pending), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'saved intent can be stopped explicitly even when catalog loading is unavailable',
    (tester) async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      await tester.runAsync(h.prepare);
      final container = await mount(tester, h, unavailable: true);
      expect(h.remote.calls, isEmpty);
      expect(find.textContaining('本机没有可用的奖励记录'), findsOneWidget);
      await tap(tester, '停止未执行请求');
      expect(find.textContaining('已受理的兑换或调账不会撤回'), findsOneWidget);
      await tap(tester, '确认');
      expect(h.remote.calls.single.$2, 'cancel');
      expect(h.remote.applied, 0);
      await tap(tester, '我已了解');
      expect(await tester.runAsync(h.pending), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'PIN loss hides adjustment details and recovery actions at double phone text size',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = CommandHarness();
      addTearDown(h.store.close);
      await tester.runAsync(() => h.prepare(adjust));
      final container = await mount(tester, h, parent: true);
      expect(find.textContaining('私有调账原因'), findsOneWidget);
      h.parent = false;
      h.revision++;
      await databaseAction(tester, () async {
        container.read(parentModeProvider.notifier).state = false;
      });
      expect(find.textContaining('私有调账原因'), findsNothing);
      expect(find.text('重试原请求'), findsNothing);
      expect(find.textContaining('有一笔家长调账待核对'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'account change while request confirmation is open prevents creating or sending intent',
    (tester) async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      final container = await mount(tester, h);
      await tap(tester, '申请');
      h.owner = 'other';
      await tap(tester, '确认申请');
      expect(h.remote.calls, isEmpty);
      h.owner = 'owner';
      expect(await tester.runAsync(h.pending), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'high adjustment persists only after both confirmations and keeps original values after a lost reply',
    (tester) async {
      final h = CommandHarness();
      addTearDown(h.store.close);
      final container = await mount(tester, h, parent: true, tab: 2);
      h.remote.loseReply = true;
      await tap(tester, '家长调账');
      await tester.enterText(
        find.widgetWithText(TextFormField, '金币变化（允许负数，只扣可用余额）'),
        '700',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '增加XP（不可扣减）'),
        '20',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '原因'),
        '完成约定的奖励',
      );
      await tap(tester, '提交调账');
      expect(find.text('高额调账再次确认'), findsOneWidget);
      expect(await tester.runAsync(h.pending), isNull);
      expect(h.remote.calls, isEmpty);
      await tap(tester, '确认高额调账');
      final pending = await tester.runAsync(h.pending);
      expect(pending!.command, {
        'kind': 'adjust',
        'coins': 700,
        'xp_amount': 20,
        'reason': '完成约定的奖励',
        'large_amount_confirmed': true,
      });
      expect(h.remote.applied, 1);
      await tap(tester, '核对结果');
      expect(h.remote.applied, 1);
      expect(h.remote.calls.last.$1, pending.requestId);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

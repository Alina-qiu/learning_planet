import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/economy/presentation/reward_editor.dart';
import 'economy_test.dart' show FakeEconomy;
import 'support/mock_supabase.dart';

class LimitedEconomy extends FakeEconomy {
  final changes = <String, dynamic>{
    'stock_total': 2,
    'stock_available': 1,
    'stock_reserved': 1,
    'stock_fulfilled': 0,
    'quota_period': 'week',
    'quota_limit': 2,
    'quota_remaining': 1,
    'quota_resets_on': '2026-11-09',
    'family_timezone': 'Asia/Shanghai',
    'can_request': true,
  };
  Object? fail;
  @override
  Future<Map<String, dynamic>> load(String childId, String familyId) async {
    final data = await super.load(childId, familyId);
    data['rewards'] = [
      {...(data['rewards'] as List).single as Map<String, dynamic>, ...changes},
    ];
    return data;
  }

  @override
  Future<void> request(
    String childId,
    String rewardId,
    String key,
    int version,
  ) async {
    await super.request(childId, rewardId, key, version);
    if (fail case final error?) {
      fail = null;
      throw error;
    }
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    LimitedEconomy repository, {
    bool parent = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          economyRepositoryProvider.overrideWithValue(repository),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          activeParentFamilyProvider.overrideWithValue(
            parent ? 'family' : null,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const EconomyScreen(childId: 'child', familyId: 'family'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> visible(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> editor(
    WidgetTester tester,
    Map<String, dynamic> initial,
    void Function(Map<String, dynamic>?) onSave,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onSave(
                  await Navigator.of(context).push<Map<String, dynamic>>(
                    MaterialPageRoute(
                      builder: (_) => RewardEditor(initial: initial),
                    ),
                  ),
                );
              },
              child: const Text('配置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
  }

  final defaults = <String, dynamic>{
    'title': '家庭电影',
    'cost': 120,
    'version': 7,
    'stock_fulfilled': 1,
    'stock_reserved': 1,
  };
  final stock = find.widgetWithText(TextFormField, '家庭共享总库存（留空不限）');
  final quota = find.widgetWithText(TextFormField, '每个周期最多兑换次数');

  testWidgets(
    'shared inventory and family-time quota are visible and exhausted limits block requests at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = LimitedEconomy()
        ..changes.addAll({
          'stock_available': 0,
          'can_request': false,
          'blocked_reason': '库存已用完',
        });
      await mount(tester, live, parent: true);
      expect(find.textContaining('已预留 1 份'), findsOneWidget);
      expect(find.textContaining('2026-11-09（Asia/Shanghai）'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '申请'))
            .onPressed,
        isNull,
      );
      expect(find.byTooltip('编辑奖励'), findsOneWidget);
      expect(tester.takeException(), isNull);
      live.changes.addAll({
        'stock_available': 1,
        'quota_remaining': 0,
        'blocked_reason': '已达兑换次数限制',
      });
      await tester.tap(find.byTooltip('刷新钱包与申请'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前剩余 0 次'), findsOneWidget);
      expect(live.requests, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lost request acknowledgement remains retryable at zero stock and preserves original UUID price and version',
    (tester) async {
      final live = LimitedEconomy()
        ..fail = const SocketException('Lost response');
      await mount(tester, live);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认申请'));
      await tester.pumpAndSettle();
      final first = live.calls.single;
      live.changes.addAll({
        'cost': 300,
        'version': 2,
        'stock_available': 0,
        'can_request': false,
        'blocked_reason': '库存已用完',
      });
      await tester.tap(find.byTooltip('刷新钱包与申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试申请'));
      await tester.pumpAndSettle();
      expect(find.textContaining('冻结 120 金币'), findsOneWidget);
      expect(find.textContaining('不会再次冻结'), findsOneWidget);
      await tester.tap(find.text('确认申请'));
      await tester.pumpAndSettle();
      expect(live.calls, [first, first]);
      expect(find.text('重试申请'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'definite rule rejection refreshes the offer and a new confirmation uses its changed version',
    (tester) async {
      final live = LimitedEconomy()
        ..fail = const PostgrestException(
          message: 'Rules changed',
          code: 'P0001',
        );
      await mount(tester, live);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      live.changes.addAll({'cost': 300, 'version': 2});
      await tester.tap(find.text('确认申请'));
      await tester.pumpAndSettle();
      expect(find.text('重试申请'), findsNothing);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      expect(find.textContaining('冻结 300 金币'), findsOneWidget);
      await tester.tap(find.text('确认申请'));
      await tester.pumpAndSettle();
      expect(live.calls.first, startsWith('request:1:'));
      expect(live.calls.last, startsWith('request:2:'));
      expect(
        live.calls.first.split(':').last,
        isNot(live.calls.last.split(':').last),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'editor rejects stock below reservations and validates quota before returning a versioned config',
    (tester) async {
      Map<String, dynamic>? saved;
      await editor(tester, defaults, (value) => saved = value);
      await visible(tester, stock);
      await tester.enterText(stock, '1');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await visible(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每月').last);
      await tester.pumpAndSettle();
      await visible(tester, quota);
      await tester.enterText(quota, '2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await visible(tester, find.text('保存奖励'));
      await tester.tap(find.text('保存奖励'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.textContaining('总库存不能少于'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        stock,
        -180,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(stock, '3');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await visible(tester, find.text('保存奖励'));
      await tester.tap(find.text('保存奖励'));
      await tester.pumpAndSettle();
      expect(saved?['stock_total'], 3);
      expect(saved?['quota_period'], 'month');
      expect(saved?['quota_limit'], 2);
      expect(saved?['expected_version'], 7);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'editor can explicitly remove stock and quota limits without leaving a stale quota value',
    (tester) async {
      Map<String, dynamic>? saved;
      await editor(tester, {
        ...defaults,
        'stock_total': 10,
        'quota_period': 'day',
        'quota_limit': 2,
      }, (value) => saved = value);
      await visible(tester, stock);
      await tester.enterText(stock, '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await visible(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不限次数').last);
      await tester.pumpAndSettle();
      await visible(tester, find.text('保存奖励'));
      await tester.tap(find.text('保存奖励'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved?['stock_total'], isNull);
      expect(saved?['quota_limit'], isNull);
      expect(saved?['quota_period'], 'none');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'saving after scrolling still validates offscreen price and missing quota fields',
    (tester) async {
      Map<String, dynamic>? saved;
      await editor(tester, {
        ...defaults,
        'cost': 0,
        'quota_period': 'day',
      }, (value) => saved = value);
      await visible(tester, find.text('保存奖励'));
      await tester.tap(find.text('保存奖励'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.textContaining('价格需为'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'repository bounds its first catalog read and preserves authoritative quota fields',
    () async {
      final api = MockSupabase();
      addTearDown(api.close);
      await api.signIn();
      api.handle = (request) {
        if (request.url.path.endsWith('wallet_overview')) {
          return MockSupabase.json(request, {
            'child_id': 'child',
            'coin_balance': 100,
          });
        }
        expect(request.url.path.endsWith('economy_page'), true);
        final args = MockSupabase.body(request);
        expect(args['page_size'], 50);
        expect(args['after_id'], null);
        final items = <Map<String, dynamic>>[
          if (args['section'] == 'rewards')
            for (var i = 100; i > 50; i--)
              {
                'id': 'reward-$i',
                'family_id': 'family',
                'created_at': DateTime.utc(
                  2026,
                  1,
                  1,
                ).add(Duration(seconds: i)).toIso8601String(),
                'stock_available': 0,
                'quota_remaining': 0,
                'can_request': false,
              },
        ];
        return MockSupabase.json(request, {
          'owner_id': MockSupabase.firstUser,
          'child_id': 'child',
          'family_id': 'family',
          'section': args['section'],
          'include_inactive': false,
          'family_today': '2026-11-05',
          'items': items,
          'next_cursor': items.isEmpty
              ? null
              : {
                  'id': items.last['id'],
                  'created_at': items.last['created_at'],
                },
        });
      };
      final data = await SupabaseEconomyRepository(
        api.client,
      ).load('child', 'family');
      expect(api.calls.length, 5);
      expect((data['rewards'] as List).length, 50);
      expect((data['rewards'] as List).last['can_request'], false);
      expect((data['cursors'] as Map)['rewards'], isNotNull);
    },
  );
}

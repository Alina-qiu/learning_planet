import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/domain/xp_progress.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/economy/presentation/reward_editor.dart';

class FakeEconomy implements EconomyRepository {
  final calls = <String>[];
  String status = 'requested';
  int requests = 0;
  @override
  Future<Map<String, dynamic>> load(String childId, String familyId) async => {
    'overview': {
      'coin_balance': 300,
      'frozen_balance': 120,
      'xp': 300,
      'pending_coins': 0,
      'reconciled': true,
      'daily_soft_limit': 150,
      'month_income': 420,
      'month_spent': 0,
    },
    'rewards': [
      {
        'id': 'reward',
        'title': '家庭电影',
        'cost': 120,
        'version': 1,
        'active': true,
        'description': '一起看电影',
        'rules': '周末',
        'request_days': 7,
        'fulfillment_days': 30,
        'minimum_level': 1,
      },
    ],
    'redemptions': [
      {
        'id': 'redemption',
        'reward_title': '旧价格电影',
        'reward_rules': '旧规则',
        'status': status,
        'frozen_amount': 120,
        'expires_at': '2026-10-10',
      },
    ],
    'ledger': [],
    'pending': [],
  };
  @override
  Future<void> request(
    String childId,
    String rewardId,
    String key,
    int version,
  ) async {
    requests++;
    calls.add('request:$version:$key');
  }

  @override
  Future<void> transition(String id, String operation, String reason) async {
    calls.add('$operation:$reason');
    status = operation == 'approve' ? 'approved' : 'fulfilled';
  }

  @override
  Future<void> saveReward(
    String familyId,
    Map<String, dynamic> config, {
    String? rewardId,
  }) async {}
  @override
  Future<void> adjust(String childId, Map<String, dynamic> command) async {}
  @override
  Future<void> limit(String childId, int limit) async {}
  @override
  Future<void> decide(String id, bool approve, String reason) async {}
  @override
  Future<void> reconcile(String childId) async {}
}

void main() {
  test('XP level thresholds are1–50 with current-level progress', () {
    for (final pair in const [
      (0, 1),
      (99, 1),
      (100, 2),
      (299, 2),
      (300, 3),
      (122499, 49),
      (122500, 50),
      (999999, 50),
    ]) {
      expect(XpProgress(pair.$1).level, pair.$2);
    }
    expect(const XpProgress(150).earnedInLevel, 50);
    expect(const XpProgress(150).nextRequired, 200);
    expect(const XpProgress(150).fraction, 0.25);
    expect(const XpProgress(122500).fraction, 1);
  });
  Future<void> mount(
    WidgetTester tester,
    FakeEconomy live, {
    bool parent = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          economyRepositoryProvider.overrideWithValue(live),
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

  testWidgets(
    'child mode can request rewards but never configures prices or approves claims',
    (tester) async {
      final live = FakeEconomy();
      await mount(tester, live);
      expect(find.text('新增奖励'), findsNothing);
      expect(find.textContaining('Lv.3'), findsOneWidget);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      expect(live.requests, 0);
      expect(find.textContaining('冻结 120 金币'), findsOneWidget);
      await tester.tap(find.text('确认申请'));
      await tester.pumpAndSettle();
      expect(live.requests, 1);
      expect(live.calls.first, startsWith('request:1:'));
      await tester.tap(find.text('兑换记录'));
      await tester.pumpAndSettle();
      expect(find.text('批准'), findsNothing);
      expect(find.text('确认已履约'), findsNothing);
      expect(find.text('取消申请'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'parent approval needs a reason and fulfillment is a separate confirmation',
    (tester) async {
      final live = FakeEconomy();
      await mount(tester, live, parent: true);
      await tester.tap(find.text('兑换记录'));
      await tester.pumpAndSettle();
      expect(find.text('确认已履约'), findsNothing);
      await tester.tap(find.text('批准'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(live.calls, isEmpty);
      await tester.enterText(find.byType(TextField), '周末兑现');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(live.calls, ['approve:周末兑现']);
      expect(find.text('确认已履约'), findsOneWidget);
      expect(find.text('取消申请'), findsNothing);
      await tester.tap(find.text('确认已履约'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '已看电影');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(live.calls.last, 'fulfill:已看电影');
      expect(find.text('确认已履约'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'approved snapshot is visible while child cannot cancel or fulfill it',
    (tester) async {
      await mount(tester, FakeEconomy()..status = 'approved');
      await tester.tap(find.text('兑换记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('旧价格电影'), findsOneWidget);
      expect(find.textContaining('旧规则'), findsOneWidget);
      expect(find.text('取消申请'), findsNothing);
      expect(find.text('确认已履约'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'wallet ledger exposes soft limit but child has no adjustment controls',
    (tester) async {
      await mount(tester, FakeEconomy());
      await tester.tap(find.text('金币与XP账本'));
      await tester.pumpAndSettle();
      expect(find.textContaining('每日软上限 150'), findsOneWidget);
      expect(find.text('家长调账'), findsNothing);
      expect(find.text('按账本重算钱包'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('reward editor presets populate transparent prices', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const RewardEditor(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('动画片30分钟 120金币'));
    await tester.pump();
    expect(find.text('动画片30分钟'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

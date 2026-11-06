import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_rewards.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'review_module_test.dart' show FakeReviewRepository;
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

/// Server response fixtures only; the actual settlement is covered by PostgreSQL.
class MilestoneReview extends FakeReviewRepository {
  int step = 3, coins = 25, xp = 20;
  String? rewardStatus;
  bool pending = false;
  @override
  Future<Map<String, dynamic>> task(String taskId) async {
    final data = await super.task(taskId);
    (data['task'] as Map<String, dynamic>).addAll({
      'review_reward_policy': 2,
      'coin_reward': coins,
      'xp_reward': xp,
    });
    (data['items'][0] as Map<String, dynamic>).addAll({
      'review_step_snapshot': step,
      'reward_status':
          rewardStatus ??
          (status == 'completed'
              ? 'awarded'
              : result == true
              ? 'eligible'
              : 'pending'),
      'reward_coins': status == 'completed' ? coins : 0,
      'reward_xp': status == 'completed' ? xp : 0,
      if (pending) 'pending_answer': 'yin2 hang2',
    });
    if (pending) {
      data['offline_cache'] = true;
      data['offline_enabled'] = true;
      data['local_completion'] = true;
    }
    return data;
  }
}

void main() {
  test(
    'rules honor the server contract and preserve legacy or missing policy',
    () {
      expect(usesReviewMilestones({'review_reward_policy': 2}), isTrue);
      for (final task in [
        <String, dynamic>{},
        {'review_reward_policy': 1},
      ]) {
        expect(usesReviewMilestones(task), isFalse);
        expect(reviewRewardRules(task), contains('每答对一题5个'));
      }
      final rules = reviewRewardRules({'review_reward_policy': 2});
      for (final text in [
        '15金币 / 15XP',
        '25金币 / 20XP',
        '40金币 / 30XP',
        '每个阶段只奖励一次',
        '全部作答并完成后',
      ]) {
        expect(rules, contains(text));
      }
    },
  );
  test('all phase labels distinguish unpaid practice and server awards', () {
    for (final entry in {
      0: '订正',
      1: '1天练习',
      2: '3天练习',
      3: '7天复测',
      4: '30天掌握',
    }.entries) {
      final pending = reviewItemReward({
        'review_step_snapshot': entry.key,
        'reward_status': 'pending',
      });
      expect(pending, startsWith(entry.value));
      expect(pending, isNot(contains('本次阶段奖励')));
      if ([1, 2].contains(entry.key)) expect(pending, contains('练习不另发阶段奖励'));
    }
    expect(
      reviewItemReward({
        'review_step_snapshot': 3,
        'reward_status': 'awarded',
        'reward_coins': 25,
        'reward_xp': 20,
      }),
      contains('25 金币 / 20 XP'),
    );
    expect(reviewItemReward({'reward_status': 'unknown'}), contains('阶段待确认'));
  });
  test(
    'pending, stale, wrong and duplicate statuses never assert an award',
    () {
      for (final entry in {
        'eligible': '完成本任务后结算',
        'already_rewarded': '不重复发奖',
        'stale': '不推进阶段',
        'wrong': '不发阶段奖励',
        'practice': '不另发阶段奖励',
      }.entries) {
        final text = reviewItemReward({
          'review_step_snapshot': 0,
          'reward_status': entry.key,
        });
        expect(text, contains(entry.value));
        expect(text, isNot(contains('本次阶段奖励')));
      }
      expect(
        reviewItemReward({
          'review_step_snapshot': 4,
          'pending_answer': 'a',
          'reward_status': 'awarded',
          'reward_coins': 40,
          'reward_xp': 30,
        }),
        contains('待服务端确认'),
      );
    },
  );
  Future<void> mount(
    WidgetTester tester,
    FakeReviewRepository repository, {
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewRepositoryProvider.overrideWithValue(repository),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          feedbackPreferencesStoreProvider.overrideWithValue(
            MemoryFeedbackPreferences(
              const FeedbackPreferences(animation: false),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ReviewSessionScreen(taskId: 'task', childId: 'child'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'correct milestone shows eligibility before completion and uses server settled totals',
    (tester) async {
      final server = MilestoneReview()..status = 'in_progress';
      await mount(tester, server);
      expect(find.textContaining('7天复测 · 阶段奖励以服务端结算为准'), findsOneWidget);
      expect(find.textContaining('标准答案：'), findsNothing);
      await tester.enterText(find.byType(TextField), 'yin2 hang2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('有点把握'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('有点把握'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('提交答案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交答案'));
      await tester.pumpAndSettle();
      expect(find.textContaining('完成本任务后结算；同周期只奖励一次'), findsOneWidget);
      expect(find.textContaining('本次阶段奖励 25'), findsNothing);
      await tester.ensureVisible(find.text('完成复习并结算'));
      await tester.tap(find.text('完成复习并结算'));
      await tester.pumpAndSettle();
      expect(server.completionCalls, 1);
      expect(find.text('25 金币 · 20 XP'), findsOneWidget);
      expect(
        find.textContaining('7天复测 · 本次阶段奖励 25 金币 / 20 XP'),
        findsOneWidget,
      );
      expect(find.textContaining('已入账金额以钱包和账本为准'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'offline pending completion keeps milestone rewards unconfirmed',
    (tester) async {
      final server = MilestoneReview()
        ..status = 'completed'
        ..pending = true
        ..step = 4;
      await mount(tester, server);
      expect(find.text('完成操作已保存在本机，等待服务端判题与结算。'), findsOneWidget);
      expect(find.textContaining('30天掌握 · 作答与阶段奖励待服务端确认'), findsOneWidget);
      expect(find.textContaining('本次阶段奖励'), findsNothing);
      expect(find.text('复习已完成，奖励已由服务端确认'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'stale reward explanation and full rules remain readable at 360 pixels and double text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = MilestoneReview()
        ..status = 'completed'
        ..result = true
        ..coins = 0
        ..xp = 0
        ..rewardStatus = 'stale';
      await mount(tester, server, scale: 2);
      expect(find.text('0 金币 · 0 XP'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('本次保留作答'),
        200,
        maxScrolls: 20,
      );
      expect(find.textContaining('本次保留作答'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('订正正确：15金币'),
        200,
        maxScrolls: 20,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'legacy review page continues to show its original reward contract',
    (tester) async {
      await mount(tester, FakeReviewRepository());
      await tester.scrollUntilVisible(
        find.textContaining('金币每答对一题5个'),
        150,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      expect(find.textContaining('XP每作答一题3点'), findsOneWidget);
      expect(find.textContaining('每个阶段只奖励一次'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

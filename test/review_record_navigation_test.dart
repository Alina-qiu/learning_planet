import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/home/presentation/home_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_confidence.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'review_module_test.dart' show FakeReviewRepository;
import 'support/task_workload.dart' show WorkloadTasks;
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

class RecordedReview extends FakeReviewRepository {
  @override
  Future<Map<String, dynamic>> task(String taskId) async {
    final data = await super.task(taskId);
    if (status != 'completed') {
      (data['items'] as List).add({
        'wrong_question_id': 'unanswered',
        'sequence': 2,
        'prompt': '未完成的题目',
        'review_kind': 'question',
        'result': null,
      });
    }
    return data;
  }
}

Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Widget home() => HomeScreen(
  childNickname: '小星',
  children: const [
    ChildProfile(id: 'child', familyId: 'family', nickname: '小星', grade: 2),
  ],
  selectedChildId: 'child',
  onChildSelected: (_) {},
  onManageFamily: () {},
  onManageTasks: () {},
  isParentMode: false,
  onParentMode: () {},
  onSignOut: () async {},
);

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'review record footer clears system navigation at ${scale}x text',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(bottom: 48);
        tester.view.viewPadding = const FakeViewPadding(bottom: 48);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final live = RecordedReview()
          ..status = 'completed'
          ..result = true
          ..submitted = '4';
        final data = await live.task('task');
        (data['task'] as Map<String, dynamic>).addAll({
          'review_reward_policy': 2,
          'review_auto_complete': true,
        });
        final item = (data['items'] as List).single as Map<String, dynamic>;
        data['items'] = [
          for (var i = 0; i < 3; i++)
            {...item, 'wrong_question_id': 'q$i', 'sequence': i + 1},
        ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              reviewTaskProvider('task').overrideWith((ref) async => data),
              taskRepositoryProvider.overrideWithValue(WorkloadTasks([])),
              feedbackPreferencesStoreProvider.overrideWithValue(
                MemoryFeedbackPreferences(),
              ),
            ],
            child: const MaterialApp(
              home: ReviewSessionScreen(taskId: 'task', childId: 'child'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final footer = find.textContaining('订正正确：');
        await tester.scrollUntilVisible(footer, 300);
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(footer, findsOneWidget);
        expect(tester.getBottomRight(footer).dy, lessThanOrEqualTo(752));
        expect(tester.getTopLeft(footer).dy, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final forbidden in [false, true]) {
    testWidgets(
      '${forbidden ? 'permission' : 'uncached offline'} failure is readable and can retry',
      (tester) async {
        final store = OfflineStore(NativeDatabase.memory());
        final live = RecordedReview()
          ..status = 'completed'
          ..result = false
          ..submitted = 'yin2 xing2'
          ..online = forbidden
          ..forbidden = forbidden;
        final reviews = CachedReviewRepository(live, store, () => 'owner');
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                reviewRepositoryProvider.overrideWithValue(reviews),
                taskRepositoryProvider.overrideWithValue(WorkloadTasks([])),
                feedbackPreferencesStoreProvider.overrideWithValue(
                  MemoryFeedbackPreferences(),
                ),
              ],
              child: const MaterialApp(
                home: ReviewSessionScreen(taskId: 'task', childId: 'child'),
              ),
            ),
          );
          await settleIo(tester);
          expect(
            find.text(
              forbidden
                  ? '暂时无法读取这次复习，请返回首页刷新后重试。'
                  : '暂时无法连接服务，且本机没有可用的这次复习记录。请联网后重试。',
            ),
            findsOneWidget,
          );
          expect(find.textContaining('SocketException'), findsNothing);
          expect(find.textContaining('Denied'), findsNothing);
          live
            ..online = true
            ..forbidden = false;
          await tester.tap(find.text('重试'));
          await settleIo(tester);
          await tester.scrollUntilVisible(find.text('你的答案：yin2 xing2'), 200);
          expect(find.text('你的答案：yin2 xing2'), findsOneWidget);
          expect(live.transitionCalls, 0);
          expect(live.completionCalls, 0);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(store.close);
        }
      },
    );
  }
  for (final fromHome in [true, false]) {
    for (final status in [
      TaskStatus.completed,
      TaskStatus.abandoned,
      TaskStatus.skipped,
    ]) {
      testWidgets(
        '${fromHome ? 'home' : 'task list'} opens cached ${status.name} review without mutations',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final store = OfflineStore(NativeDatabase.memory());
          final live = RecordedReview()
            ..status = status == TaskStatus.skipped ? 'expired' : status.name
            ..result = false
            ..submitted = 'yin2 xing2'
            ..submittedConfidence = ReviewConfidence.somewhat;
          final reviews = CachedReviewRepository(live, store, () => 'owner');
          await tester.runAsync(() async => reviews.task('task'));
          live.online = false;
          final tasks = WorkloadTasks([
            TaskItem(
              id: 'task',
              childId: 'child',
              title: '今日错题与拼音复习',
              status: status,
              coinReward: 0,
              xpReward: 0,
              dueDate: DateTime.now(),
              accumulatedSeconds: 180,
              sourceType: 'automatic_wrong_review',
            ),
          ]);
          try {
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  taskRepositoryProvider.overrideWithValue(tasks),
                  reviewRepositoryProvider.overrideWithValue(reviews),
                  familiesProvider.overrideWith((ref) async => []),
                  feedbackPreferencesStoreProvider.overrideWithValue(
                    MemoryFeedbackPreferences(),
                  ),
                ],
                child: MaterialApp(
                  home: fromHome
                      ? home()
                      : const TaskManagementScreen(
                          childId: 'child',
                          childNickname: '小星',
                          isParentMode: false,
                        ),
                ),
              ),
            );
            await settleIo(tester);
            await tester.scrollUntilVisible(find.text('查看记录'), 250);
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('查看记录'));
            await tester.pumpAndSettle();
            expect(find.text('查看记录').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('查看记录'));
            await settleIo(tester);
            expect(find.byType(ReviewSessionScreen), findsOneWidget);
            await tester.scrollUntilVisible(find.text('作答把握：有点把握'), 250);
            expect(find.text('你的答案：yin2 xing2'), findsOneWidget);
            expect(find.text('标准答案：yín háng'), findsOneWidget);
            expect(find.text('解析：这里读háng'), findsOneWidget);
            expect(find.byType(TextField), findsNothing);
            expect(find.text('提交答案'), findsNothing);
            expect(find.text('开始复习'), findsNothing);
            expect(find.text('完成复习并结算'), findsNothing);
            if (status != TaskStatus.completed) {
              await tester.scrollUntilVisible(find.text('本题未作答'), 200);
              expect(find.text('本题未作答'), findsOneWidget);
            }
            expect(live.transitionCalls, 0);
            expect(live.completionCalls, 0);
            expect(tasks.completions, 0);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(store.close);
          }
        },
      );
    }

    testWidgets(
      '${fromHome ? 'home' : 'task list'} keeps ordinary completed tasks disabled',
      (tester) async {
        final tasks = WorkloadTasks([
          TaskItem(
            id: 'ordinary',
            childId: 'child',
            title: '普通任务',
            status: TaskStatus.completed,
            coinReward: 5,
            xpReward: 5,
            dueDate: DateTime.now(),
            accumulatedSeconds: 20,
          ),
        ]);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              taskRepositoryProvider.overrideWithValue(tasks),
              familiesProvider.overrideWith((ref) async => []),
              feedbackPreferencesStoreProvider.overrideWithValue(
                MemoryFeedbackPreferences(),
              ),
            ],
            child: MaterialApp(
              home: fromHome
                  ? home()
                  : const TaskManagementScreen(
                      childId: 'child',
                      childNickname: '小星',
                      isParentMode: false,
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('已完成'), 250);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '已完成'))
              .onPressed,
          isNull,
        );
        expect(find.text('查看记录'), findsNothing);
        expect(tasks.completions, 0);
      },
    );
  }
}

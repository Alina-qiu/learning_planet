import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/tasks/data/schedule_repository.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'widget_test.dart' show FakeTaskRepository;

void main() {
  testWidgets('伪造客户端模式开关不能显示创建或补签入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(FakeTaskRepository()),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const TaskManagementScreen(
            childId: 'child-1',
            childNickname: '星宝',
            familyId: 'family-1',
            isParentMode: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byTooltip('家长补签'), findsNothing);
  });
  testWidgets('周期编辑器创建配置并安全释放输入控制器', (tester) async {
    ScheduleConfig? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await Navigator.of(context).push<ScheduleConfig>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ScheduleEditor(today: DateTime(2026, 9, 16)),
                  ),
                );
              },
              child: const Text('打开配置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '任务名称'), '每日阅读');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存配置'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(saved?.title, '每日阅读');
    expect(saved?.recurrence, ScheduleRecurrence.daily);
    expect(tester.takeException(), isNull);
  });
  testWidgets('只读计划显示完成率和已批准请假，隐藏修改入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          schedulesProvider.overrideWith(
            (ref, id) async => [
              {
                'id': 'template-1',
                'title': '阅读计划',
                'recurrence': 'daily',
                'starts_on': '2026-09-16',
                'ends_on': '2026-09-30',
                'start_time': '16:00',
                'due_time': '20:00',
                'coin_reward': 20,
                'xp_reward': 30,
                'long_plans': {
                  'id': 'plan-1',
                  'minimum_rate': .8,
                  'bonus_coins': 100,
                  'bonus_xp': 100,
                  'settled_at': null,
                  'plan_leaves': [
                    {'leave_date': '2026-09-18'},
                  ],
                  'progress': {'expected': 14, 'completed': 7, 'rate': .5},
                  'plan_stage_rewards': [],
                  'plan_bonus_tiers': [],
                },
              },
            ],
          ),
          remindersProvider.overrideWith((ref, id) async => []),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ScheduleManagementScreen(
            childId: 'child-1',
            familyId: 'family-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('完成率 50.0%'), findsOneWidget);
    expect(find.text('已批准请假：1 天'), findsOneWidget);
    expect(find.text('批准请假'), findsNothing);
    expect(find.text('到期结算'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });
}

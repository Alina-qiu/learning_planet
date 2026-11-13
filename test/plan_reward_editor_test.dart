import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';

class _Harness {
  ScheduleConfig? saved;

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await Navigator.push<ScheduleConfig>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ScheduleEditor(
                      today: DateTime(2026, 11, 5),
                      defaults: const {'title': '阅读计划'},
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
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final scrollable = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    220,
    scrollable: scrollable,
    maxScrolls: 80,
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await reveal(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await reveal(tester, field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> recurrence(WidgetTester tester, String label) async {
  final field = find.byType(DropdownButtonFormField<ScheduleRecurrence>);
  await reveal(tester, field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> stage(
  WidgetTester tester,
  int number,
  String count,
  String coins,
  String xp,
) async {
  await tap(tester, '添加阶段奖励');
  await enter(tester, '阶段 $number 完成次数', count);
  await enter(tester, '阶段 $number 金币', coins);
  await enter(tester, '阶段 $number XP', xp);
}

void main() {
  testWidgets(
    'structured stage and terminal tiers keep the server reward contract',
    (tester) async {
      final h = _Harness();
      await h.open(tester);
      await tap(tester, '设为长期计划');
      await stage(tester, 1, '3', '30', '20');
      await stage(tester, 2, '7', '70', '50');
      await tap(tester, '添加终奖档位');
      await enter(tester, '档位 1 完成率%', '90');
      await enter(tester, '档位 1 金币', '150');
      await enter(tester, '档位 1 XP', '125');
      await tap(tester, '保存配置');
      final json = h.saved!.toJson();
      expect(json['long_plan'], true);
      expect(json['minimum_rate'], .8);
      expect(json['stages'], [
        {'completed_count': 3, 'coins': 30, 'xp': 20},
        {'completed_count': 7, 'coins': 70, 'xp': 50},
      ]);
      expect(json['tiers'], [
        {'minimum_rate': .9, 'coins': 150, 'xp': 125},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removing an earlier stage preserves later values and disposes safely',
    (tester) async {
      final h = _Harness();
      await h.open(tester);
      await tap(tester, '设为长期计划');
      await stage(tester, 1, '3', '30', '20');
      await stage(tester, 2, '7', '70', '50');
      final remove = find.byTooltip('移除阶段 1');
      await reveal(tester, remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await enter(tester, '阶段 1 XP', '55');
      await tap(tester, '保存配置');
      expect(h.saved!.stages, [
        {'completed_count': 7, 'coins': 70, 'xp': 55},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('duplicate or invalid stages cannot be saved', (tester) async {
    final h = _Harness();
    await h.open(tester);
    await tap(tester, '设为长期计划');
    await stage(tester, 1, '0', '-1', '20');
    await tap(tester, '保存配置');
    expect(h.saved, isNull);
    await enter(tester, '阶段 1 完成次数', '3');
    await enter(tester, '阶段 1 金币', '30');
    await stage(tester, 2, '3', '70', '50');
    await tap(tester, '保存配置');
    expect(h.saved, isNull);
    await enter(tester, '阶段 2 完成次数', '7');
    await tap(tester, '保存配置');
    expect(h.saved!.stages.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal thresholds follow the currently edited base rate', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester);
    await tap(tester, '设为长期计划');
    await tap(tester, '添加终奖档位');
    await enter(tester, '档位 1 完成率%', '90');
    await enter(tester, '最低完成率 %', '95');
    await tap(tester, '保存配置');
    expect(h.saved, isNull);
    await enter(tester, '档位 1 完成率%', '101');
    await tap(tester, '保存配置');
    expect(h.saved, isNull);
    await enter(tester, '档位 1 完成率%', '100');
    await tap(tester, '添加终奖档位');
    await enter(tester, '档位 2 完成率%', '100');
    await tap(tester, '保存配置');
    expect(h.saved, isNull);
    final remove = find.byTooltip('移除档位 2');
    await reveal(tester, remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tap(tester, '保存配置');
    expect(h.saved!.tiers.single['minimum_rate'], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning off a plan ignores invalid hidden reward inputs', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester);
    await tap(tester, '设为长期计划');
    await stage(tester, 1, '0', '', '-1');
    await enter(tester, '最低完成率 %', '');
    await enter(tester, '终奖金币', 'abc');
    await enter(tester, '终奖 XP', '-1');
    await tap(tester, '设为长期计划');
    await tap(tester, '保存配置');
    expect(h.saved!.longPlan, false);
    expect(h.saved!.stages, isEmpty);
    expect(h.saved!.tiers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to once ignores hidden dates and all plan rules', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester);
    await recurrence(tester, '自定义日期');
    await enter(tester, '日期（YYYY-MM-DD，逗号分隔）', 'not-a-date');
    await tap(tester, '设为长期计划');
    await stage(tester, 1, '3', '30', '20');
    await recurrence(tester, '一次性');
    await tap(tester, '保存配置');
    expect(h.saved!.recurrence, ScheduleRecurrence.once);
    expect(h.saved!.endsOn, h.saved!.startsOn);
    expect(h.saved!.longPlan, false);
    expect(h.saved!.customDates, isEmpty);
    expect(h.saved!.stages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'returning to an active rule restores its draft and validates it',
    (tester) async {
      final h = _Harness();
      await h.open(tester);
      await tap(tester, '设为长期计划');
      await stage(tester, 1, '3', '30', '20');
      await recurrence(tester, '一次性');
      await recurrence(tester, '每天');
      await tap(tester, '保存配置');
      expect(h.saved!.longPlan, true);
      expect(h.saved!.stages.single['coins'], 30);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reward rows remain operable at 360px and double text size', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester, scale: 2);
    await tap(tester, '设为长期计划');
    await stage(tester, 1, '3', '30', '20');
    await tap(tester, '添加终奖档位');
    await enter(tester, '档位 1 完成率%', '90');
    await tap(tester, '保存配置');
    expect(h.saved!.longPlan, true);
    expect(tester.takeException(), isNull);
  });
}

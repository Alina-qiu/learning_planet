import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/features/tasks/presentation/task_presentation.dart';

import 'support/task_workload.dart';

Future<void> openTasks(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('任务管理'));
  await tester.pumpAndSettle();
}

Future<WorkloadTasks> launch(WidgetTester tester) async {
  final now = DateTime.now();
  // The non-Supabase test repository uses the host calendar, unlike the real
  // offline snapshot's Asia/Shanghai date. Keep this test independent of CI TZ.
  final tasks = WorkloadTasks(taskWorkload(1000, now, dueDate: now));
  await tester.pumpWidget(
    LearningPlanetApp(
      authRepository: WorkloadAuth(),
      familyRepository: WorkloadFamily(),
      taskRepository: tasks,
    ),
  );
  await tester.pumpAndSettle();
  return tasks;
}

void main() {
  testWidgets('home and task list build only visible rows from 1000 tasks', (
    tester,
  ) async {
    await launch(tester);
    expect(find.byType(TaskHeading).evaluate().length, inExclusiveRange(0, 30));
    expect(find.text('本机测试任务 0999'), findsNothing);
    await openTasks(tester);
    expect(find.byType(TaskHeading).evaluate().length, inExclusiveRange(0, 30));
    expect(find.text('本机测试任务 0000'), findsOneWidget);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position;
    for (var i = 0; i < 4; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(find.text('本机测试任务 0999'), findsOneWidget);
    expect(find.byType(TaskHeading).evaluate().length, lessThan(30));
  });

  testWidgets('completion confirms success when the completed row moves away', (
    tester,
  ) async {
    final tasks = await launch(tester);
    await openTasks(tester);
    await tester.tap(find.byTooltip('完成'));
    await tester.pumpAndSettle();
    expect(tasks.completions, 1);
    expect(find.text('任务已完成'), findsOneWidget);
    expect(find.text('本机测试任务 0000'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('任务已完成'), findsNothing);
  });

  testWidgets('a failed completion never shows success', (tester) async {
    final tasks = await launch(tester);
    tasks.failCompletion = true;
    await openTasks(tester);
    await tester.tap(find.byTooltip('完成'));
    await tester.pumpAndSettle();
    expect(tasks.completions, 0);
    expect(find.text('任务已完成'), findsNothing);
    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(find.byTooltip('完成'), findsOneWidget);
  });

  testWidgets('360px and double text size keep home and task controls usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    await tester.scrollUntilVisible(find.text('本机测试任务 0000'), 250);
    expect(tester.takeException(), isNull);
    final heading = find.byType(TaskHeading).first;
    final labels = tester.widgetList<Text>(
      find.descendant(of: heading, matching: find.byType(Text)),
    );
    for (final label in labels.where((text) => text.style?.fontSize != null)) {
      expect(label.style!.fontSize, greaterThanOrEqualTo(14));
    }
    await openTasks(tester);
    expect(find.byTooltip('完成').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

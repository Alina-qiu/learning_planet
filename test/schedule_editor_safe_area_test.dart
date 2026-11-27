import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';

void main() {
  for (final keyboard in [false, true]) {
    testWidgets('schedule save stays above system UI (keyboard: $keyboard)', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
      tester.view.padding = FakeViewPadding(top: 24, bottom: keyboard ? 0 : 48);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard ? 300 : 0);
      addTearDown(tester.view.reset);
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
                          ScheduleEditor(today: DateTime(2026, 11, 5)),
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
      await tester.enterText(
        find.widgetWithText(TextFormField, '任务名称'),
        '学习任务',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      final button = find.widgetWithText(FilledButton, '保存配置');
      final scrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(button, 200, scrollable: scrollable);
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(button);
      expect(bounds.bottom, lessThanOrEqualTo(800 - (keyboard ? 300 : 48)));
      expect(bounds.top, greaterThan(24 + kToolbarHeight));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved?.title, '学习任务');
      expect(tester.takeException(), isNull);
    });
  }
}

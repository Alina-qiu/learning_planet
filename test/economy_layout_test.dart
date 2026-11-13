import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/economy/data/economy_commands.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'economy_test.dart' show FakeEconomy;
import 'economy_commands_test.dart'
    show CommandHarness, UnavailableEconomy, databaseAction;

void main() {
  Future<void> mount(
    WidgetTester tester,
    Size size,
    FakeEconomy repository, {
    CommandHarness? commands,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewPadding = size.width > size.height
        ? const FakeViewPadding(top: 24, left: 48, right: 48, bottom: 24)
        : const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = tester.view.viewPadding;
    addTearDown(tester.view.reset);
    await databaseAction(
      tester,
      () => tester.pumpWidget(
        ProviderScope(
          overrides: [
            economyRepositoryProvider.overrideWithValue(repository),
            taskRepositoryProvider.overrideWithValue(
              const UnconfiguredTaskRepository(),
            ),
            activeParentFamilyProvider.overrideWithValue(null),
            if (commands != null)
              economyCommandsProvider.overrideWithValue(commands.repository),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const EconomyScreen(childId: 'child', familyId: 'family'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      100,
      maxScrolls: 60,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    final rect = tester.getRect(target);
    final size = tester.view.physicalSize;
    final padding = tester.view.viewPadding;
    expect(rect.left, greaterThanOrEqualTo(padding.left));
    expect(rect.right, lessThanOrEqualTo(size.width - padding.right));
    expect(rect.bottom, lessThanOrEqualTo(size.height - padding.bottom));
    expect(tester.takeException(), isNull);
  }

  for (final size in [
    const Size(640, 320),
    const Size(360, 800),
    const Size(1024, 768),
  ]) {
    testWidgets(
      'large-text reward request and records remain usable at $size',
      (tester) async {
        final repository = FakeEconomy();
        await mount(tester, size, repository);
        expect(tester.takeException(), isNull);
        final request = find.widgetWithText(FilledButton, '申请');
        await reveal(tester, request);
        await tester.tap(request);
        await tester.pumpAndSettle();
        final confirm = find.widgetWithText(FilledButton, '确认申请');
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(repository.requests, 1);
        await tester.tap(find.text('兑换记录'));
        await tester.pumpAndSettle();
        await reveal(tester, find.widgetWithText(TextButton, '取消申请'));
        await tester.ensureVisible(find.text('金币与XP账本'));
        await tester.tap(find.text('金币与XP账本'));
        await tester.pumpAndSettle();
        await reveal(tester, find.textContaining('每日软上限'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final unavailable in [false, true]) {
    testWidgets(
      'landscape recovery remains reachable with unavailable catalog: $unavailable',
      (tester) async {
        final commands = CommandHarness();
        addTearDown(commands.store.close);
        await tester.runAsync(commands.prepare);
        await mount(
          tester,
          const Size(640, 320),
          unavailable ? UnavailableEconomy() : FakeEconomy(),
          commands: commands,
        );
        expect(tester.takeException(), isNull);
        expect(commands.remote.calls, isEmpty);
        final stop = find.widgetWithText(TextButton, '停止未执行请求');
        await reveal(tester, stop);
        await tester.tap(stop);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '确认'));
        await databaseAction(tester, () async {});
        expect(commands.remote.calls.single.$2, 'cancel');
        expect(commands.remote.applied, 0);
        await reveal(tester, find.widgetWithText(TextButton, '我已了解'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

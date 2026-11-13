import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/learning_report.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'package:learning_planet/features/reports/presentation/monthly_report_details.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_growth_category.dart';
import 'package:learning_planet/features/tasks/presentation/schedule_management_screen.dart';
import 'learning_report_test.dart' show sample, FakeReports;
import 'offline_tasks_test.dart' show FakeTaskRemote;

String date(DateTime value) => value.toIso8601String().substring(0, 10);
LearningReport monthSample({
  String today = '2026-11-04',
  String? anchor,
  bool empty = false,
}) {
  final day = DateTime.parse('${anchor ?? today}T00:00:00Z');
  final first = DateTime.utc(day.year, day.month);
  final monthEnd = DateTime.utc(day.year, day.month + 1, 0);
  final last = date(monthEnd).compareTo(today) > 0
      ? DateTime.parse('${today}T00:00:00Z')
      : monthEnd;
  return LearningReport({
    ...sample(end: date(last), empty: empty).data,
    'today': today,
    'start_date': date(first),
    'period': 'month',
    'days': [
      for (var n = 1; n <= last.day; n++)
        {
          'day': date(DateTime.utc(day.year, day.month, n)),
          'expected': empty ? 0 : 1,
          'completed': empty ? 0 : 1,
        },
    ],
    'growth': {
      'definition_version': 'activity-v1',
      'series': [
        for (var n = 5; n >= 0; n--)
          if (DateTime.utc(day.year, day.month - n).year >= 2000)
            {
              'start_date': date(DateTime.utc(day.year, day.month - n)),
              'end_date': date(
                n == 0 ? last : DateTime.utc(day.year, day.month - n + 1, 0),
              ),
              'partial': n == 0 && date(last) != date(monthEnd),
              'learning': empty ? 0 : 10 - n,
              'persistence': empty ? 0 : 5,
              'focus_seconds': empty ? 0 : 1200,
              'exploration': empty ? 0 : 3,
              'responsibility': empty ? 0 : 2,
              'unclassified': empty ? 0 : 1,
              'completed': empty ? 0 : 16 - n,
            },
      ],
    },
    'knowledge': {
      'subjects': empty
          ? []
          : [
              {
                'subject': 'math',
                'added': 2,
                'answered': 3,
                'correct': 2,
                'points': [
                  {
                    'knowledge_point': '进位加法',
                    'added': 1,
                    'answered': 3,
                    'correct': 2,
                    'accuracy': .6667,
                  },
                  {
                    'knowledge_point': '',
                    'added': 1,
                    'answered': 0,
                    'correct': 0,
                    'accuracy': null,
                  },
                ],
              },
            ],
    },
  });
}

class MonthReports extends FakeReports {
  String today = '2026-11-04';
  bool empty = false;
  @override
  Future<LearningReport> load(ReportScope scope) async {
    if (scope.period != 'month') return super.load(scope);
    calls.add(scope);
    if (this.fail) throw StateError('network');
    if (pending != null) return pending!.future;
    return monthSample(today: today, anchor: scope.endDate, empty: empty);
  }
}

Future<ProviderContainer> mount(
  WidgetTester tester,
  MonthReports repo, {
  double scale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reportRepositoryProvider.overrideWithValue(repo),
        activeParentFamilyProvider.overrideWith(
          (ref) => ref.watch(parentFamilyIdProvider),
        ),
        parentFamilyIdProvider.overrideWith((ref) => 'family'),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const LearningReportScreen(
          childId: 'child',
          familyId: 'family',
          childNickname: '小星',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(LearningReportScreen)),
  );
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    400,
    scrollable: find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first,
    maxScrolls: 100,
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'calendar month navigation preserves whole months across leap years and year boundaries',
    () {
      final leap = monthSample(anchor: '2024-02-29');
      expect(leap.endDate, '2024-02-29');
      expect(adjacentReportAnchor(leap, 'month', -1), '2024-01-01');
      expect(adjacentReportAnchor(leap, 'month', 1), '2024-03-01');
      expect(
        adjacentReportAnchor(monthSample(anchor: '2024-01-31'), 'month', -1),
        '2023-12-01',
      );
      expect(
        adjacentReportAnchor(monthSample(anchor: '2023-12-01'), 'month', 1),
        '2024-01-01',
      );
      expect(adjacentReportAnchor(sample(), 'week', -1), '2026-10-28');
      expect(adjacentReportAnchor(sample(), 'day', -1), '2026-11-03');
    },
  );
  testWidgets(
    'month navigation requests previous calendar month and returns to server current month',
    (tester) async {
      final repo = MonthReports();
      await mount(tester, repo);
      await tester.tap(find.text('月报'));
      await tester.pumpAndSettle();
      expect(repo.calls.last.period, 'month');
      expect(repo.calls.last.endDate, isNull);
      expect(find.text('2026-11-01 至 2026-11-04'), findsOneWidget);
      await tester.tap(find.text('上个月'));
      await tester.pumpAndSettle();
      expect(repo.calls.last.endDate, '2026-10-01');
      expect(find.text('2026-10-01 至 2026-10-31'), findsOneWidget);
      await tester.tap(find.text('下个月'));
      await tester.pumpAndSettle();
      expect(repo.calls.last.endDate, isNull);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '下个月'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('earliest month prevents an invalid previous-month request', (
    tester,
  ) async {
    final repo = MonthReports()..today = '2000-01-02';
    await mount(tester, repo);
    await tester.tap(find.text('月报'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '上个月'))
          .onPressed,
      isNull,
    );
    expect(repo.calls.last.endDate, isNull);
  });
  testWidgets(
    'knowledge detail expands all labels and leaves empty accuracy as no data',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MonthlyKnowledgeDistribution(report: monthSample()),
            ),
          ),
        ),
      );
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.text('进位加法'), findsOneWidget);
      expect(find.text('未标注知识点'), findsOneWidget);
      expect(find.textContaining('正确率 67%'), findsOneWidget);
      expect(find.textContaining('正确率 暂无数据'), findsOneWidget);
    },
  );
  testWidgets(
    'growth chart and monthly sections stay readable at 360 pixels with large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, MonthReports(), scale: 2);
      await tester.tap(find.text('月报'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('五维成长趋势'));
      expect(tester.takeException(), isNull);
      await reveal(tester, find.text('学习 · 10 项'));
      await tester.tap(find.text('学习 · 10 项'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('2026-11（截至2026-11-04）'));
      expect(tester.takeException(), isNull);
      await reveal(tester, find.text('学科与知识点分布'));
      await reveal(tester, find.text('数学'));
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('未标注知识点'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'empty month has zero recorded activity and no fabricated subject distribution',
    (tester) async {
      final data = monthSample(empty: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  MonthlyGrowthTrends(report: data),
                  MonthlyKnowledgeDistribution(report: data),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('学习 · 0 项'), findsOneWidget);
      expect(find.text('专注 · 0 秒'), findsOneWidget);
      expect(find.textContaining('本月没有可展示'), findsOneWidget);
      expect(find.textContaining('不是能力评分'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('month authorization loss suppresses a delayed response', (
    tester,
  ) async {
    final repo = MonthReports();
    final container = await mount(tester, repo);
    repo.pending = Completer();
    await tester.tap(find.text('月报'));
    await tester.pump();
    container.read(parentFamilyIdProvider.notifier).state = null;
    await tester.pump();
    repo.pending!.complete(monthSample());
    await tester.pumpAndSettle();
    expect(find.textContaining('家长授权已到期'), findsOneWidget);
    expect(find.text('五维成长趋势'), findsNothing);
  });
  testWidgets(
    'parent chooses a growth category in schedule editor while rewards remain unchanged',
    (tester) async {
      ScheduleConfig? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  saved = await Navigator.push<ScheduleConfig>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ScheduleEditor(
                        today: DateTime(2026, 11, 4),
                        defaults: const {
                          'title': '整理书包',
                          'growth_category': 'learning',
                        },
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
      final dropdown = find.byType(DropdownButtonFormField<TaskGrowthCategory>);
      await reveal(tester, dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('责任').last);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('保存配置'));
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      expect(saved!.growthCategory, TaskGrowthCategory.responsibility);
      expect(saved!.toJson()['growth_category'], 'responsibility');
      expect(saved!.coins, 20);
      expect(saved!.xp, 20);
    },
  );
  test(
    'growth classification survives actual Drift cache, offline transition and repository restart',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final now = DateTime.utc(2026, 9, 16, 8);
      final remote = FakeTaskRemote(() => now)..seed('child');
      remote.tasks['task-child']!['growth_category'] = 'exploration';
      OfflineTaskRepository repository() => OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'owner',
        clock: () => now,
        autoSync: false,
      )..setForeground(false);
      var repo = repository();
      try {
        expect(
          (await repo.loadTasks('child')).single.growthCategory,
          TaskGrowthCategory.exploration,
        );
        remote.online = false;
        await repo.start('task-child');
        await repo.dispose();
        repo = repository();
        final restored = (await repo.loadTasks('child')).single;
        expect(restored.growthCategory, TaskGrowthCategory.exploration);
        expect(restored.status, TaskStatus.inProgress);
        expect(restored.coinReward, 10);
      } finally {
        await repo.dispose();
        await store.close();
      }
    },
  );
}

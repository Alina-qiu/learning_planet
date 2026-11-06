import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/learning_report.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';

LearningReport sample({String end = '2026-11-04', bool empty = false}) =>
    LearningReport({
      'start_date': end,
      'end_date': end,
      'today': '2026-11-04',
      'timezone': 'Asia/Shanghai',
      'tasks': {
        'expected': empty ? 0 : 2,
        'completed': empty ? 0 : 1,
        'effective_seconds': 720,
        'completion_rate': empty ? null : 0.5,
      },
      'reviews': {'answered': 0, 'correct': 0, 'accuracy': null},
      'coins': {'income': 25, 'spent': 0, 'adjustment_out': 0, 'xp': 20},
      'days': [
        {'day': end, 'expected': empty ? 0 : 2, 'completed': empty ? 0 : 1},
      ],
      'activities': <Map<String, dynamic>>[],
      'activity_count': 0,
      'due_now': 0,
    });

class FakeReports implements ReportRepository {
  final calls = <ReportScope>[];
  bool fail = false;
  Completer<LearningReport>? pending;
  @override
  Future<LearningReport> load(ReportScope scope) async {
    calls.add(scope);
    if (fail) throw StateError('network');
    if (pending != null) return pending!.future;
    return sample(end: scope.endDate ?? '2026-11-04');
  }
}

void main() {
  test(
    'empty report uses no-data rates and an actionable evidence-based suggestion',
    () {
      expect(reportPercent(null), '暂无数据');
      expect(reportPercent(0), '0%');
      expect(reportDuration(65), '1 分 5 秒');
      expect(sample(empty: true).suggestion.basis, contains('没有已生成'));
      expect(sample().suggestion.basis, contains('2 项任务'));
      final due = sample().data..['due_now'] = 3;
      expect(LearningReport(due).suggestion.basis, contains('3 道'));
    },
  );

  Future<ProviderContainer> mount(
    WidgetTester tester,
    FakeReports repository, {
    bool parent = true,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reportRepositoryProvider.overrideWithValue(repository),
          parentModeProvider.overrideWith((ref) => parent),
          parentFamilyIdProvider.overrideWith((ref) => 'family'),
          parentAuthorizedUntilProvider.overrideWith(
            (ref) => DateTime.now().add(const Duration(hours: 1)),
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
          home: const LearningReportScreen(
            childId: 'child',
            familyId: 'family',
            childNickname: '小星',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return ProviderScope.containerOf(
      tester.element(find.byType(LearningReportScreen)),
    );
  }

  testWidgets('child mode does not load reports', (tester) async {
    final repository = FakeReports();
    await mount(tester, repository, parent: false);
    expect(repository.calls, isEmpty);
    expect(find.textContaining('重新验证 PIN'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'day/week navigation uses server date and supports historical periods',
    (tester) async {
      final repository = FakeReports();
      await mount(tester, repository);
      expect(find.textContaining('完成 1 / 2 项'), findsOneWidget);
      expect(repository.calls.single.endDate, isNull);
      await tester.tap(find.text('前一天'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.endDate, '2026-11-03');
      await tester.tap(find.text('周报 · 近7天'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.period, 'week');
      expect(repository.calls.last.endDate, isNull);
      await tester.tap(find.text('前7天'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.endDate, '2026-10-28');
      await tester.tap(find.text('回到今天'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.endDate, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'authorization loss hides data and a late response cannot restore it',
    (tester) async {
      final repository = FakeReports()..pending = Completer();
      final container = await mount(tester, repository);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pump();
      repository.pending!.complete(sample());
      await tester.pumpAndSettle();
      expect(find.textContaining('重新验证 PIN'), findsOneWidget);
      expect(find.textContaining('完成 1 / 2 项'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('network error can retry without showing fabricated totals', (
    tester,
  ) async {
    final repository = FakeReports()..fail = true;
    await mount(tester, repository);
    expect(find.textContaining('报告读取失败'), findsOneWidget);
    expect(find.textContaining('完成 1 / 2 项'), findsNothing);
    repository.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('完成 1 / 2 项'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('small screen and large text keep report sections readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, FakeReports(), scale: 2);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('可以试试'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

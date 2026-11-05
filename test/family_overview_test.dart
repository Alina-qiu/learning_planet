import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/economy/presentation/economy_screen.dart';
import 'package:learning_planet/features/reports/data/family_overview_repository.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/family_overview.dart';
import 'package:learning_planet/features/reports/presentation/family_overview_screen.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'support/mock_supabase.dart';
import 'widget_test.dart' as fixture;
import 'economy_test.dart' show FakeEconomy;
import 'learning_report_test.dart' show FakeReports;

Map<String, dynamic> overviewData({bool empty = false}) => {
  'family_id': 'family',
  'family_name': '星星家',
  'timezone': 'Asia/Shanghai',
  'today': '2026-11-05',
  'generated_at': '2026-11-05T03:04:05Z',
  'children': [
    if (!empty)
      for (final pair in [('child', '小星'), ('sibling', '小月')])
        {
          'child_id': pair.$1,
          'nickname': pair.$2,
          'days': [
            for (var i = 0; i < 7; i++)
              {
                'day': DateTime.utc(
                  2026,
                  10,
                  30 + i,
                ).toIso8601String().substring(0, 10),
                'expected': i == 6 ? (pair.$1 == 'child' ? 2 : 10) : 0,
                'completed': i == 6 ? (pair.$1 == 'child' ? 1 : 8) : 0,
              },
          ],
          'requested': pair.$1 == 'child' ? 1 : 2,
          'approved': 1,
          'awaiting_expiry': 1,
          'pending_awards': 2,
          'pending_coins': 50,
        },
  ],
};

class FakeOverview implements FamilyOverviewRepository {
  int calls = 0;
  bool fail = false, empty = false;
  Completer<FamilyOverview>? pending;
  @override
  Future<FamilyOverview> load(String familyId) async {
    calls++;
    if (fail) throw StateError('Private backend detail');
    if (pending != null) return pending!.future;
    return FamilyOverview.fromJson(overviewData(empty: empty), familyId);
  }
}

Future<ProviderContainer> mountOverview(
  WidgetTester tester,
  FakeOverview repo, {
  bool parent = true,
  double scale = 1,
  fixture.SwitchingAuthRepository? auth,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        familyOverviewRepositoryProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(
          auth ??
              fixture.FakeAuthRepository(const AuthSession(userId: 'owner')),
        ),
        activeParentFamilyProvider.overrideWith(
          (ref) => ref.watch(parentFamilyIdProvider),
        ),
        parentFamilyIdProvider.overrideWith((ref) => parent ? 'family' : null),
        taskRepositoryProvider.overrideWithValue(
          const UnconfiguredTaskRepository(),
        ),
        economyRepositoryProvider.overrideWithValue(FakeEconomy()),
        reportRepositoryProvider.overrideWithValue(FakeReports()),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const FamilyOverviewScreen(familyId: 'family'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return ProviderScope.containerOf(
    tester.element(find.byType(FamilyOverviewScreen)),
  );
}

Future<void> tapOverview(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'overview aggregates counts rather than averaging child rates and preserves empty dates',
    () {
      final report = FamilyOverview.fromJson(overviewData(), 'family');
      final trend = report.trend(report.children);
      expect(trend.last.rate, .75);
      expect(trend.first.rate, isNull);
      expect(report.children.first.weekCompleted, 1);
      expect(report.children.first.weekExpected, 2);
      expect(report.trend([report.children.last]).last.rate, .8);
      expect(report.trend([]).every((day) => day.rate == null), isTrue);
      expect(() => report.children.clear(), throwsUnsupportedError);
      expect(() => report.children.first.days.clear(), throwsUnsupportedError);
      expect(report.generatedAt.isUtc, isTrue);
    },
  );
  test(
    'overview rejects mixed family, duplicate child, invalid counts and incomplete dates',
    () {
      expect(
        () => FamilyOverview.fromJson(overviewData(), 'foreign'),
        throwsFormatException,
      );
      for (final change in <void Function(Map<String, dynamic>)>[
        (data) =>
            (data['children'] as List).add((data['children'] as List).first),
        (data) => data['children'][0]['requested'] = -1,
        (data) => data['children'][0]['days'][6]['completed'] = 3,
        (data) => data['children'][0]['days'][0]['day'] = '2026-10-29',
        (data) => data['children'][0]['days'].removeLast(),
        (data) => data['children'][0]['pending_coins'] = 1.5,
      ]) {
        final data = overviewData();
        change(data);
        expect(
          () => FamilyOverview.fromJson(data, 'family'),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'real SDK overview requests only a family aggregate and rejects changed account or scope',
    () async {
      final backend = MockSupabase();
      addTearDown(backend.close);
      final repo = SupabaseFamilyOverviewRepository(backend.client);
      await expectLater(repo.load('family'), throwsStateError);
      await backend.signIn();
      backend.handle = (r) => MockSupabase.json(r, overviewData());
      expect((await repo.load('family')).children.length, 2);
      expect(backend.calls.single.url.path, '/rest/v1/rpc/family_overview');
      expect(MockSupabase.body(backend.calls.single), {
        'target_family_id': 'family',
      });
      await expectLater(repo.load('foreign'), throwsFormatException);
      final entered = Completer<void>(), release = Completer<http.Response>();
      backend.handle = (r) {
        entered.complete();
        return release.future;
      };
      final pending = repo.load('family');
      final result = expectLater(pending, throwsStateError);
      await entered.future;
      await backend.signIn(MockSupabase.secondUser);
      release.complete(MockSupabase.json(backend.calls.last, overviewData()));
      await result;
    },
  );
  testWidgets('child mode never requests family statistics', (tester) async {
    final repo = FakeOverview();
    await mountOverview(tester, repo, parent: false);
    expect(repo.calls, 0);
    expect(find.textContaining('重新验证 PIN'), findsOneWidget);
    expect(find.text('小星'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'family filter changes aggregate trend without changing the global selected child',
    (tester) async {
      final repo = FakeOverview();
      final container = await mountOverview(tester, repo);
      expect(find.text('今日完成 9/12 项'), findsOneWidget);
      expect(find.textContaining('待审批 3 · 待履约 2'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '小月'));
      await tester.pumpAndSettle();
      expect(find.text('今日完成 8/10 项'), findsOneWidget);
      expect(container.read(selectedChildIdProvider), isNull);
      expect(repo.calls, 1);
      await tapOverview(tester, find.text('待审批 2'));
      final economy = tester.widget<EconomyScreen>(find.byType(EconomyScreen));
      expect(
        (economy.childId, economy.familyId, economy.initialTab),
        ('sibling', 'family', 1),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(repo.calls, 2);
      await tapOverview(tester, find.text('查看周报'));
      final report = tester.widget<LearningReportScreen>(
        find.byType(LearningReportScreen),
      );
      expect(
        (report.childId, report.familyId, report.initialPeriod),
        ('sibling', 'family', 'week'),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('PIN loss and renewal discard old statistics and late replies', (
    tester,
  ) async {
    final old = Completer<FamilyOverview>();
    final repo = FakeOverview()..pending = old;
    final container = await mountOverview(tester, repo);
    container.read(parentFamilyIdProvider.notifier).state = null;
    await tester.pump();
    old.complete(FamilyOverview.fromJson(overviewData(), 'family'));
    await tester.pumpAndSettle();
    expect(find.text('星星家'), findsNothing);
    expect(find.textContaining('重新验证 PIN'), findsOneWidget);
    repo.pending = null;
    repo.empty = true;
    container.read(parentFamilyIdProvider.notifier).state = 'family';
    await tester.pumpAndSettle();
    expect(find.textContaining('家庭中暂无孩子'), findsOneWidget);
    expect(find.text('小星'), findsNothing);
    container.read(parentAuthorizationRevisionProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(repo.calls, 3);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'account change replaces data while loading and signing out hides the overview immediately',
    (tester) async {
      final auth = fixture.SwitchingAuthRepository();
      addTearDown(auth.changes.close);
      final repo = FakeOverview();
      final container = await mountOverview(tester, repo, auth: auth);
      expect(find.text('星星家'), findsOneWidget);
      final late = Completer<FamilyOverview>();
      repo.pending = late;
      auth.changes.add(const AuthSession(userId: 'other'));
      await tester.pump();
      await tester.pump();
      expect(find.text('星星家'), findsNothing);
      container.read(signingOutProvider.notifier).state = true;
      await tester.pump();
      late.complete(FamilyOverview.fromJson(overviewData(), 'family'));
      await tester.pumpAndSettle();
      expect(find.text('星星家'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failure displays no fabricated totals or private errors and supports retry and empty family',
    (tester) async {
      final repo = FakeOverview()..fail = true;
      await mountOverview(tester, repo);
      expect(find.textContaining('暂时无法读取'), findsOneWidget);
      expect(find.textContaining('Private backend'), findsNothing);
      expect(find.textContaining('今日完成'), findsNothing);
      repo.fail = false;
      repo.empty = true;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('家庭中暂无孩子'), findsOneWidget);
      expect(find.text('近七日完成趋势'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    '360px double text keeps pending actions and trend semantics usable',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await mountOverview(tester, FakeOverview(), scale: 2);
        await tester.tap(find.widgetWithText(ChoiceChip, '小星'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(LinearProgressIndicator),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp('2026-11-05已完成1项，共2项任务')),
          findsOneWidget,
        );
        await tapOverview(tester, find.text('确认超额金币'));
        final screen = tester.widget<EconomyScreen>(find.byType(EconomyScreen));
        expect((screen.childId, screen.initialTab), ('child', 2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets(
    'production home exposes the overview only after family PIN and routes to that family',
    (tester) async {
      await tester.pumpWidget(
        LearningPlanetApp(
          authRepository: fixture.FakeAuthRepository(
            const AuthSession(userId: 'parent-1'),
          ),
          familyRepository: fixture.FakeFamilyRepository.withChild(),
          taskRepository: fixture.FakeTaskRepository(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('家庭概览与待处理事项'), findsNothing);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入家长模式'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('验证'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('家庭概览与待处理事项'), 200);
      await tester.tap(find.text('家庭概览与待处理事项'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FamilyOverviewScreen>(find.byType(FamilyOverviewScreen))
            .familyId,
        'family-1',
      );
      expect(find.textContaining('暂时无法读取家庭概览'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

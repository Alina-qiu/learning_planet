import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/business_metrics.dart';
import 'package:learning_planet/features/reports/domain/learning_report.dart';
import 'package:learning_planet/features/reports/presentation/business_metrics_details.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'learning_report_test.dart' show sample;
import 'support/mock_supabase.dart';

Map<String, dynamic> metrics({bool empty = false}) => {
  'version': 'business-v1',
  'fulfillment': <String, dynamic>{
    'samples': empty ? 0 : 2,
    'median_seconds': empty ? null : 82800,
    'open_requests': 2,
  },
  'ocr': <String, dynamic>{
    'ocr_fields': empty ? 0 : 3,
    'corrected_fields': empty ? 0 : 2,
    'correction_rate': empty ? null : 0.6667,
    'manual_records': 1,
    'unmeasured_saved_records': 4,
  },
  'coin_income_to_spent': empty ? null : 5,
};
Map<String, dynamic> report({
  bool empty = false,
  bool legacy = false,
  String child = 'child',
  String period = 'day',
}) => {
  ...sample().data,
  'child_id': child,
  'period': period,
  if (!legacy) 'business_metrics': metrics(empty: empty),
};
const scope = (
  childId: 'child',
  familyId: 'family',
  period: 'day',
  endDate: '2026-11-04',
);

class MetricsReports implements ReportRepository {
  bool empty = false, fail = false, legacy = false;
  int calls = 0;
  @override
  Future<LearningReport> load(ReportScope scope) async {
    calls++;
    if (fail) throw StateError('unavailable');
    return LearningReport(
      report(
        empty: empty,
        legacy: legacy,
        child: scope.childId,
        period: scope.period,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'no samples stay null while a measured zero remains zero, including long fulfillment durations',
    () {
      final value = BusinessMetrics.fromJson(metrics());
      expect(value.fulfilled, 2);
      expect(value.medianSeconds, 82800);
      expect(value.correctionRate, .6667);
      expect(value.coinRatio, 5);
      final empty = BusinessMetrics.fromJson(metrics(empty: true));
      expect(empty.medianSeconds, isNull);
      expect(empty.correctionRate, isNull);
      expect(empty.coinRatio, isNull);
      final zero = metrics()..['coin_income_to_spent'] = 0;
      zero['ocr'] = {
        'ocr_fields': 1,
        'corrected_fields': 0,
        'correction_rate': 0,
        'manual_records': 0,
        'unmeasured_saved_records': 0,
      };
      expect(BusinessMetrics.fromJson(zero).correctionRate, 0);
      expect(BusinessMetrics.fromJson(zero).coinRatio, 0);
      expect(fulfillmentDuration(null), '暂无已履约样本');
      expect(fulfillmentDuration(0), '0 秒');
      expect(fulfillmentDuration(59.6), '1 分 0 秒');
      expect(fulfillmentDuration(3660), '1 小时 1 分');
      expect(fulfillmentDuration(176400), '2 天 1 小时');
      expect(LearningReport(report(legacy: true)).businessMetrics, isNull);
    },
  );
  test(
    'invalid counts, inconsistent rates, unsupported definitions and nonfinite metrics cannot look like valid totals',
    () {
      final cases = <Map<String, dynamic>>[];
      for (final invalid in [-1, 1.5, '2', null, double.infinity]) {
        final row = metrics();
        row['fulfillment']['samples'] = invalid;
        cases.add(row);
      }
      for (final invalid in [-1, '2', double.nan, double.infinity]) {
        final row = metrics();
        row['coin_income_to_spent'] = invalid;
        cases.add(row);
      }
      var row = metrics();
      row['version'] = 'business-v9';
      cases.add(row);
      row = metrics();
      row['fulfillment']['median_seconds'] = null;
      cases.add(row);
      row = metrics(empty: true);
      row['fulfillment']['median_seconds'] = 0;
      cases.add(row);
      row = metrics();
      row['ocr']['corrected_fields'] = 4;
      cases.add(row);
      row = metrics();
      row['ocr']['correction_rate'] = 0.5;
      cases.add(row);
      row = metrics();
      row['ocr']['correction_rate'] = null;
      cases.add(row);
      for (final invalid in cases) {
        expect(() => BusinessMetrics.fromJson(invalid), throwsFormatException);
      }
    },
  );
  group('Supabase report transport', () {
    late MockSupabase backend;
    late SupabaseReportRepository repository;
    setUp(() async {
      backend = MockSupabase();
      await backend.signIn();
      repository = SupabaseReportRepository(backend.client);
    });
    tearDown(() async {
      await backend.close();
    });
    test(
      'fetches actual child and period once and accepts aggregate metrics or a legacy report',
      () async {
        backend.handle = (request) {
          expect(request.url.path, '/rest/v1/rpc/learning_report');
          expect(MockSupabase.body(request), {
            'target_child_id': 'child',
            'report_period': 'day',
            'anchor_date': '2026-11-04',
          });
          return MockSupabase.json(request, report());
        };
        expect((await repository.load(scope)).businessMetrics!.coinRatio, 5);
        expect(backend.calls, hasLength(1));
        backend.handle = (request) =>
            MockSupabase.json(request, report(legacy: true));
        expect((await repository.load(scope)).businessMetrics, isNull);
      },
    );
    test(
      'wrong child or period, malformed aggregates and server denial are rejected instead of displayed',
      () async {
        for (final response in [
          report(child: 'other'),
          report(period: 'week'),
          {
            ...report(),
            'business_metrics': {'version': 'invalid'},
          },
        ]) {
          backend.handle = (request) => MockSupabase.json(request, response);
          await expectLater(repository.load(scope), throwsA(anything));
        }
        backend.handle = MockSupabase.denied;
        await expectLater(repository.load(scope), throwsA(anything));
        await backend.client.auth.signOut();
        final count = backend.calls.length;
        await expectLater(repository.load(scope), throwsStateError);
        expect(backend.calls.length, count);
      },
    );
    test('account switch fences a late metrics response', () async {
      final started = Completer<void>(), gate = Completer<void>();
      backend.handle = (request) async {
        started.complete();
        await gate.future;
        return MockSupabase.json(request, report());
      };
      final pending = repository.load(scope);
      await started.future;
      await backend.signIn(MockSupabase.secondUser);
      gate.complete();
      await expectLater(pending, throwsStateError);
    });
  });

  Future<ProviderContainer> mount(
    WidgetTester tester,
    MetricsReports repository, {
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
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(LearningReportScreen)),
    );
  }

  Future<void> reveal(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.textContaining(text),
      300,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 60,
    );
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'business section is readable at 360px and doubled text with explicit cohort definitions',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, MetricsReports(), scale: 2);
      await reveal(tester, '奖励承诺与录入质量');
      await reveal(tester, '申请到履约中位时长：23 小时 0 分');
      await reveal(tester, '金币产消比：5.00 : 1');
      await reveal(tester, 'OCR 校正率：67%');
      await reveal(tester, '缺少首次确认统计');
      expect(find.textContaining('修改 2 / 3 个识别字段'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'empty period explains absent denominators without showing infinite ratios or false zero quality',
    (tester) async {
      await mount(tester, MetricsReports()..empty = true);
      await reveal(tester, '奖励承诺与录入质量');
      expect(find.textContaining('暂无已履约样本'), findsOneWidget);
      expect(find.text('金币产消比：暂无履约消耗'), findsOneWidget);
      expect(find.text('OCR 校正率：暂无数据'), findsOneWidget);
      expect(find.textContaining('缺少首次确认统计'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'parent authorization loss hides all metrics and child mode makes no report request',
    (tester) async {
      final repository = MetricsReports();
      var container = await mount(tester, repository);
      await reveal(tester, '奖励承诺与录入质量');
      container.read(parentModeProvider.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.byType(BusinessMetricsDetails), findsNothing);
      expect(find.textContaining('重新验证 PIN'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final other = MetricsReports();
      container = await mount(tester, other, parent: false);
      expect(other.calls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'refresh failure clears old metrics and retry restores only a successful response',
    (tester) async {
      final repository = MetricsReports();
      final container = await mount(tester, repository);
      await reveal(tester, '奖励承诺与录入质量');
      repository.fail = true;
      container.invalidate(
        learningReportProvider((
          childId: 'child',
          familyId: 'family',
          period: 'day',
          endDate: null,
        )),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BusinessMetricsDetails), findsNothing);
      expect(find.textContaining('报告读取失败'), findsOneWidget);
      repository.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      await reveal(tester, '奖励承诺与录入质量');
      expect(find.byType(BusinessMetricsDetails), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/ai/data/ai_repository.dart';
import 'package:learning_planet/features/ai/presentation/ai_analysis_screen.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/reports/data/ai_weekly_report_repository.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/presentation/ai_weekly_report_screen.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'ai_analysis_test.dart' show FakeAi;
import 'learning_report_test.dart' show FakeReports;

Map<String, dynamic> weeklyInput() => {
  'kind': 'weekly_report',
  'end_date': '2026-03-08',
  'snapshot': {
    'schema_version': 'weekly-facts-v1',
    'start_date': '2026-03-02',
    'end_date': '2026-03-08',
    'as_of_date': '2026-11-04',
    'tasks': {'expected': 2, 'completed': 1, 'effective_seconds': 720},
    'reviews': {'answered': 1, 'correct': 1},
    'due_now': 1,
    'coins': {'income': 5, 'spent': 0, 'adjustment_out': 0},
    'activity_count': 2,
    'days': [
      for (var i = 0; i < 7; i++)
        {
          'day': '2026-03-0${i + 2}',
          'expected': i < 2 ? 1 : 0,
          'completed': i == 0 ? 1 : 0,
          'effective_seconds': i == 0
              ? 600
              : i == 1
              ? 120
              : 0,
        },
    ],
  },
};
Map<String, dynamic> weeklyResult({List<String> flags = const []}) => {
  'model_version': 'test-model',
  'prompt_version': 'weekly-report-v1',
  'confidence': .72,
  'raw_output': 'raw',
  'safety_flags': flags,
  'evidence': weeklyInput(),
  'structured_output': flags.isNotEmpty
      ? {}
      : {
          'summaries': [
            {
              'text': '本周到期的2项任务中已完成1项。',
              'evidence_ids': ['tasks'],
            },
          ],
          'recommendation': {
            'text': '和孩子一起安排一小段复习。',
            'evidence_ids': ['reviews', 'due_now'],
          },
        },
};

class WeeklyAi extends FakeAi {
  @override
  Future<Map<String, dynamic>> resolve(
    String childId,
    String id,
    String operation,
  ) async {
    try {
      final receipt = await super.resolve(childId, id, operation);
      return {
        ...receipt,
        'result': operation == 'submit' ? weeklyResult() : result,
      };
    } finally {
      if (operation == 'submit') result = weeklyResult();
    }
  }
}

class WeeklyReports implements AiWeeklyReportRepository {
  Map<String, dynamic> input = weeklyInput();
  String familyId = 'family';
  final List<String> feedbacks = [];
  bool loseFeedback = false;
  @override
  Future<Map<String, dynamic>> context(String child, String date) async => {
    'family_id': familyId,
    'child_id': child,
    'input': input,
  };
  @override
  Future<void> feedback(String child, String request, String item) async {
    feedbacks.add(item);
    if (loseFeedback) {
      loseFeedback = false;
      throw StateError('lost feedback reply');
    }
  }
}

final weeklyAuthorization = StateProvider<String?>((ref) => 'family');
const weeklyScreen = AiWeeklyReportScreen(
  familyId: 'family',
  childId: 'child',
  endDate: '2026-03-08',
);
void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    WeeklyAi ai,
    WeeklyReports reports, {
    Widget home = weeklyScreen,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiRepositoryProvider.overrideWithValue(ai),
          aiWeeklyReportRepositoryProvider.overrideWithValue(reports),
          reportRepositoryProvider.overrideWithValue(FakeReports()),
          activeParentFamilyProvider.overrideWith(
            (ref) => ref.watch(weeklyAuthorization),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(home.runtimeType)),
    );
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scroll = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(target, 220, scrollable: scroll);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await reveal(tester, find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> ready(WeeklyAi ai) async {
    await ai.prepare('family', 'child', weeklyInput());
    ai.status = 'completed';
    ai.result = weeklyResult();
  }

  testWidgets(
    'weekly generation requires consent and a lost reply resolves without another model call',
    (tester) async {
      final ai = WeeklyAi()..loseReply = true, reports = WeeklyReports();
      await mount(tester, ai, reports);
      expect(ai.submits, 0);
      await reveal(tester, find.text('生成本次 AI 周报'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '生成本次 AI 周报'),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, '同意发送以上汇总数据，生成本次周报');
      await tap(tester, '生成本次 AI 周报');
      expect(ai.submits, 1);
      await tap(tester, '核对原请求');
      expect(ai.submits, 1);
      await reveal(tester, find.byKey(const ValueKey('evidence:summary:0')));
      expect(find.textContaining('低置信度建议'), findsOneWidget);
      // A refreshed local report cannot change the evidence of a frozen AI result.
      reports.input['snapshot']['tasks']['effective_seconds'] = 9999;
      await tester.tap(find.byKey(const ValueKey('evidence:summary:0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已保存计时 12 分 0 秒'), findsOneWidget);
      expect(find.textContaining('9999'), findsNothing);
      expect(ai.submits, 1);
    },
  );
  testWidgets(
    'each conclusion has explicit feedback and a lost feedback receipt never regenerates the report',
    (tester) async {
      final ai = WeeklyAi();
      await ready(ai);
      final reports = WeeklyReports()..loseFeedback = true;
      await mount(tester, ai, reports);
      final button = find.byKey(const ValueKey('feedback:recommendation'));
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(reports.feedbacks, ['recommendation']);
      expect(ai.submits, 0);
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('已记录反馈'), findsOneWidget);
      expect(reports.feedbacks, ['recommendation', 'recommendation']);
      expect(ai.submits, 0);
    },
  );
  testWidgets(
    'PIN expiration hides the nested evidence view and the weekly interpretation',
    (tester) async {
      final ai = WeeklyAi();
      await ready(ai);
      final container = await mount(tester, ai, WeeklyReports());
      final button = find.byKey(const ValueKey('evidence:recommendation'));
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.textContaining('到期未掌握题 1 道'), findsOneWidget);
      container.read(weeklyAuthorization.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.textContaining('到期未掌握题 1 道'), findsNothing);
      expect(find.text('家长授权已到期，请返回后重新验证'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('和孩子一起安排一小段复习。'), findsNothing);
    },
  );
  testWidgets(
    'an invalidated result cannot open evidence or submit feedback; refusal hides normal conclusions',
    (tester) async {
      final ai = WeeklyAi();
      await ready(ai);
      final reports = WeeklyReports();
      await mount(tester, ai, reports);
      ai.status = 'discarded';
      ai.result = null;
      final button = find.byKey(const ValueKey('feedback:recommendation'));
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(reports.feedbacks, isEmpty);
      expect(find.text('和孩子一起安排一小段复习。'), findsNothing);
      ai.status = 'completed';
      ai.result = weeklyResult(flags: ['refused']);
      await tap(tester, '核对原请求');
      expect(find.textContaining('本次结果被安全检查拦截'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('feedback:recommendation')),
        findsNothing,
      );
    },
  );
  testWidgets(
    'classification and weekly requests cannot be submitted through each other entry points',
    (tester) async {
      final ai = WeeklyAi();
      await ready(ai);
      await mount(
        tester,
        ai,
        WeeklyReports(),
        home: const AiAnalysisScreen(
          familyId: 'family',
          childId: 'child',
          input: {'subject': 'math', 'text': '2+3'},
        ),
      );
      expect(find.text('当前为学习周报请求，请返回周报查看。'), findsOneWidget);
      expect(find.textContaining('候选错因'), findsNothing);
      expect(tester.takeException(), isNull);
      ai.draft = {
        'request_id': 'other',
        'generation': 0,
        'input': {'subject': 'math', 'text': '2+3'},
      };
      ai.status = 'unknown';
      ai.result = null;
      await mount(tester, ai, WeeklyReports());
      expect(find.textContaining('当前孩子有另一项 AI 请求'), findsOneWidget);
      expect(find.text('生成本次 AI 周报'), findsNothing);
      expect(ai.submits, 0);
    },
  );
  testWidgets(
    'ending a request is explicit and failure retains it; narrow enlarged text remains usable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ai = WeeklyAi();
      await ready(ai);
      ai.failEnd = true;
      await mount(tester, ai, WeeklyReports(), scale: 2);
      await tap(tester, '结束或重新生成');
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(ai.draft, isNotNull);
      await tap(tester, '结束或重新生成');
      await tester.tap(find.text('确认结束'));
      await tester.pumpAndSettle();
      expect(ai.draft, isNotNull);
      ai.failEnd = false;
      await tap(tester, '结束或重新生成');
      await tester.tap(find.text('确认结束'));
      await tester.pumpAndSettle();
      expect(ai.draft, isNull);
      await reveal(tester, find.text('生成本次 AI 周报'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '生成本次 AI 周报'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      expect(ai.submits, 0);
    },
  );
  testWidgets(
    'the weekly report entry passes the selected report end date without sending automatically',
    (tester) async {
      final ai = WeeklyAi();
      await mount(
        tester,
        ai,
        WeeklyReports(),
        home: const LearningReportScreen(
          childId: 'child',
          familyId: 'family',
          childNickname: '孩子',
        ),
      );
      expect(find.text('AI 解读这份周报（家长参考）'), findsNothing);
      await tester.tap(find.text('周报 · 近7天'));
      await tester.pumpAndSettle();
      await tap(tester, 'AI 解读这份周报（家长参考）');
      expect(
        tester
            .widget<AiWeeklyReportScreen>(find.byType(AiWeeklyReportScreen))
            .endDate,
        '2026-11-04',
      );
      expect(ai.submits, 0);
    },
  );
  testWidgets(
    'a mismatched family cannot restore a local report before source scope is checked',
    (tester) async {
      final ai = WeeklyAi();
      await ready(ai);
      await mount(tester, ai, WeeklyReports()..familyId = 'other-family');
      expect(ai.operations, isEmpty);
      expect(find.text('和孩子一起安排一小段复习。'), findsNothing);
      expect(find.text('查看本次发送的汇总数据'), findsNothing);
      expect(ai.submits, 0);
    },
  );
  group('real weekly repository and durable request transport', () {
    late OfflineStore store;
    late SupabaseClient client;
    late SupabaseAiRepository ai;
    late SupabaseAiWeeklyReportRepository reports;
    const uid = '10000000-0000-0000-0000-000000000001';
    Completer<void>? entered, hold;
    bool mismatch = false;
    final calls = <Map<String, dynamic>>[];
    setUp(() async {
      store = OfflineStore(NativeDatabase.memory());
      entered = null;
      hold = null;
      mismatch = false;
      calls.clear();
      client = SupabaseClient(
        'https://project.supabase.co',
        'public',
        httpClient: MockClient((request) async {
          http.Response reply(Object? value) => http.Response(
            jsonEncode(value),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
          if (request.url.path.endsWith('/token')) {
            return reply({
              'access_token':
                  'header.${base64UrlEncode(utf8.encode(jsonEncode({'sub': uid, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})))}.signature',
              'refresh_token': 'mock',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': uid,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': 'parent@example.test',
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-11-04T00:00:00Z',
              },
            });
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          calls.add(body);
          if (entered != null && !entered!.isCompleted) entered!.complete();
          await hold?.future;
          if (request.url.path.endsWith('/weekly_report_ai_context')) {
            return reply({
              'child_id': mismatch ? 'wrong' : body['target_child_id'],
              'family_id': 'family',
              'input': weeklyInput(),
            });
          }
          if (request.url.path.endsWith('/feedback_ai_report')) {
            return reply({
              'request_id': mismatch ? 'wrong' : body['request_id'],
              'item_key': body['item_key'],
            });
          }
          return reply({
            'request_id': body['request_id'],
            'child_id': body['target_child_id'],
            'status': 'completed',
            'result': weeklyResult(),
          });
        }),
      );
      await client.auth.signInWithPassword(
        email: 'parent@example.test',
        password: 'mock',
      );
      ai = SupabaseAiRepository(client, store);
      reports = SupabaseAiWeeklyReportRepository(client, store);
    });
    tearDown(() async {
      await client.dispose();
      await store.close();
    });
    test(
      'frozen aggregate input survives repository recreation and cannot be replaced during inspection',
      () async {
        final input = weeklyInput(),
            draft = await ai.prepare('family', 'child', weeklyInput());
        input['snapshot']['tasks']['completed'] = 999;
        ai = SupabaseAiRepository(client, store);
        final restored = await ai.prepare('family', 'child', input);
        expect(restored, draft);
        await ai.resolve('child', draft['request_id'] as String, 'inspect');
        expect(calls.single['input'], weeklyInput());
        expect(
          (await reports.context('child', '2026-03-08'))['child_id'],
          'child',
        );
        expect(calls.last.keys.toSet(), {'target_child_id', 'anchor_date'});
      },
    );
    test('scope mismatch and wrong feedback receipt are rejected', () async {
      mismatch = true;
      await expectLater(
        reports.context('child', '2026-03-08'),
        throwsStateError,
      );
      await expectLater(
        reports.feedback('child', 'request', 'summary:0'),
        throwsStateError,
      );
      mismatch = false;
      await expectLater(
        reports.context('child', '2026-03-07'),
        throwsStateError,
      );
    });
    test(
      'privacy cleanup during an in-flight context read rejects late data and erases frozen aggregates',
      () async {
        await ai.prepare('family', 'child', weeklyInput());
        entered = Completer<void>();
        hold = Completer<void>();
        final pending = reports.context('child', '2026-03-08');
        final rejection = expectLater(pending, throwsStateError);
        await entered!.future;
        await store.removeReviewCache(
          uid,
          childId: 'child',
          discardCommands: true,
        );
        hold!.complete();
        await rejection;
        expect(await ai.pending('child'), isNull);
      },
    );
  });
}

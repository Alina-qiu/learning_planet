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
import 'package:learning_planet/features/ai/data/similar_question_repository.dart';
import 'package:learning_planet/features/ai/presentation/similar_questions_screen.dart';
import 'package:learning_planet/features/ai/presentation/ai_analysis_screen.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'ai_analysis_test.dart' show FakeAi;

const sourceInput = {
  'kind': 'similar',
  'source_question_id': 'source',
  'source_version': 0,
  'text': '8+7=?',
  'subject': 'math',
  'knowledge_point': '加法',
  'difficulty': 'easy',
};
Map<String, dynamic> generated({List<String> flags = const []}) => {
  'model_version': 'test-model',
  'prompt_version': 'similar-question-v1',
  'confidence': .7,
  'raw_output': 'raw',
  'safety_flags': flags,
  'structured_output': {
    'prompt': '9+6=?',
    'answers': ['15'],
    'subject': 'math',
    'explanation': '先凑十，再加五。',
    'knowledge_point': '加法',
    'difficulty': 'easy',
    'answer_check': {'status': 'passed', 'message': '算式已复算，解析仍需审核。'},
  },
};

class SimilarAi extends FakeAi {
  @override
  Future<Map<String, dynamic>> resolve(
    String child,
    String id,
    String operation,
  ) async {
    if (operation == 'submit') {
      operations.add(operation);
      submits++;
      status = 'completed';
      result = generated();
      if (loseReply) {
        loseReply = false;
        throw StateError('unknown');
      }
      return {
        'request_id': id,
        'child_id': child,
        'status': status,
        'result': result,
      };
    }
    return super.resolve(child, id, operation);
  }
}

class SimilarRepo implements SimilarQuestionRepository {
  SimilarRepo(this.ai);
  final SimilarAi ai;
  int saves = 0, prepares = 0, checks = 0, feedbacks = 0;
  bool loseSave = false;
  String state = 'unknown', checkState = 'passed';
  @override
  Future<Map<String, dynamic>> context(String child, String source) async => {
    'child_id': child,
    'family_id': 'family',
    'input': sourceInput,
  };
  @override
  Future<List<Map<String, dynamic>>> search(
    String child,
    String source,
    String query,
  ) async => [
    {
      'id': 'candidate',
      'final_text': '题库候选题',
      'match_reason': 'knowledge',
      'ai_generated': true,
    },
  ];
  @override
  Future<Map<String, dynamic>> question(String child, String id) async => {
    'child_id': child,
    'final_text': '题库候选题',
    'answers': ['候选答案'],
    'explanation': '候选解析',
    'ai_generated': true,
  };
  @override
  Future<Map<String, dynamic>> check(
    String child,
    Map<String, dynamic> config,
  ) async {
    checks++;
    return {
      'status': checkState,
      'message': checkState == 'failed' ? '标准答案不正确，请修改。' : '请核对题意、全部答案与解析。',
    };
  }

  @override
  Future<Map<String, dynamic>> prepareApproval(
    String child,
    String request,
    Map<String, dynamic> config,
  ) async {
    prepares++;
    return ai.draft = {
      ...ai.draft!,
      'approval': Map<String, dynamic>.from(config),
    };
  }

  @override
  Future<Map<String, dynamic>> save(String child, String request) async {
    saves++;
    state = 'saved';
    if (loseSave) {
      loseSave = false;
      throw StateError('lost');
    }
    return inspect(child, request);
  }

  @override
  Future<Map<String, dynamic>> inspect(String child, String request) async => {
    'request_id': request,
    'status': state,
    if (state == 'saved') 'question_id': 'saved-question',
  };
  @override
  Future<void> feedback(String child, String request, String reason) async {
    feedbacks++;
  }
}

final authorization = StateProvider<String?>((ref) => 'family');
const screen = SimilarQuestionsScreen(
  familyId: 'family',
  childId: 'child',
  sourceId: 'source',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<ProviderContainer> mount(
    WidgetTester tester,
    SimilarAi ai,
    SimilarRepo repo, {
    Widget home = screen,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiRepositoryProvider.overrideWithValue(ai),
          similarQuestionRepositoryProvider.overrideWithValue(repo),
          activeParentFamilyProvider.overrideWith(
            (ref) => ref.watch(authorization),
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

  Future<void> reveal(WidgetTester tester, String label) async {
    final scroll = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(find.text(label), 240, scrollable: scroll);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await reveal(tester, label);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> ready(SimilarAi ai) async {
    await ai.prepare('family', 'child', sourceInput);
    ai.status = 'completed';
    ai.result = generated();
  }

  testWidgets(
    'generation needs explicit consent and unknown response restores the same request without paying twice',
    (tester) async {
      final ai = SimilarAi()..loseReply = true;
      final repo = SimilarRepo(ai);
      await mount(tester, ai, repo);
      expect(ai.submits, 0);
      await reveal(tester, '生成本次练习');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '生成本次练习'))
            .onPressed,
        isNull,
      );
      await tap(tester, '已去除隐私信息，同意发送以上内容生成本次练习');
      await tap(tester, '生成本次练习');
      expect(ai.submits, 1);
      await tap(tester, '核对原请求');
      expect(ai.submits, 1);
      expect(find.text('标准答案：15'), findsNothing);
      expect(find.text('解析：先凑十，再加五。'), findsNothing);
      await tap(tester, '显示答案与解析，开始审核');
      expect(find.text('标准答案：15'), findsOneWidget);
      expect(find.textContaining('低置信度建议'), findsOneWidget);
    },
  );
  testWidgets(
    'failed recomputation leaves result editable and never freezes or saves approval',
    (tester) async {
      final ai = SimilarAi();
      await ready(ai);
      final repo = SimilarRepo(ai)..checkState = 'failed';
      await mount(tester, ai, repo);
      await tap(tester, '显示答案与解析，开始审核');
      await tap(tester, '复算并确认采纳');
      expect(repo.checks, 1);
      expect(repo.prepares, 0);
      expect(repo.saves, 0);
      expect(find.text('标准答案不正确，请修改。'), findsOneWidget);
      await tap(tester, '编辑题目、答案与解析');
      expect(find.text('审核 AI 生成题目'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语').last);
      await tester.pumpAndSettle();
      await tap(tester, '保存');
      await tap(tester, '复算并确认采纳');
      expect(find.textContaining('审核内容尚未冻结'), findsOneWidget);
      expect(repo.prepares, 0);
      expect(repo.checks, 1);
    },
  );
  testWidgets(
    'manual verification requires explicit adoption and lost save reply resolves without another insert',
    (tester) async {
      final ai = SimilarAi();
      await ready(ai);
      final repo = SimilarRepo(ai)
        ..checkState = 'manual'
        ..loseSave = true;
      await mount(tester, ai, repo);
      await tap(tester, '显示答案与解析，开始审核');
      await tap(tester, '复算并确认采纳');
      expect(find.text('确认采纳 AI 练习题'), findsOneWidget);
      expect(repo.saves, 0);
      await tester.tap(find.text('返回修改'));
      await tester.pumpAndSettle();
      expect(repo.prepares, 0);
      await tap(tester, '复算并确认采纳');
      await tester.tap(find.text('我已逐项核对，确认保存'));
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
      expect(ai.draft!['approval'], isNotNull);
      await tap(tester, '核对并继续原保存请求');
      expect(repo.saves, 1);
      expect(find.textContaining('已保存到题库'), findsOneWidget);
      expect(ai.submits, 0);
    },
  );
  testWidgets(
    'PIN expiration masks generated results and the nested edit page',
    (tester) async {
      final ai = SimilarAi();
      await ready(ai);
      final repo = SimilarRepo(ai);
      final container = await mount(tester, ai, repo);
      await tap(tester, '显示答案与解析，开始审核');
      await tap(tester, '编辑题目、答案与解析');
      expect(find.text('9+6=?'), findsOneWidget);
      container.read(authorization.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('9+6=?'), findsNothing);
      expect(find.text('家长授权已到期，请返回后重新验证'), findsOneWidget);
      expect(repo.saves, 0);
    },
  );
  testWidgets(
    'candidate answers are collapsed and safety flags suppress normal output while allowing feedback',
    (tester) async {
      final ai = SimilarAi();
      await ready(ai);
      ai.result = generated(flags: ['bullying']);
      final repo = SimilarRepo(ai);
      await mount(tester, ai, repo);
      expect(find.text('9+6=?'), findsNothing);
      await tap(tester, '提交反馈');
      expect(repo.feedbacks, 1);
      await tap(tester, '【AI生成·家长已审核】题库候选题');
      expect(find.text('标准答案：候选答案'), findsNothing);
      await tester.tap(find.text('显示答案与解析'));
      await tester.pumpAndSettle();
      expect(find.text('标准答案：候选答案'), findsOneWidget);
    },
  );
  testWidgets(
    'classification page cannot submit or apply a pending similar-question request',
    (tester) async {
      final ai = SimilarAi();
      await ready(ai);
      final repo = SimilarRepo(ai);
      await mount(
        tester,
        ai,
        repo,
        home: const AiAnalysisScreen(
          familyId: 'family',
          childId: 'child',
          input: {'text': '8+7=?', 'subject': 'math'},
        ),
      );
      expect(find.text('采纳到当前草稿'), findsNothing);
      expect(ai.submits, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'regeneration cancels the prior request and 360px double text remains usable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ai = SimilarAi();
      await ready(ai);
      final repo = SimilarRepo(ai);
      await mount(tester, ai, repo, scale: 2);
      await tap(tester, '结束或重新生成');
      await tester.tap(find.text('结束原请求'));
      await tester.pumpAndSettle();
      expect(ai.ends, 1);
      expect(ai.submits, 0);
      await reveal(tester, '生成本次练习');
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '生成本次练习'))
            .onPressed,
        isNull,
      );
    },
  );

  group('durable approval transport', () {
    late OfflineStore store;
    late SupabaseClient client;
    late SupabaseAiRepository ai;
    late SupabaseSimilarQuestionRepository repo;
    const uid = '10000000-0000-0000-0000-000000000001';
    final sent = <Map<String, dynamic>>[];
    bool lost = false, mismatch = false;
    String state = 'unknown';
    Completer<void>? entered, hold;
    setUp(() async {
      store = OfflineStore(NativeDatabase.memory());
      sent.clear();
      lost = false;
      mismatch = false;
      state = 'unknown';
      entered = null;
      hold = null;
      client = SupabaseClient(
        'https://project.supabase.co',
        'public',
        httpClient: MockClient((request) async {
          http.Response reply(Object? value, [int code = 200]) => http.Response(
            jsonEncode(value),
            code,
            headers: {'content-type': 'application/json'},
            request: request,
          );
          if (request.url.path.endsWith('/token')) {
            return reply({
              'access_token':
                  'header.${base64UrlEncode(utf8.encode(jsonEncode({'sub': uid, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})))}.signature',
              'refresh_token': 'mock-refresh',
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
          sent.add(body);
          if (entered != null && !entered!.isCompleted) entered!.complete();
          await hold?.future;
          if (request.url.path.endsWith('/adopt_similar_question')) {
            state = 'saved';
            if (lost) {
              lost = false;
              return reply({'message': 'unknown'}, 503);
            }
          }
          return reply({
            'request_id': mismatch ? 'wrong' : body['request_id'],
            'status': state,
            if (state == 'saved') 'question_id': 'saved',
          });
        }),
      );
      await client.auth.signInWithPassword(
        email: 'parent@example.test',
        password: 'local-only',
      );
      ai = SupabaseAiRepository(client, store);
      repo = SupabaseSimilarQuestionRepository(client, store);
    });
    tearDown(() async {
      await client.dispose();
      await store.close();
    });
    final config = {
      'prompt': '9+6=?',
      'answers': ['15'],
      'subject': 'math',
      'knowledge_point': '加法',
      'difficulty': 'easy',
      'explanation': '凑十',
      'reviewed': true,
    };
    test(
      'frozen approval survives repository restart and unknown save result with one original payload',
      () async {
        final draft = await ai.prepare('family', 'child', sourceInput);
        final id = draft['request_id'] as String;
        final mutable = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
        await repo.prepareApproval('child', id, mutable);
        mutable['answers'] = ['999'];
        lost = true;
        await expectLater(
          repo.save('child', id),
          throwsA(isA<PostgrestException>()),
        );
        repo = SupabaseSimilarQuestionRepository(client, store);
        final restored = await repo.prepareApproval('child', id, {
          ...config,
          'prompt': 'changed',
        });
        expect(restored['approval'], config);
        expect((await repo.inspect('child', id))['status'], 'saved');
        expect(
          sent.where((b) => b.containsKey('config')).single['config'],
          config,
        );
      },
    );
    test(
      'privacy cleanup rejects late approval response and removes frozen answer body',
      () async {
        final id =
            (await ai.prepare('family', 'child', sourceInput))['request_id']
                as String;
        await repo.prepareApproval('child', id, config);
        entered = Completer<void>();
        hold = Completer<void>();
        final saving = repo.save('child', id);
        final rejection = expectLater(saving, throwsStateError);
        await entered!.future;
        await store.removeReviewCache(
          uid,
          childId: 'child',
          discardCommands: true,
        );
        hold!.complete();
        await rejection;
        expect(await store.read(uid, 'ai-request:child'), isNull);
      },
    );
    test(
      'mismatched receipt cannot confirm save and a deleted child cannot freeze a new approval',
      () async {
        final id =
            (await ai.prepare('family', 'child', sourceInput))['request_id']
                as String;
        await repo.prepareApproval('child', id, config);
        mismatch = true;
        await expectLater(repo.save('child', id), throwsStateError);
        expect(
          (await store.read(uid, 'ai-request:child'))!['approval'],
          config,
        );
        await store.removeChildData('child');
        await expectLater(
          repo.prepareApproval('child', id, config),
          throwsStateError,
        );
      },
    );
  });
}

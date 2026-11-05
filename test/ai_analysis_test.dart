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
import 'package:learning_planet/features/ai/presentation/ai_settings_screen.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';

const question = {'text': '8 + 7 = ?', 'subject': 'math'};
Map<String, dynamic> policy() => {
  'enabled': true,
  'available': true,
  'can_manage': true,
  'version': 1,
  'monthly_limit': 100,
  'budget_cents': 10000,
  'retention_days': 7,
  'requests': 0,
  'reserved_cents': 0,
  'reserve_cents': 100,
};
Map<String, dynamic> output({List<String> flags = const []}) => {
  'model_version': 'test-model',
  'prompt_version': 'question-structure-v1',
  'confidence': .6,
  'raw_output': 'raw',
  'structured_output': {
    'knowledge_points': ['进位加法'],
    'difficulty': 'easy',
    'error_reasons': ['calculation'],
  },
  'safety_flags': flags,
};

class FakeAi implements AiRepository {
  Map<String, dynamic> config = policy();
  Map<String, dynamic>? draft;
  Map<String, dynamic>? result;
  String status = 'unknown';
  int submits = 0, ends = 0;
  bool loseReply = false, failEnd = false;
  final operations = <String>[];
  @override
  Future<Map<String, dynamic>> settings(String id) async => {...config};
  @override
  Future<Map<String, dynamic>> context(String id) async => {
    ...config,
    'generation': 0,
    'grade': 2,
  };
  @override
  Future<Map<String, dynamic>> updateSettings(
    String id,
    int version,
    Map<String, dynamic> value,
  ) async {
    config = {...config, ...value, 'version': version + 1};
    return {...config};
  }

  @override
  Future<Map<String, dynamic>?> pending(String id) async => draft;
  @override
  Future<Map<String, dynamic>> prepare(
    String familyId,
    String childId,
    Map<String, dynamic> input, {
    int generation = 0,
  }) async => draft ??= {
    'request_id': 'request',
    'family_id': familyId,
    'child_id': childId,
    'generation': generation,
    'input': Map<String, dynamic>.from(input),
  };
  @override
  Future<Map<String, dynamic>> resolve(
    String childId,
    String id,
    String operation,
  ) async {
    operations.add(operation);
    if (operation == 'submit') {
      submits++;
      status = 'completed';
      result = output();
      if (loseReply) {
        loseReply = false;
        throw StateError('lost reply');
      }
    }
    return {
      'request_id': id,
      'child_id': childId,
      'status': status,
      'result': result,
    };
  }

  @override
  Future<void> dismiss(String childId, String id) async {
    if (failEnd) throw StateError('offline');
    ends++;
    draft = null;
    result = null;
    status = 'discarded';
  }
}

final parent = StateProvider<String?>((ref) => 'family');
Widget app(FakeAi repo, Widget home, {ProviderContainer? container}) {
  final child = MaterialApp(theme: buildAppTheme(), home: home);
  return container == null
      ? ProviderScope(
          overrides: [
            aiRepositoryProvider.overrideWithValue(repo),
            activeParentFamilyProvider.overrideWith((ref) => ref.watch(parent)),
          ],
          child: child,
        )
      : UncontrolledProviderScope(container: container, child: child);
}

const screen = AiAnalysisScreen(
  familyId: 'family',
  childId: 'child',
  input: question,
);
Future<void> tap(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'AI needs explicit consent, lost response only inspects original request, low confidence needs review',
    (tester) async {
      final repo = FakeAi()..loseReply = true;
      await tester.pumpWidget(app(repo, screen));
      await tester.pumpAndSettle();
      expect(repo.submits, 0);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送本次分析'))
            .onPressed,
        isNull,
      );
      await tap(tester, '我已去除隐私信息，同意发送这些文字进行本次分析');
      await tap(tester, '发送本次分析');
      expect(repo.submits, 1);
      expect(find.textContaining('未能确认结果'), findsOneWidget);
      await tap(tester, '核对原请求');
      expect(repo.submits, 1);
      expect(find.textContaining('低置信'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '采纳到当前草稿'))
            .onPressed,
        isNull,
      );
      expect(repo.operations, ['inspect', 'submit', 'inspect']);
      expect(repo.ends, 0);
    },
  );
  testWidgets(
    'AI restores frozen earlier input without resending and prevents applying it to another question',
    (tester) async {
      final repo = FakeAi();
      await repo.prepare('family', 'child', {'text': '旧题目', 'subject': 'math'});
      repo.status = 'completed';
      repo.result = output();
      await tester.pumpWidget(app(repo, screen));
      await tester.pumpAndSettle();
      expect(find.text('旧题目'), findsOneWidget);
      expect(find.textContaining('与当前编辑内容不同'), findsOneWidget);
      expect(repo.submits, 0);
      await tap(tester, '我已逐项核对建议，并确认候选错因适用于这道题');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '采纳到当前草稿'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'AI apply rechecks a remotely disabled result and never adopts stale suggestion',
    (tester) async {
      final repo = FakeAi();
      await repo.prepare('family', 'child', question);
      repo.status = 'completed';
      repo.result = output();
      await tester.pumpWidget(app(repo, screen));
      await tester.pumpAndSettle();
      await tap(tester, '我已逐项核对建议，并确认候选错因适用于这道题');
      repo.status = 'discarded';
      repo.result = null;
      await tap(tester, '采纳到当前草稿');
      expect(repo.ends, 0);
      expect(find.text('请求状态：结果已清除'), findsOneWidget);
      expect(find.text('采纳到当前草稿'), findsNothing);
    },
  );
  testWidgets(
    'AI flags suppress ordinary suggestions and parent expiry hides text and controls',
    (tester) async {
      final repo = FakeAi();
      await repo.prepare('family', 'child', question);
      repo.status = 'completed';
      repo.result = output(flags: ['bullying']);
      final container = ProviderContainer(
        overrides: [
          aiRepositoryProvider.overrideWithValue(repo),
          activeParentFamilyProvider.overrideWith((ref) => ref.watch(parent)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(app(repo, screen, container: container));
      await tester.pumpAndSettle();
      expect(find.textContaining('可信任的成年人'), findsOneWidget);
      expect(find.text('采纳到当前草稿'), findsNothing);
      container.read(parent.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text(question['text']!), findsNothing);
      expect(find.textContaining('家长授权已到期'), findsOneWidget);
    },
  );
  testWidgets(
    'AI cancellation failure retains request and does not enable a second paid submission',
    (tester) async {
      final repo = FakeAi()..failEnd = true;
      await repo.prepare('family', 'child', question);
      repo.status = 'running';
      await tester.pumpWidget(app(repo, screen));
      await tester.pumpAndSettle();
      await tap(tester, '结束并清除本次建议');
      await tap(tester, '确认结束');
      expect(repo.draft, isNotNull);
      expect(repo.ends, 0);
      expect(find.text('发送本次分析'), findsNothing);
    },
  );
  testWidgets(
    'AI settings save explicit off and expose actual usage without optimistic success',
    (tester) async {
      final repo = FakeAi();
      await tester.pumpWidget(
        app(repo, const AiSettingsScreen(familyId: 'family')),
      );
      await tester.pumpAndSettle();
      await tap(tester, '允许 AI 分析');
      expect(repo.config['enabled'], true);
      await tap(tester, '保存设置');
      expect(repo.config['enabled'], false);
      expect(find.text('AI 设置已保存'), findsOneWidget);
      expect(find.textContaining('这不是供应商实际账单'), findsOneWidget);
    },
  );
  testWidgets(
    'AI accepted suggestion returns only reviewed data after a fresh receipt',
    (tester) async {
      final repo = FakeAi();
      await repo.prepare('family', 'child', question);
      repo.status = 'completed';
      repo.result = output();
      Map<String, dynamic>? adopted;
      await tester.pumpWidget(
        app(
          repo,
          Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  adopted = await Navigator.push<Map<String, dynamic>>(
                    context,
                    MaterialPageRoute(builder: (_) => screen),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tap(tester, '打开');
      await tap(tester, '我已逐项核对建议，并确认候选错因适用于这道题');
      await tap(tester, '采纳到当前草稿');
      expect(adopted!['input'], question);
      expect(
        (adopted!['result'] as Map)['structured_output'],
        output()['structured_output'],
      );
      expect(repo.ends, 1);
      expect(repo.operations, ['inspect', 'inspect']);
    },
  );

  group('AI durable transport', () {
    late OfflineStore store;
    late SupabaseClient client;
    late SupabaseAiRepository repo;
    const uid = '10000000-0000-0000-0000-000000000001';
    final sent = <Map<String, dynamic>>[];
    String status = 'unknown';
    bool mismatch = false, loseSubmit = false;
    Completer<void>? hold;
    setUp(() async {
      store = OfflineStore(NativeDatabase.memory());
      sent.clear();
      status = 'unknown';
      mismatch = false;
      loseSubmit = false;
      hold = null;
      client = SupabaseClient(
        'https://project.supabase.co',
        'public',
        httpClient: MockClient((request) async {
          http.Response reply(Object? body, [int code = 200]) => http.Response(
            jsonEncode(body),
            code,
            headers: {'content-type': 'application/json'},
            request: request,
          );
          if (request.url.path.endsWith('/token')) {
            return reply({
              'access_token':
                  'header.${base64UrlEncode(utf8.encode(jsonEncode({'sub': uid, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})))}.signature',
              'refresh_token': 'refresh',
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
          if (request.url.path.endsWith('/logout')) return reply({});
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          sent.add(body);
          await hold?.future;
          if (request.url.path.endsWith('/ai-analysis')) {
            status = 'running';
            if (loseSubmit) {
              loseSubmit = false;
              return reply({'error': 'unknown'}, 503);
            }
          }
          if (body['operation'] == 'cancel') status = 'discarded';
          return reply({
            'request_id': mismatch ? 'wrong' : body['request_id'],
            'child_id': body['child_id'] ?? body['target_child_id'],
            'status': status,
          });
        }),
      );
      await client.auth.signInWithPassword(
        email: 'parent@example.test',
        password: 'local-test-only',
      );
      repo = SupabaseAiRepository(client, store);
    });
    tearDown(() async {
      await client.dispose();
      await store.close();
    });
    test(
      'request is stored before sending and resumed after unknown acknowledgement with identical immutable input',
      () async {
        final input = Map<String, dynamic>.from(question);
        final first = await repo.prepare('family', 'child', input);
        input['text'] = 'changed';
        expect(first['input'], question);
        loseSubmit = true;
        await expectLater(
          repo.resolve('child', first['request_id'] as String, 'submit'),
          throwsA(isA<FunctionException>()),
        );
        repo = SupabaseAiRepository(client, store);
        final saved = await repo.pending('child');
        expect(saved, first);
        final result = await repo.resolve(
          'child',
          first['request_id'] as String,
          'inspect',
        );
        expect(result['status'], 'running');
        expect(sent[0]['input'], sent[1]['input']);
        expect(sent[0]['request_id'], sent[1]['request_id']);
        expect(
          await repo.prepare('family', 'child', {
            'text': 'other',
            'subject': 'math',
          }),
          first,
        );
        await repo.dismiss('child', first['request_id'] as String);
        expect(await repo.pending('child'), isNull);
        expect(sent.last['operation'], 'cancel');
      },
    );
    test(
      'receipt mismatch retains pending request and child deletion removes text and rejects a late response',
      () async {
        final draft = await repo.prepare('family', 'child', question);
        mismatch = true;
        await expectLater(
          repo.resolve('child', draft['request_id'] as String, 'inspect'),
          throwsStateError,
        );
        expect(await repo.pending('child'), isNotNull);
        mismatch = false;
        hold = Completer<void>();
        final response = repo.resolve(
          'child',
          draft['request_id'] as String,
          'inspect',
        );
        final expectation = expectLater(response, throwsStateError);
        while (sent.length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await store.removeChildData('child');
        hold!.complete();
        await expectation;
        expect(await store.read(uid, 'ai-request:child'), isNull);
      },
    );
    test(
      'cancellation receipt mismatch preserves intent; targeted question cleanup erases only that child AI draft',
      () async {
        final a = await repo.prepare(
          'family',
          'child',
          question,
          generation: 3,
        );
        await repo.prepare('family', 'sibling', question);
        mismatch = true;
        await expectLater(
          repo.dismiss('child', a['request_id'] as String),
          throwsStateError,
        );
        expect(await repo.pending('child'), isNotNull);
        expect(sent.last['expected_generation'], 3);
        await store.removeReviewCache(
          uid,
          childId: 'child',
          questionIds: {'question'},
        );
        expect(await repo.pending('child'), isNull);
        expect(await repo.pending('sibling'), isNotNull);
      },
    );
    test(
      'logout during response rejects private output without writing it to local storage',
      () async {
        final draft = await repo.prepare('family', 'child', question);
        hold = Completer<void>();
        final response = repo.resolve(
          'child',
          draft['request_id'] as String,
          'inspect',
        );
        final expectation = expectLater(response, throwsStateError);
        while (sent.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await client.auth.signOut();
        hold!.complete();
        await expectation;
        expect(
          (await store.read(uid, 'ai-request:child'))!.containsKey('result'),
          false,
        );
      },
    );
  });
}

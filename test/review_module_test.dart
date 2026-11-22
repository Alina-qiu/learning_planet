import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_progress.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_confidence.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_scheduler.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_hub_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'widget_test.dart' show FakeFamilyRepository;

class FakeReviewRepository implements ReviewRepository {
  String status = 'ready';
  bool online = true, forbidden = false, cached = false;
  bool? result;
  String? submitted;
  ReviewConfidence? submittedConfidence;
  int transitionCalls = 0, completionCalls = 0;
  final manualSaves = <Map<String, dynamic>>[];
  final saveRequests = <String?>[];
  Completer<void>? pendingSave;
  void check() {
    if (forbidden) {
      throw const PostgrestException(message: 'Denied', code: '42501');
    }
    if (!online) throw const SocketException('offline');
  }

  @override
  Future<List<Map<String, dynamic>>> questions(String childId) async {
    check();
    return [
      {
        'id': 'q',
        'final_text': '银行',
        'review_kind': 'pinyin',
        'pronunciation_context': '我去银行存钱',
        'mastery_status': 'practicing',
        'review_attempts': 0,
        'wrong_count': 1,
        'archived': false,
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> overview(String childId) async {
    check();
    return {'task_id': 'task', 'due': 1, 'backlog': 2};
  }

  @override
  Future<Map<String, dynamic>> editor(String questionId) async {
    check();
    return {
      'answers': ['yín háng'],
    };
  }

  @override
  Future<void> save(
    String childId,
    Map<String, dynamic> config, {
    String? questionId,
    String? requestId,
  }) async {
    manualSaves.add(config);
    saveRequests.add(requestId);
    check();
    await pendingSave?.future;
  }

  @override
  Future<void> archive(String questionId, bool archived) async {
    check();
  }

  @override
  Future<Map<String, dynamic>> task(String taskId) async {
    check();
    return jsonDecode(
          jsonEncode({
            'offline_cache': cached,
            'task': {
              'id': taskId,
              'status': status,
              'coin_reward': 5,
              'xp_reward': 5,
            },
            'items': [
              {
                'wrong_question_id': 'q',
                'sequence': 1,
                'prompt': '银行',
                'review_kind': 'pinyin',
                'pronunciation_context': '我去银行存钱',
                'result': result,
                'answer_text': submitted,
                'answer_confidence': submittedConfidence?.wire,
                'accepted_answers': result == null ? null : ['yín háng'],
                'explanation': result == null ? null : '这里读háng',
              },
            ],
          }),
        )
        as Map<String, dynamic>;
  }

  @override
  Future<void> transition(String taskId, String operation) async {
    check();
    transitionCalls++;
    status = operation == 'pause' ? 'paused' : 'in_progress';
  }

  @override
  Future<Map<String, dynamic>> answer(
    String taskId,
    String questionId,
    String answer,
    String commandId, {
    ReviewConfidence? confidence,
  }) async {
    check();
    submitted = answer;
    submittedConfidence = confidence;
    result = answer == 'yin2 hang2';
    return task(taskId);
  }

  @override
  Future<void> complete(String taskId, String key) async {
    check();
    if (result == null) throw StateError('All answers required');
    status = 'completed';
    completionCalls++;
  }
}

void main() {
  test(
    'review progress advances through 1/3/7/30 and only then marks mastered',
    () {
      final date = DateTime(2026, 9, 16);
      for (var step = 0; step < 4; step++) {
        final progress = ReviewProgress.after(
          step: step,
          correct: true,
          familyDate: date,
        );
        expect(progress.step, step + 1);
        expect(progress.mastered, isFalse);
        expect(
          progress.nextDate,
          date.add(Duration(days: ReviewProgress.intervals[step])),
        );
      }
      final mastered = ReviewProgress.after(
        step: 4,
        correct: true,
        familyDate: date,
      );
      expect(mastered.mastered, isTrue);
      expect(mastered.nextDate, isNull);
    },
  );
  test(
    'wrong answer resets review stage to one day, including prior mastered stage',
    () {
      final date = DateTime(2026, 9, 16);
      final progress = ReviewProgress.after(
        step: 4,
        correct: false,
        familyDate: date,
      );
      expect(progress.step, 0);
      expect(progress.nextDate, DateTime(2026, 9, 17));
      expect(progress.mastered, isFalse);
      expect(
        () => ReviewProgress.after(step: 5, correct: true, familyDate: date),
        throwsRangeError,
      );
    },
  );
  test(
    'scheduler caps oversized configuration at ten and resolves ties by ID',
    () {
      final day = DateTime(2026, 9, 16);
      final rows = [
        for (var i = 14; i >= 0; i--)
          ReviewCandidate(
            id: i.toString().padLeft(2, '0'),
            reviewDueAt: day,
            wrongCount: 1,
          ),
      ];
      final draft = const ReviewScheduler(
        maxQuestionsPerDay: 100,
      ).buildDailyTask(familyDate: day, candidates: rows)!;
      expect(draft.questionIds.length, 10);
      expect(draft.questionIds.first, '00');
      expect(draft.questionIds.last, '09');
    },
  );
  test(
    'review cache is account scoped, refuses known denial and never queues grading',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final live = FakeReviewRepository();
      String? owner = 'a';
      final cached = CachedReviewRepository(live, store, () => owner);
      try {
        await cached.task('task');
        live.online = false;
        expect((await cached.task('task'))['offline_cache'], isTrue);
        await expectLater(
          cached.answer('task', 'q', 'yin2 hang2', 'command'),
          throwsA(isA<SocketException>()),
        );
        expect(await store.commands('a'), isEmpty);
        owner = 'b';
        await expectLater(cached.task('task'), throwsA(isA<SocketException>()));
        owner = 'a';
        live.online = true;
        live.forbidden = true;
        await expectLater(
          cached.task('task'),
          throwsA(isA<PostgrestException>()),
        );
        expect(await store.read('a', 'review-task:task'), isNull);
        live.forbidden = false;
        await cached.editor('q');
        expect(await store.read('a', 'review-editor:q'), isNull);
      } finally {
        await store.close();
      }
    },
  );

  Future<void> mount(
    WidgetTester tester,
    FakeReviewRepository live,
    Widget page, {
    bool authorized = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewRepositoryProvider.overrideWithValue(live),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          activeParentFamilyProvider.overrideWithValue(
            authorized ? 'family' : null,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'review page reveals keys only after submit and finishes through the server',
    (tester) async {
      final live = FakeReviewRepository();
      await mount(
        tester,
        live,
        const ReviewSessionScreen(taskId: 'task', childId: 'child'),
      );
      expect(find.textContaining('标准答案：'), findsNothing);
      expect(find.text('完成复习并结算'), findsNothing);
      await tester.tap(find.text('开始复习'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'yin2 hang2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('有点把握'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('有点把握'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('提交答案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交答案'));
      await tester.pumpAndSettle();
      expect(find.text('回答正确 ✓'), findsOneWidget);
      expect(find.text('标准答案：yín háng'), findsOneWidget);
      await tester.ensureVisible(find.text('完成复习并结算'));
      await tester.tap(find.text('完成复习并结算'));
      await tester.pumpAndSettle();
      expect(live.completionCalls, 1);
      expect(find.text('复习已完成，奖励已由服务端确认'), findsOneWidget);
      expect(find.text('完成复习并结算'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'offline review cache cannot enable answer or pretend completion',
    (tester) async {
      final live = FakeReviewRepository()
        ..status = 'in_progress'
        ..cached = true;
      await mount(
        tester,
        live,
        const ReviewSessionScreen(taskId: 'task', childId: 'child'),
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.textContaining('离线缓存：'), findsOneWidget);
      expect(live.completionCalls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'review hub restricts editing to current family PIN authorization',
    (tester) async {
      await mount(
        tester,
        FakeReviewRepository(),
        const ReviewHubScreen(childId: 'child', familyId: 'family'),
      );
      expect(find.text('手工录入错题'), findsNothing);
      expect(find.text('新增拼音词语'), findsNothing);
      expect(find.textContaining('可以录入错题交给家长确认'), findsOneWidget);
      expect(find.text('拍照 / 相册 OCR 录入'), findsOneWidget);
      expect(find.text('孩子提交与家长确认'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'manual editor retains input on failure and retries just once with the same request',
    (tester) async {
      tester.view.physicalSize = const Size(850, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = FakeReviewRepository();
      await mount(
        tester,
        live,
        const ReviewHubScreen(childId: 'child', familyId: 'family'),
        authorized: true,
      );
      await tester.tap(find.text('手工录入错题'));
      await tester.pumpAndSettle();
      final prompt = find.widgetWithText(TextFormField, '题目');
      final answers = find.widgetWithText(TextFormField, '标准答案（一行一个可接受答案）');
      final save = find.text('保存');
      await tester.enterText(prompt, '6 × 7');
      await tester.enterText(answers, '42');
      live.online = false;
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.text('6 × 7'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(live.saveRequests.single, isNotNull);
      await tester.enterText(prompt, '6 × 7 = ?');
      live.online = true;
      live.pendingSave = Completer<void>();
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.tap(save);
      await tester.pump();
      expect(find.text('正在保存…'), findsOneWidget);
      expect(live.saveRequests, [
        live.saveRequests.first,
        live.saveRequests.first,
      ]);
      expect(live.manualSaves.last['prompt'], '6 × 7 = ?');
      expect(live.manualSaves.last['answers'], ['42']);
      live.pendingSave!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ReviewQuestionEditor), findsNothing);
      expect(find.text('手工录入错题'), findsOneWidget);
    },
  );

  for (final (size, scale, insets) in [
    (const Size(412, 800), 1.0, const FakeViewPadding(top: 24, bottom: 48)),
    (const Size(320, 640), 2.0, const FakeViewPadding(top: 24, bottom: 48)),
    (const Size(720, 360), 2.0, const FakeViewPadding(left: 24, right: 48)),
  ]) {
    testWidgets(
      'manual editor save and retry clear system navigation at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.viewPadding = insets;
        tester.view.padding = insets;
        addTearDown(tester.view.reset);
        var attempts = 0;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    child: const Text('打开编辑器'),
                    onPressed: () =>
                        Navigator.of(context).push<Map<String, dynamic>>(
                          MaterialPageRoute(
                            builder: (_) => ReviewQuestionEditor(
                              pinyin: false,
                              initial: const {
                                'final_text': '6 × 7',
                                'answers': ['42'],
                              },
                              onSave: (config) async {
                                expect(config['answers'], ['42']);
                                if (++attempts == 1) throw StateError('网络暂不可用');
                              },
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开编辑器'));
        await tester.pumpAndSettle();
        final save = find.widgetWithText(FilledButton, '保存');
        final list = find.byType(Scrollable).first;
        for (var attempt = 1; attempt <= 2; attempt++) {
          await tester.scrollUntilVisible(save, 200, scrollable: list);
          await tester.drag(find.byType(ListView), const Offset(0, -300));
          await tester.pumpAndSettle();
          final error = find.textContaining('网络暂不可用');
          for (final control in [save, if (attempt == 2) error]) {
            final rect = tester.getRect(control);
            expect(rect.left, greaterThanOrEqualTo(insets.left));
            expect(rect.right, lessThanOrEqualTo(size.width - insets.right));
            expect(rect.top, greaterThanOrEqualTo(insets.top));
            expect(rect.bottom, lessThanOrEqualTo(size.height - insets.bottom));
          }
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(attempts, attempt);
        }
        expect(find.text('打开编辑器'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<ProviderContainer> openParentEditor(
    WidgetTester tester,
    FakeReviewRepository live,
  ) async {
    tester.view.physicalSize = const Size(850, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewRepositoryProvider.overrideWithValue(live),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          familyRepositoryProvider.overrideWithValue(FakeFamilyRepository()),
          authorizationClockProvider.overrideWith(
            (ref) => Stream.value(DateTime.now()),
          ),
        ],
        child: const MaterialApp(
          home: ReviewHubScreen(childId: 'child', familyId: 'family'),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReviewHubScreen)),
    );
    container.read(parentModeProvider.notifier).state = true;
    container.read(parentFamilyIdProvider.notifier).state = 'family';
    container.read(parentAuthorizedUntilProvider.notifier).state =
        DateTime.now().add(const Duration(minutes: 10));
    await tester.pumpAndSettle();
    expect(container.read(activeParentFamilyProvider), 'family');
    await tester.scrollUntilVisible(
      find.text('手工录入错题'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('手工录入错题'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '题目'),
      'private draft',
    );
    return container;
  }

  testWidgets(
    'manual editor hides its draft until PIN renewal and clears it on account change',
    (tester) async {
      final live = FakeReviewRepository();
      final container = await openParentEditor(tester, live);
      container.read(parentAuthorizedUntilProvider.notifier).state = DateTime(
        2000,
      );
      await tester.pumpAndSettle();
      expect(find.text('private draft'), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect(live.manualSaves, isEmpty);
      await tester.tap(find.text('验证家长 PIN 后继续编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('验证'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('private draft'), findsOneWidget);
      final answerField = find.widgetWithText(TextFormField, '标准答案（一行一个可接受答案）');
      await tester.ensureVisible(answerField);
      await tester.enterText(answerField, 'private answer');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '保存'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      live.pendingSave = Completer<void>();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(live.manualSaves, hasLength(1));
      container.read(parentAuthorizationRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      live.pendingSave!.completeError(
        const PostgrestException(
          code: '42501',
          message: 'Parent authorization expired',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReviewQuestionEditor), findsNothing);
      expect(find.text('private draft'), findsNothing);
      expect(find.text('登录状态已变化，请返回错题本'), findsOneWidget);
      expect(container.read(parentAuthorizedUntilProvider), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server PIN revocation locks the matching editor grant and preserves the draft for renewal',
    (tester) async {
      final live = FakeReviewRepository();
      final container = await openParentEditor(tester, live);
      await tester.enterText(
        find.widgetWithText(TextFormField, '标准答案（一行一个可接受答案）'),
        'private answer',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      Future<void> submit() async {
        live.pendingSave = Completer<void>();
        await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
        await tester.tap(find.text('保存'));
        await tester.pump();
      }

      Future<void> reject(String message) async {
        live.pendingSave!.completeError(
          PostgrestException(code: '42501', message: message),
        );
        await tester.pumpAndSettle();
      }

      const expired = 'Parent authorization expired';
      await submit();
      await reject('Child access required');
      expect(container.read(activeParentFamilyProvider), 'family');
      await submit();
      container.read(parentFamilyIdProvider.notifier).state = 'another family';
      await tester.pump();
      await reject(expired);
      expect(container.read(activeParentFamilyProvider), 'another family');
      container.read(parentFamilyIdProvider.notifier).state = 'family';
      await tester.pumpAndSettle();
      await submit();
      final renewedElsewhere = DateTime.now().add(const Duration(minutes: 20));
      container.read(parentAuthorizedUntilProvider.notifier).state =
          renewedElsewhere;
      await reject(expired);
      expect(container.read(parentAuthorizedUntilProvider), renewedElsewhere);
      for (final reason in [
        'Parent authorization required or expired',
        expired,
      ]) {
        await submit();
        await reject(reason);
        expect(container.read(parentAuthorizedUntilProvider), isNull);
        expect(find.text('private answer'), findsNothing);
        expect(find.text('private draft'), findsNothing);
        await tester.tap(find.text('验证家长 PIN 后继续编辑'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '1234');
        await tester.tap(find.text('验证'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.text('private draft'), findsOneWidget);
        expect(find.text('private answer'), findsOneWidget);
      }
      expect(live.saveRequests.toSet(), hasLength(1));
    },
  );

  testWidgets(
    'pinyin editor requires parent pronunciation confirmation and retains tone marks',
    (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  captured = await Navigator.of(context)
                      .push<Map<String, dynamic>>(
                        MaterialPageRoute(
                          builder: (_) =>
                              const ReviewQuestionEditor(pinyin: true),
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
      await tester.enterText(find.byType(TextFormField).at(0), '银行');
      await tester.enterText(find.byType(TextFormField).at(1), '我去银行存钱');
      await tester.enterText(find.byType(TextFormField).at(2), 'yín háng');
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('保存'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(captured, isNull);
      expect(find.text('请先确认语境及标准读音'), findsOneWidget);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(captured?['answers'], ['yín háng']);
      expect(captured?['pronunciation_confirmed'], true);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

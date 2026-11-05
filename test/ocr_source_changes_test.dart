import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/question_ocr_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';
import 'ocr_management_test.dart' show FakeImages, FakeMedia, fixture;

class ReplacedRecognition extends FakeImages {
  int processes = 0;
  @override
  Future<Uint8List> process(
    Uint8List original,
    int turns,
    List<double> crop, {
    bool enhance = false,
  }) async {
    processes++;
    return fixture();
  }

  @override
  Future<Map<String, dynamic>> recognize(Uint8List processed) async {
    recognitions++;
    if (this.fail) throw StateError('未识别到文字');
    return {
      'text': '6 + 3 = ?',
      'lines': [
        {'text': '6 + 3 = ?', 'confidence': null},
      ],
    };
  }
}

void main() {
  late OfflineStore store;
  late OfflineQuestionMediaRepository repository;
  late ReplacedRecognition images;
  late FakeMedia remote;
  String? parent;
  const draft = '00000000-0000-4000-8000-000000000001';
  const otherDraft = '00000000-0000-4000-8000-000000000002';
  const corrections = {
    'prompt': '人工校对的旧题干',
    'options': 'A. 4\nB. 5',
    'answer': '5',
    'annotation': '旧批注',
  };
  setUp(() async {
    store = OfflineStore(NativeDatabase.memory());
    parent = 'family';
    images = ReplacedRecognition();
    remote = FakeMedia();
    repository = OfflineQuestionMediaRepository(
      store: store,
      live: remote,
      accountId: () => 'owner',
      parentFamily: () => parent,
      autoSync: false,
    );
    await store.customSelect('SELECT 1').get();
  });
  tearDown(() async {
    await repository.dispose();
    await store.close();
  });

  Future<void> seed({bool child = false}) async {
    if (child) parent = null;
    for (final id in [draft, otherDraft]) {
      await repository.saveDraft(
        'child',
        'family',
        id,
        {
          if (child) 'requires_parent_review': true,
          'recognition': {
            'text': '2 + 2 = ?',
            'lines': [
              {'text': '2 + 2 = ?', 'confidence': null},
            ],
          },
          'editor': {
            'final_text': corrections['prompt'],
            'answers': ['4'],
            'subject': 'math',
            'ocr_corrections': corrections,
            'ocr_field_confirmations': corrections.keys.toList(),
          },
          'consent': true,
          'crop': [0.0, 0.0, 1.0, 1.0],
          'turns': 0,
        },
        fixture(),
        fixture(),
      );
    }
  }

  Future<Map<String, dynamic>> metadata({bool child = false}) async =>
      (await repository.draft(draft, 'family', childInput: child))['metadata']
          as Map<String, dynamic>;

  Future<void> settle(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pumpAndSettle();
      if (find.byType(AlertDialog).evaluate().isNotEmpty ||
          find.byType(ReviewQuestionEditor).evaluate().isNotEmpty ||
          find.textContaining('家长授权已到期').evaluate().isNotEmpty ||
          (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              tester
                  .widgetList<ButtonStyleButton>(
                    find.byWidgetPredicate(
                      (widget) => widget is ButtonStyleButton,
                    ),
                  )
                  .any((button) => button.onPressed != null))) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('Image operation did not finish');
  }

  Future<void> mount(WidgetTester tester, {bool child = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          questionMediaRepositoryProvider.overrideWithValue(repository),
          questionImageServiceProvider.overrideWithValue(images),
          parentFamilyIdProvider.overrideWith((ref) => parent),
          activeParentFamilyProvider.overrideWith(
            (ref) => ref.watch(parentFamilyIdProvider),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: QuestionOcrScreen(
            childId: 'child',
            familyId: 'family',
            draftId: draft,
            childInput: child,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await settle(tester);
  }

  Future<void> confirmIfPresent(WidgetTester tester) async {
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      await tester.tap(find.text('重新校对'));
      await settle(tester);
    }
  }

  testWidgets(
    'cancelling source changes preserves the entire correction draft',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await seed();
        final before = await metadata();
        await mount(tester);
        await tap(tester, '设备端识别 / 重试');
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('保留校对内容').hitTestable(), findsOneWidget);
        await tester.tap(find.text('保留校对内容'));
        await tester.pumpAndSettle();
        expect(images.processes, 0);
        expect(images.recognitions, 0);
        expect(await metadata(), before);
        expect(remote.saves, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    },
  );

  for (final child in [false, true]) {
    testWidgets(
      'new recognition replaces old text and field confirmations (${child ? 'child' : 'parent'})',
      (tester) async {
        await tester.runAsync(() async {
          await seed(child: child);
          await mount(tester, child: child);
          await tap(tester, '设备端识别 / 重试');
          await confirmIfPresent(tester);
          await tap(tester, '校对、配置答案并保存');
          expect(
            find.byType(ReviewQuestionEditor),
            findsOneWidget,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((w) => w.data)
                .join(' | '),
          );
          final editor = tester.widget<ReviewQuestionEditor>(
            find.byType(ReviewQuestionEditor),
          );
          expect(editor.initial, isNull);
          expect(editor.ocrResult!['text'], '6 + 3 = ?');
          await tester.scrollUntilVisible(
            find.widgetWithText(TextFormField, '题目'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            tester
                .widget<TextFormField>(find.widgetWithText(TextFormField, '题目'))
                .controller!
                .text,
            '6 + 3 = ?',
          );
          await tap(tester, '已核对题干的文字与字段归属');
          final current = await metadata(child: child);
          expect(current['editor']['answers'], ['']);
          expect(current['editor']['ocr_corrections']['options'], '');
          expect(current['editor']['ocr_field_confirmations'], ['prompt']);
          expect(current['recognition']['text'], '6 + 3 = ?');
          expect(remote.saves, 0);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  }

  testWidgets('changing the crop source clears only that image draft durably', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seed();
      final other = (await repository.draft(otherDraft, 'family'))['metadata'];
      await mount(tester);
      await tap(tester, '顺时针旋转90°');
      expect(find.byType(AlertDialog), findsOneWidget);
      await confirmIfPresent(tester);
      final current = await metadata();
      expect(current['turns'], 1);
      expect(current['editor'], isNull);
      expect(current['recognition'], isNull);
      expect((await repository.draft(otherDraft, 'family'))['metadata'], other);
      expect((await repository.draft(draft, 'family'))['original'], fixture());
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      await tap(tester, '转手工校对并保存图片');
      expect(
        tester
            .widget<ReviewQuestionEditor>(find.byType(ReviewQuestionEditor))
            .initial,
        isNull,
      );
      expect(remote.saves, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a failed new recognition retains previous corrections', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seed();
      final before = await metadata();
      images.fail = true;
      await mount(tester);
      await tap(tester, '设备端识别 / 重试');
      await confirmIfPresent(tester);
      final current = await metadata();
      expect(current['editor'], before['editor']);
      expect(current['recognition'], before['recognition']);
      expect(images.recognitions, 1);
      expect(remote.saves, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('PIN expiry while confirming cannot erase or reprocess a draft', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seed();
      final before = await metadata();
      await mount(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QuestionOcrScreen)),
      );
      await tap(tester, '设备端识别 / 重试');
      expect(find.byType(AlertDialog), findsOneWidget);
      parent = null;
      container.read(parentFamilyIdProvider.notifier).state = null;
      await confirmIfPresent(tester);
      expect(images.processes, 0);
      expect(images.recognitions, 0);
      parent = 'family';
      expect(await metadata(), before);
      expect(remote.saves, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/wrong_questions/domain/error_reason.dart';
import 'package:learning_planet/features/wrong_questions/domain/question_filter.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';

void main() {
  const original = <String, dynamic>{
    'final_text': '2+3=?',
    'subject': 'math',
    'answers': ['5'],
    'error_reason': '需要复核书写和记忆，暂不确定',
    'content_version': 7,
  };
  Future<void> tap(WidgetTester tester, String text) async {
    final target = errorReasonLabels.values.contains(text)
        ? find.widgetWithText(FilterChip, text)
        : find.text(text);
    final scroll = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(target, 200, scrollable: scroll);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  test(
    'legacy notes are not inferred as labels and explicit labels are searchable',
    () {
      expect(questionErrorReasons(original), isEmpty);
      final labeled = {
        ...original,
        'error_reason': '',
        'error_reason_tags': ['handwriting', 'memory'],
      };
      expect(matchesQuestion(labeled, keyword: '书写'), isTrue);
      expect(matchesQuestion(labeled, keyword: '记忆'), isTrue);
      expect(matchesQuestion(labeled, keyword: '概念'), isFalse);
      expect(
        matchesQuestion(labeled, keyword: '书写', subject: 'chinese'),
        isFalse,
      );
    },
  );

  testWidgets(
    'six labels survive draft callbacks and reopening without replacing existing notes',
    (tester) async {
      Map<String, dynamic>? saved, draft;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await Navigator.push<Map<String, dynamic>>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ReviewQuestionEditor(
                        pinyin: false,
                        initial: saved == null
                            ? original
                            : {...saved!, 'final_text': saved!['prompt']},
                        onDraftChanged: (value) => draft = value,
                      ),
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      for (final label in errorReasonLabels.values) {
        await tap(tester, label);
      }
      expect(draft?['error_reason_tags'], errorReasonLabels.keys.toList());
      expect(draft?['error_reason'], original['error_reason']);
      await tap(tester, '保存');
      expect(saved?['error_reason_tags'], errorReasonLabels.keys.toList());
      expect(saved?['error_reason'], original['error_reason']);
      expect(saved?['expected_version'], 7);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tap(tester, '记忆');
      expect(draft?['error_reason_tags'], isNot(contains('memory')));
      expect(draft?['error_reason_tags'], hasLength(5));
      await tap(tester, '保存');
      expect(saved?['error_reason'], original['error_reason']);
      expect(saved?['error_reason_tags'], hasLength(5));
    },
  );

  testWidgets(
    'all labels can be cleared at 360px with doubled text and saved as an empty list',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await Navigator.push<Map<String, dynamic>>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ReviewQuestionEditor(
                        pinyin: false,
                        initial: {
                          ...original,
                          'error_reason_tags': ['handwriting', 'memory'],
                        },
                      ),
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tap(tester, '书写');
      await tap(tester, '记忆');
      await tap(tester, '保存');
      expect(saved?['error_reason_tags'], isEmpty);
      expect(saved?['error_reason'], original['error_reason']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new AI practice review does not ask for an unobserved mistake or discard an editable reason',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await Navigator.push<Map<String, dynamic>>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ReviewQuestionEditor(
                        pinyin: false,
                        collectErrorReasons: false,
                        initial: {...original, 'ai_generated': true},
                      ),
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tap(tester, '保存');
      expect(saved, isNotNull);
      expect(saved!.containsKey('error_reason_tags'), isFalse);
      expect(saved!.containsKey('error_reason'), isFalse);
    },
  );
}

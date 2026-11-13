import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/wrong_questions/domain/ocr_fields.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';

Map<String, dynamic> ocrSample() => structureQuestionOcr({
  'text': '题目：2+2=?\nA.3\nB.4\n我的答案：3\n批注：再算一次',
  'lines': [
    {'text': '题目：2+2=?', 'confidence': 0.95},
    {'text': 'A.3', 'confidence': 0.92},
    {'text': 'B.4', 'confidence': 0.7},
    {'text': '我的答案：3', 'confidence': null},
    {'text': '批注：再算一次', 'confidence': 0.8},
  ],
});
const overallConfirmation = '我已逐项核对原图、所有题目文字（含低置信/未知置信内容）及标准答案';
Future<void> seeOcr(
  WidgetTester tester,
  Finder finder, {
  double delta = 240,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 50,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'partial OCR line arrays fall back to all raw text without dropping unknown content',
    () {
      final raw = structureQuestionOcr({
        'text': '题目：完整题目\n答案：4\n批注：漏行',
        'lines': [
          {'text': '题目：完整题目', 'confidence': 0.99},
        ],
      });
      expect(raw['field_line_source'], 'text');
      final fields = questionOcrFields(raw);
      expect(fields['answer']['text'], '4');
      expect(fields['annotation']['text'], '漏行');
      expect(fields['prompt']['confidence'], null);
    },
  );
  test(
    'explicit labels split four fields and preserve source text indices and weakest line confidence',
    () {
      final value = ocrSample(), fields = questionOcrFields(value);
      expect(fields['prompt']['text'], '2+2=?');
      expect(fields['options']['text'], 'A.3\nB.4');
      expect(fields['answer']['text'], '3');
      expect(fields['annotation']['text'], '再算一次');
      expect(fields['options']['confidence'], 0.7);
      expect(fields['answer']['confidence'], null);
      expect(fields['options']['line_indices'], [1, 2]);
      expect(value['text'], contains('我的答案：3'));
      expect(
        composeOcrQuestion({
          for (final key in ocrFieldLabels.keys) key: fields[key]['text'],
        }),
        '2+2=?\nA.3\nB.4',
      );
    },
  );
  test(
    'unlabelled and continuation lines are retained without inventing confidence or semantic answers',
    () {
      final fields = questionOcrFields({
        'text': '没有标签的题目\n继续题目\n答案：\n4\n批注：字迹不清\n再检查',
      });
      expect(fields['prompt']['text'], '没有标签的题目\n继续题目');
      expect(fields['answer']['text'], '4');
      expect(fields['annotation']['text'], '字迹不清\n再检查');
      expect(fields['prompt']['confidence'], null);
      expect(
        questionOcrFields({'text': '这句话中的答案：只是题干的一部分'})['answer']['text'],
        '',
      );
    },
  );
  test(
    'English labels full width options and invalid confidence remain conservative',
    () {
      final fields = questionOcrFields({
        'lines': [
          {'text': 'Question: Choose', 'confidence': 1.2},
          {'text': 'Ａ．cat', 'confidence': 0.9},
          {'text': 'Answer: A', 'confidence': double.nan},
          {'text': 'Comment: check again', 'confidence': 0.3},
        ],
      });
      expect(fields['prompt']['text'], 'Choose');
      expect(fields['options']['text'], 'Ａ．cat');
      expect(fields['answer']['confidence'], null);
      expect(fields['prompt']['confidence'], null);
    },
  );
  test(
    'stored field schema is reused without reclassifying original source',
    () {
      final raw = ocrSample();
      expect(questionOcrFields(raw), raw['fields']);
      expect(
        composeOcrQuestion({
          'prompt': '  题目  ',
          'options': '  A.1  ',
          'answer': 'private',
          'annotation': 'private',
        }),
        '题目\nA.1',
      );
    },
  );
  testWidgets(
    'parent corrects each recognized field and standard answer remains independently required',
    (tester) async {
      Map<String, dynamic>? result, draft;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('open'),
                onPressed: () async {
                  result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ReviewQuestionEditor(
                        pinyin: false,
                        fromImage: true,
                        ocrResult: ocrSample(),
                        onDraftChanged: (v) => draft = v,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final key in ocrFieldLabels.keys) {
        final confirm = find.text('已核对${ocrFieldLabels[key]}的文字与字段归属');
        await seeOcr(tester, confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
      }
      final answer = find.widgetWithText(TextFormField, '标准答案（一行一个可接受答案）');
      await seeOcr(tester, answer);
      expect(tester.widget<TextFormField>(answer).controller!.text, '');
      await tester.enterText(answer, '4');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await seeOcr(tester, find.text(overallConfirmation));
      await tester.tap(find.text(overallConfirmation));
      await tester.pumpAndSettle();
      await seeOcr(tester, find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result?['prompt'], '2+2=?\nA.3\nB.4');
      expect(result?['answers'], ['4']);
      expect(result?['ocr_corrections']['answer'], '3');
      expect(result?['ocr_corrections']['annotation'], '再算一次');
      expect(result?['ocr_field_confirmations'], ocrFieldLabels.keys.toList());
      expect(draft?['ocr_corrections']['options'], 'A.3\nB.4');
    },
  );
  testWidgets(
    'editing a confirmed field clears its confirmation and blocks final submission',
    (tester) async {
      final fields = {
        'prompt': '2+2=?',
        'options': 'A.3\nB.4',
        'answer': '3',
        'annotation': '再算一次',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: ReviewQuestionEditor(
            pinyin: false,
            fromImage: true,
            ocrResult: ocrSample(),
            initial: {
              'ocr_corrections': fields,
              'ocr_field_confirmations': ocrFieldLabels.keys.toList(),
              'answers': ['4'],
            },
          ),
        ),
      );
      final prompt = find.widgetWithText(TextFormField, '题目');
      await seeOcr(tester, prompt);
      await tester.enterText(prompt, '2+3=?');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await seeOcr(tester, find.text('已核对题干的文字与字段归属'));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '已核对题干的文字与字段归属'),
            )
            .value,
        false,
      );
      await seeOcr(tester, find.text(overallConfirmation));
      await tester.tap(find.text(overallConfirmation));
      await tester.pumpAndSettle();
      await seeOcr(tester, find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请逐字段核对'), findsOneWidget);
    },
  );
  testWidgets(
    'restored field corrections override raw OCR and keep cleared recognized fields reviewable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReviewQuestionEditor(
            pinyin: false,
            fromImage: true,
            childSubmission: true,
            ocrResult: ocrSample(),
            initial: {
              'final_text': 'legacy combined',
              'ocr_corrections': {
                'prompt': '校对题干',
                'options': '',
                'answer': '',
                'annotation': '校对批注',
              },
              'ocr_field_confirmations': ['prompt'],
            },
          ),
        ),
      );
      final prompt = find.widgetWithText(TextFormField, '题目');
      await seeOcr(tester, prompt);
      expect(tester.widget<TextFormField>(prompt).controller!.text, '校对题干');
      await seeOcr(tester, find.text('已核对图片中的作答的文字与字段归属'));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '已核对图片中的作答的文字与字段归属'),
            )
            .value,
        false,
      );
    },
  );
}

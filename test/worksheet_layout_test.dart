import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/worksheets/data/worksheet_repository.dart';
import 'package:learning_planet/features/worksheets/presentation/worksheet_pdf_screen.dart';
import 'package:learning_planet/features/worksheets/presentation/worksheet_screen.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'worksheet_test.dart' show FakeWorksheet, FakeOutput;

class LayoutWorksheets extends FakeWorksheet {
  @override
  Future<List<Map<String, dynamic>>> history(String child) async => [
    if (ready)
      {
        ...(await super.history(child)).single,
        'config': {'title': '二年级语文与数学错题复习（含拼音词语）'},
      },
  ];
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    LayoutWorksheets repository, {
    Size size = const Size(360, 800),
    bool preview = false,
    FakeOutput? output,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewPadding = size.width > size.height
        ? const FakeViewPadding(top: 24, left: 24, right: 48)
        : const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = tester.view.viewPadding;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeParentFamilyProvider.overrideWithValue('family'),
          worksheetRepositoryProvider.overrideWithValue(repository),
          worksheetOutputProvider.overrideWithValue(output ?? FakeOutput()),
          worksheetPreviewBuilderProvider.overrideWithValue(
            (_) => const ColoredBox(
              color: Colors.white,
              child: Center(child: Text('试卷预览')),
            ),
          ),
          reviewQuestionsProvider('child').overrideWith(
            (_) async => [
              {
                'id': 'q1',
                'final_text': '计算并解释：23 + 18 等于多少？',
                'subject': 'math',
                'review_kind': 'question',
              },
              {
                'id': 'q2',
                'final_text': '银行',
                'subject': 'chinese',
                'review_kind': 'pinyin',
              },
            ],
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: preview
              ? const WorksheetPdfScreen(id: 'job', familyId: 'family')
              : const WorksheetScreen(
                  childId: 'child',
                  familyId: 'family',
                  initialQuestionIds: ['q1', 'q2'],
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder getListScroll() => find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      )
      .first;

  Future<void> choose(WidgetTester tester, String current, String next) async {
    final field = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<String> && widget.value == current,
    );
    await tester.scrollUntilVisible(field, 150, scrollable: getListScroll());
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    final option = find.text(next).last;
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final size in [const Size(360, 800), const Size(800, 360)]) {
    testWidgets('large-text worksheet configuration remains usable at $size', (
      tester,
    ) async {
      final repository = LayoutWorksheets()..fail = true;
      await mount(tester, repository, size: size);
      expect(tester.takeException(), isNull);
      await choose(tester, 'portrait', '横向');
      await choose(tester, 'word_to_pinyin', '固定随机混合');
      await choose(tester, 'both', '四线三格');
      final answers = find.widgetWithText(CheckboxListTile, '包含独立答案页');
      await tester.scrollUntilVisible(
        answers,
        150,
        scrollable: getListScroll(),
      );
      await tester.pumpAndSettle();
      await tester.tap(answers);
      await tester.pumpAndSettle();
      final create = find.widgetWithText(FilledButton, '生成服务端 PDF');
      final rect = tester.getRect(create);
      expect(
        rect.bottom,
        lessThanOrEqualTo(size.height - tester.view.padding.bottom),
      );
      expect(rect.left, greaterThanOrEqualTo(tester.view.padding.left));
      expect(
        rect.right,
        lessThanOrEqualTo(size.width - tester.view.padding.right),
      );
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(repository.creates, hasLength(1));
      final config = repository.creates.single['config'] as Map;
      expect(config['orientation'], 'landscape');
      expect(config['pinyin_mode'], 'mixed');
      expect(config['grid'], 'four_lines');
      expect(config['include_answers'], true);
      expect(repository.creates.single['ids'], ['q1', 'q2']);
      expect(tester.takeException(), isNull);
      repository.fail = false;
      await tester.tap(find.text('重试同一份组卷'));
      await tester.pumpAndSettle();
      expect(repository.creates, hasLength(2));
      expect(repository.creates[0], repository.creates[1]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'large-text worksheet history allows preview and deletion at $size',
      (tester) async {
        final repository = LayoutWorksheets()..ready = true;
        await mount(tester, repository, size: size);
        await tester.tap(find.text('生成历史'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final preview = find.text('预览 / 导出');
        await tester.scrollUntilVisible(
          preview,
          120,
          scrollable: getListScroll(),
        );
        await tester.pumpAndSettle();
        await tester.tap(preview);
        await tester.pumpAndSettle();
        expect(find.text('试卷预览'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        final remove = find.text('永久删除 PDF');
        await tester.scrollUntilVisible(
          remove,
          120,
          scrollable: getListScroll(),
        );
        await tester.pumpAndSettle();
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(repository.deletes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'large-text PDF actions and preview respect safe areas at $size',
      (tester) async {
        final repository = LayoutWorksheets(), output = FakeOutput();
        await mount(
          tester,
          repository,
          size: size,
          preview: true,
          output: output,
        );
        expect(tester.takeException(), isNull);
        final preview = tester.getRect(find.byType(ColoredBox).last);
        expect(preview.left, greaterThanOrEqualTo(tester.view.padding.left));
        expect(
          preview.right,
          lessThanOrEqualTo(size.width - tester.view.padding.right),
        );
        expect(
          preview.bottom,
          lessThanOrEqualTo(size.height - tester.view.padding.bottom),
        );
        expect(preview.height, greaterThan(0));
        for (final label in ['下载保存', '打印', '分享文件']) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(output.exports, ['save', 'print', 'share']);
        expect(
          output.inputs.every((bytes) => identical(bytes, repository.bytes)),
          true,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

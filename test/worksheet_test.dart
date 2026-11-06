import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/worksheets/data/worksheet_repository.dart';
import 'package:learning_planet/features/worksheets/presentation/worksheet_screen.dart';
import 'package:learning_planet/features/worksheets/presentation/worksheet_pdf_screen.dart';

class FakeWorksheet implements WorksheetRepository {
  final bytes = Uint8List.fromList('%PDF-test-byte-identity'.codeUnits);
  final creates = <Map<String, dynamic>>[];
  bool fail = false, ready = false, changed = false;
  String? generated;
  final deletes = <String>[];
  @override
  Future<void> delete(String id, String key) async {
    deletes.add('$id:$key');
    if (fail) throw StateError('delete acknowledgement lost');
  }

  @override
  Future<void> create(
    String child,
    List<String> ids,
    Map<String, dynamic> config,
    String key,
  ) async {
    creates.add({
      'child': child,
      'ids': List.of(ids),
      'config': Map.of(config),
      'key': key,
    });
    if (fail) throw StateError('response lost');
  }

  @override
  Future<void> generate(String id) async => generated = id;
  @override
  Future<List<Map<String, dynamic>>> history(String child) async => ready
      ? [
          {
            'id': 'job',
            'config': {'title': '已生成卷'},
            'status': 'ready',
            'progress': 100,
            'pages': 2,
            'expires_at': '2099-01-01T00:00:00Z',
          },
        ]
      : [];
  @override
  Future<Uint8List> download(String id) async =>
      changed ? Uint8List.fromList('%PDF-changed'.codeUnits) : bytes;
}

class FakeOutput implements WorksheetOutput {
  final exports = <String>[];
  final inputs = <Uint8List>[];
  @override
  Future<bool> save(Uint8List bytes, String filename) async {
    exports.add('save');
    inputs.add(bytes);
    return true;
  }

  @override
  Future<bool> print(Uint8List bytes, String filename) async {
    exports.add('print');
    inputs.add(bytes);
    return true;
  }

  @override
  Future<bool> share(Uint8List bytes, String filename) async {
    exports.add('share');
    inputs.add(bytes);
    return true;
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeWorksheet repo, {
    bool parent = true,
    Widget? screen,
    FakeOutput? output,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeParentFamilyProvider.overrideWithValue(
            parent ? 'family' : null,
          ),
          worksheetRepositoryProvider.overrideWithValue(repo),
          worksheetOutputProvider.overrideWithValue(output ?? FakeOutput()),
          worksheetPreviewBuilderProvider.overrideWithValue(
            (bytes) => const Center(child: Text('原始字节预览')),
          ),
          reviewQuestionsProvider('child').overrideWith(
            (ref) async => [
              {
                'id': 'q1',
                'final_text': '数学题',
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
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home:
              screen ??
              const WorksheetScreen(
                childId: 'child',
                familyId: 'family',
                initialQuestionIds: ['q1', 'q2'],
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'PDF deletion requires confirmation and retains UUID after unknown acknowledgement',
    (tester) async {
      final repo = FakeWorksheet()
        ..ready = true
        ..fail = true;
      await mount(tester, repo);
      await tester.tap(find.text('生成历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久删除 PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.deletes, isEmpty);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('永久删除 PDF'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认永久删除'));
        await tester.pumpAndSettle();
      }
      expect(repo.deletes.length, 2);
      expect(repo.deletes.first, repo.deletes.last);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'A4 module and answer PDFs are inaccessible in ordinary child mode',
    (tester) async {
      final repo = FakeWorksheet();
      await mount(tester, repo, parent: false);
      expect(find.text('生成服务端 PDF'), findsNothing);
      expect(find.text('请先返回首页验证家长PIN'), findsOneWidget);
      expect(repo.creates, isEmpty);
    },
  );
  testWidgets(
    'mixed order can be changed and is frozen across an unknown-response retry',
    (tester) async {
      final repo = FakeWorksheet()..fail = true;
      await mount(tester, repo);
      await tester.scrollUntilVisible(
        find.text('已选 2/100 · 可拖动排序'),
        200,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.pumpAndSettle();
      final reorder = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      // onReorderItem normalizes indices on newer SDKs; legacy callback remains for the minimum SDK.
      // ignore: deprecated_member_use
      reorder.onReorder!(0, 2);
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成服务端 PDF'));
      await tester.pumpAndSettle();
      expect(repo.creates.single['ids'], ['q2', 'q1']);
      final config = repo.creates.single['config'] as Map;
      expect(config['margin_mm'], 12);
      expect(config['orientation'], 'portrait');
      expect(config['include_answers'], false);
      repo.fail = false;
      await tester.tap(find.text('重试同一份组卷'));
      await tester.pumpAndSettle();
      expect(repo.creates.length, 2);
      expect(repo.creates[0], repo.creates[1]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'PDF preview save print and share hand off the same byte object',
    (tester) async {
      final repo = FakeWorksheet(), output = FakeOutput();
      await mount(
        tester,
        repo,
        output: output,
        screen: const WorksheetPdfScreen(id: 'job', familyId: 'family'),
      );
      expect(find.text('原始字节预览'), findsOneWidget);
      for (final label in ['下载保存', '打印', '分享文件']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(output.exports, ['save', 'print', 'share']);
      expect(
        output.inputs.every((input) => identical(input, repo.bytes)),
        isTrue,
      );
    },
  );
  testWidgets('changed server bytes are never exported from a stale preview', (
    tester,
  ) async {
    final repo = FakeWorksheet(), output = FakeOutput();
    await mount(
      tester,
      repo,
      output: output,
      screen: const WorksheetPdfScreen(id: 'job', familyId: 'family'),
    );
    repo.changed = true;
    await tester.tap(find.text('打印'));
    await tester.pumpAndSettle();
    expect(output.exports, isEmpty);
    expect(find.textContaining('文件已改变'), findsOneWidget);
  });
  test(
    'download integrity rejects modified bytes incorrect size and non PDF data',
    () {
      final bytes = Uint8List.fromList('%PDF-fixture'.codeUnits),
          hash = sha256
              .convert(Uint8List.fromList('%PDF-fixture'.codeUnits))
              .toString();
      verifyWorksheetBytes(bytes, bytes.length, hash);
      expect(
        () => verifyWorksheetBytes(bytes, bytes.length + 1, hash),
        throwsStateError,
      );
      expect(
        () => verifyWorksheetBytes(bytes, bytes.length, '0' * 64),
        throwsStateError,
      );
      expect(
        () => verifyWorksheetBytes(
          Uint8List(12),
          12,
          sha256.convert(Uint8List(12)).toString(),
        ),
        throwsStateError,
      );
    },
  );
}

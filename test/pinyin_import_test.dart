import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/pinyin_import_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/pinyin_import.dart';
import 'package:learning_planet/features/wrong_questions/presentation/pinyin_import_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_hub_screen.dart';
import 'review_module_test.dart' show FakeReviewRepository;

class ImportRepository implements PinyinImportRepository {
  final calls = <({String key, List<Map<String, dynamic>> entries})>[];
  Object? fail;
  @override
  Future<Map<String, dynamic>> importWords(
    String childId,
    String requestId,
    List<Map<String, dynamic>> entries,
  ) async {
    calls.add((
      key: requestId,
      entries: jsonDecode(jsonEncode(entries)).cast<Map<String, dynamic>>(),
    ));
    if (fail case final error?) {
      fail = null;
      throw error;
    }
    return {
      'created': [
        for (var i = 0; i < entries.length; i++)
          {'row': i + 1, 'question_id': 'word-$i'},
      ],
      'skipped': <Map<String, dynamic>>[],
    };
  }
}

class ConvertRepository extends FakeReviewRepository {
  Map<String, dynamic>? saved;
  String? savedId;
  @override
  Future<List<Map<String, dynamic>>> questions(String childId) async => [
    {
      'id': 'question',
      'child_id': childId,
      'final_text': '请给银行标注读音',
      'subject': 'chinese',
      'review_kind': 'question',
      'mastery_status': 'practicing',
      'wrong_count': 1,
      'review_attempts': 2,
    },
  ];
  @override
  Future<Map<String, dynamic>> editor(String questionId) async => {
    'final_text': '请给银行标注读音',
    'answers': ['yín háng'],
    'content_version': 9,
    'subject': 'chinese',
  };
  @override
  Future<void> save(
    String childId,
    Map<String, dynamic> config, {
    String? questionId,
  }) async {
    saved = config;
    savedId = questionId;
  }
}

void main() {
  test(
    'CSV and TSV imports preserve quoted commas newlines escaped quotes BOM and blank pinyin for candidate editing',
    () {
      final rows = parsePinyinImport(
        '\uFEFF词语,拼音,语境,知识点\r\n银行,yín háng,"我去银行,存钱",多音字\r\n妈妈,,"妈妈说""好""\n又回家了",轻声\r\n',
      );
      expect(rows.length, 2);
      expect(rows[0].context, '我去银行,存钱');
      expect(rows[1].reading, '');
      expect(rows[1].context, '妈妈说"好"\n又回家了');
      expect(
        parsePinyinImport('词语\t拼音\t语境\n绿叶\tlü4 ye4\t绿叶发芽').single.word,
        '绿叶',
      );
      expect(parsePinyinImport(pinyinImportTemplate).length, 2);
    },
  );
  test(
    'malformed or oversized import files are rejected without truncating rows or guessing columns',
    () {
      for (final source in [
        '',
        '银行,yin2 hang2,银行',
        '词语,拼音,语境\n银行,yin2 hang2',
        '词语,拼音,语境\n银行,yin2 hang2,"未闭合',
        '词语,拼音,语境\n银行,yin2 hang2,"银行"意外字符',
        '词语,拼音,语境\n${List.filled(101, '银行,yin2 hang2,银行').join('\n')}',
        '词语,拼音,语境\n银行,yin2 hang2,${'字' * 90000}',
      ]) {
        expect(() => parsePinyinImport(source), throwsFormatException);
      }
    },
  );
  test(
    'local candidates retain neutral tones and polyphone choices and expose one/bu sandhi as an explicit option',
    () {
      final bank = suggestPinyin('银行', '我去银行存钱');
      expect(bank.reading, 'yín háng');
      expect(bank.alternatives['行'], containsAll(['háng', 'xíng']));
      expect(suggestPinyin('妈妈', '妈妈回家了').reading, 'mā ma');
      expect(suggestPinyin('不是', '这不是书', toneSandhi: true).reading, 'bú shì');
      expect(suggestPinyin('不是', '这不是书').reading, 'bù shì');
      expect(suggestPinyin('一天', '一天过去了', toneSandhi: true).reading, 'yì tiān');
      expect(() => suggestPinyin('abc', '语境'), throwsFormatException);
      expect(() => suggestPinyin('字' * 81, ''), throwsFormatException);
    },
  );
  test(
    'import repository sends only confirmed structured entries with the caller request UUID',
    () async {
      Map<String, dynamic>? payload;
      final client = SupabaseClient(
        'https://example.test',
        'key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/import_pinyin_words');
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            '{"created":[],"skipped":[]}',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final entry = parsePinyinImport(
        pinyinImportTemplate,
      ).first.toConfig(confirmed: true);
      await SupabasePinyinImportRepository(
        client,
      ).importWords('child', 'request', [entry]);
      expect(payload, {
        'target_child_id': 'child',
        'request_id': 'request',
        'entries': [entry],
      });
    },
  );
  Future<void> show(
    WidgetTester tester,
    Widget page, {
    ImportRepository? importer,
    FakeReviewRepository? review,
    Future<String?> Function()? file,
    bool parent = true,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeParentFamilyProvider.overrideWithValue(
            parent ? 'family' : null,
          ),
          pinyinImportRepositoryProvider.overrideWithValue(
            importer ?? ImportRepository(),
          ),
          reviewRepositoryProvider.overrideWithValue(
            review ?? FakeReviewRepository(),
          ),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          if (file != null) pinyinFileReaderProvider.overrideWithValue(file),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => page),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(
    WidgetTester tester,
    Finder target, {
    double delta = 180,
  }) async {
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> load(
    WidgetTester tester,
    ImportRepository repository, {
    String source = '词语,拼音,语境\n银行,yín háng,我去银行存钱',
  }) async {
    await show(
      tester,
      const PinyinImportScreen(childId: 'child', familyId: 'family'),
      importer: repository,
      file: () async => source,
    );
    await tap(tester, find.text('选择词库文件'));
  }

  Finder field(String label) => find.widgetWithText(TextField, label);
  testWidgets(
    'import preview requires every row confirmation and changed reading invalidates previous approval',
    (tester) async {
      final repository = ImportRepository();
      await load(tester, repository);
      await tap(tester, find.text('确认导入已核对词语'));
      expect(repository.calls, isEmpty);
      expect(find.textContaining('第1条尚未完整核对'), findsOneWidget);
      await tap(tester, find.text('我已按语境核对本条读音'), delta: -180);
      await tester.ensureVisible(field('确认后的拼音'));
      await tester.enterText(field('确认后的拼音'), 'yin2 hang2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, find.text('确认导入已核对词语'));
      expect(repository.calls, isEmpty);
      await tap(tester, find.text('我已按语境核对本条读音'), delta: -180);
      await tap(tester, find.text('确认导入已核对词语'));
      expect(repository.calls.single.entries.single['answers'], ['yin2 hang2']);
      expect(find.text('已新增 1 条，跳过 0 条'), findsOneWidget);
      expect(find.text('用新增词语生成练习卷'), findsOneWidget);
    },
  );
  testWidgets(
    'every imported row must be confirmed even when earlier cards scroll offscreen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = ImportRepository();
      await load(tester, repository, source: pinyinImportTemplate);
      Future<void> confirm(int index) async {
        final card = find.byKey(ValueKey('pinyin-row-$index'));
        await tester.scrollUntilVisible(
          card,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        final checkbox = find.descendant(
          of: card,
          matching: find.byType(CheckboxListTile),
        );
        await tester.ensureVisible(checkbox);
        await tester.pumpAndSettle();
        await tester.tap(checkbox);
        await tester.pumpAndSettle();
      }

      await confirm(0);
      await tap(tester, find.text('确认导入已核对词语'));
      expect(repository.calls, isEmpty);
      expect(find.textContaining('第2条尚未完整核对'), findsOneWidget);
      await confirm(1);
      await tap(tester, find.text('确认导入已核对词语'));
      expect(repository.calls.single.entries.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown import acknowledgement freezes rows and retries the same UUID and payload',
    (tester) async {
      final repository = ImportRepository()
        ..fail = const SocketException('reply lost');
      await load(tester, repository);
      await tap(tester, find.text('我已按语境核对本条读音'));
      await tap(tester, find.text('确认导入已核对词语'));
      expect(find.textContaining('导入结果尚未确认'), findsOneWidget);
      await tap(tester, find.text('重试同一批导入'));
      expect(repository.calls.length, 2);
      expect(repository.calls[0].key, repository.calls[1].key);
      expect(repository.calls[0].entries, repository.calls[1].entries);
    },
  );
  testWidgets(
    'a known server rejection preserves the editable draft for correction',
    (tester) async {
      final repository = ImportRepository()
        ..fail = const PostgrestException(message: '读音无效', code: 'P0001');
      await load(tester, repository);
      await tap(tester, find.text('我已按语境核对本条读音'));
      await tap(tester, find.text('确认导入已核对词语'));
      expect(find.textContaining('导入未通过'), findsOneWidget);
      await tester.ensureVisible(field('确认后的拼音'));
      await tester.enterText(field('确认后的拼音'), 'yin2 hang2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, find.text('我已按语境核对本条读音'));
      await tap(tester, find.text('确认导入已核对词语'));
      expect(repository.calls.last.entries.single['answers'], ['yin2 hang2']);
    },
  );
  testWidgets('file cancellation and unauthorised entry never submit data', (
    tester,
  ) async {
    final repository = ImportRepository();
    await show(
      tester,
      const PinyinImportScreen(childId: 'child', familyId: 'family'),
      importer: repository,
      file: () async => null,
    );
    await tap(tester, find.text('选择词库文件'));
    expect(find.text('解析并逐条核对'), findsOneWidget);
    expect(repository.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await show(
      tester,
      const PinyinImportScreen(childId: 'child', familyId: 'family'),
      importer: repository,
      parent: false,
    );
    expect(find.textContaining('重新验证 PIN'), findsOneWidget);
    expect(find.text('选择词库文件'), findsNothing);
  });
  testWidgets(
    'candidate generation works in a narrow editor and changing context revokes confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(
        tester,
        const ReviewQuestionEditor(
          pinyin: true,
          initial: {'final_text': '银行', 'pronunciation_context': '我去银行存钱'},
        ),
        scale: 1.2,
      );
      await tap(tester, find.text('填入本地候选读音'));
      expect(find.textContaining('多音字候选：'), findsOneWidget);
      await tap(tester, find.text('我已根据语境确认标准读音，不接受未经确认的多音字猜测'));
      final contextField = find.widgetWithText(
        TextFormField,
        '语境/例句（多音字必须明确语境）',
      );
      await tester.scrollUntilVisible(
        contextField,
        -180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
      await tester.enterText(contextField, '银行关门了');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, find.text('保存'));
      expect(find.text('请先确认语境及标准读音'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a Chinese wrong question converts through its existing ID and version after explicit reading review',
    (tester) async {
      final repository = ConvertRepository();
      await show(
        tester,
        const ReviewHubScreen(childId: 'child', familyId: 'family'),
        review: repository,
      );
      await tester.scrollUntilVisible(
        find.byTooltip('转为拼音词条'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('转为拼音词条'));
      await tester.pumpAndSettle();
      expect(find.textContaining('将当前语文错题转为拼音词条'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, '词语/句中词语'),
        '银行',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, find.text('填入本地候选读音'));
      await tap(tester, find.text('我已根据语境确认标准读音，不接受未经确认的多音字猜测'));
      await tap(tester, find.text('保存'));
      expect(repository.savedId, 'question');
      expect(repository.saved!['expected_version'], 9);
      expect(repository.saved!['kind'], 'pinyin');
      expect(repository.saved!['answers'], ['yín háng']);
    },
  );
}

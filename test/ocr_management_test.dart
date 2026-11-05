import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/question_filter.dart';
import 'package:learning_planet/features/wrong_questions/presentation/question_ocr_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';

Uint8List fixture() =>
    Uint8List.fromList(image.encodeJpg(image.Image(width: 60, height: 40)));

class FakeImages implements QuestionImageService {
  int picks = 0, recognitions = 0;
  bool fail = false;
  bool recoverImage = false;
  @override
  Future<Uint8List?> pick(bool camera) async {
    picks++;
    return fixture();
  }

  @override
  Future<List<Uint8List>> recover() async => recoverImage ? [fixture()] : [];

  @override
  Future<List<Uint8List>> pickMany() async => [fixture()];

  @override
  Future<Uint8List> process(
    Uint8List original,
    int turns,
    List<double> crop, {
    bool enhance = false,
  }) async => fixture();
  @override
  Future<Map<String, dynamic>> recognize(Uint8List processed) async {
    recognitions++;
    if (fail) throw StateError('未识别到文字');
    return {
      'text': '2+2=?',
      'lines': [
        {'text': '2+2=?', 'confidence': null},
      ],
    };
  }
}

class FakeMedia implements QuestionMediaRepository {
  int saves = 0;
  bool fail = false;
  final ids = <String>[];
  Map<String, dynamic>? config, recognition;
  @override
  Future<void> save(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
  ) async {
    saves++;
    ids.add(draftId);
    this.config = config;
    this.recognition = recognition;
    if (fail) throw StateError('连接失败');
  }

  @override
  Future<void> archiveMany(
    String childId,
    List<String> ids,
    bool enabled,
  ) async {}
  @override
  Future<String> imageUrl(String path) async => 'https://example.test/private';
  @override
  Future<Map<String, dynamic>?> provenance(String questionId) async => null;
}

void main() {
  test(
    'question list reads all pages instead of truncating at API row limit',
    () async {
      var requests = 0;
      final transport = MockClient((request) async {
        requests++;
        final length = requests == 1 ? 500 : 1;
        return http.Response(
          jsonEncode(
            List.generate(
              length,
              (i) => {
                'id': '$requests-$i',
                'final_text': '题目',
                'child_id': 'child',
              },
            ),
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        httpClient: transport,
      );
      try {
        final rows = await SupabaseReviewRepository(client).questions('child');
        expect(rows.length, 501);
        expect(requests, 2);
      } finally {
        await client.dispose();
      }
    },
  );
  test(
    'filter combines subject mastery archive and case insensitive knowledge text',
    () {
      final row = {
        'subject': 'math',
        'mastery_status': 'unmastered',
        'archived': false,
        'final_text': '2+2=?',
        'knowledge_point': 'Addition',
      };
      expect(
        matchesQuestion(
          row,
          keyword: ' add ',
          subject: 'math',
          mastery: 'unmastered',
          archive: 'active',
        ),
        isTrue,
      );
      expect(matchesQuestion(row, subject: 'chinese'), isFalse);
      expect(matchesQuestion(row, mastery: 'mastered'), isFalse);
      expect(matchesQuestion(row, archive: 'archived'), isFalse);
      expect(
        matchesQuestion({...row, 'archived': true}, archive: 'active'),
        isFalse,
      );
      expect(
        matchesQuestion({
          'final_text': '银行',
          'pronunciation_context': '我去存钱',
        }, keyword: '存钱'),
        isTrue,
      );
    },
  );
  test(
    'image processing rotates and crops without altering original bytes',
    () {
      final original = fixture(), copy = Uint8List.fromList(fixture());
      final result = processQuestionImage({
        'bytes': original,
        'turns': 1,
        'crop': [0.0, 0.0, 0.5, 1.0],
      });
      final decoded = image.decodeJpg(result)!;
      expect(decoded.width, 20);
      expect(decoded.height, 60);
      expect(original, copy);
      expect(isQuestionImage(result), isTrue);
    },
  );
  test('transparent PNG keeps readable ink when flattened to JPEG', () {
    final source = image.Image(width: 120, height: 80, numChannels: 4);
    image.fillRect(
      source,
      x1: 20,
      y1: 20,
      x2: 45,
      y2: 60,
      color: image.ColorRgba8(0, 0, 0, 255),
    );
    image.fillRect(
      source,
      x1: 70,
      y1: 20,
      x2: 100,
      y2: 60,
      color: image.ColorRgba8(255, 0, 0, 128),
      alphaBlend: false,
    );
    final original = Uint8List.fromList(image.encodePng(source));
    final before = Uint8List.fromList(original);
    final processed = processQuestionImage({
      'bytes': original,
      'turns': 0,
      'crop': [0.0, 0.0, 1.0, 1.0],
    });
    final decoded = image.decodeJpg(processed)!;
    final background = decoded.getPixel(5, 5);
    expect([
      background.r,
      background.g,
      background.b,
    ], everyElement(greaterThan(245)));
    final ink = decoded.getPixel(30, 40);
    expect([ink.r, ink.g, ink.b], everyElement(lessThan(10)));
    final translucent = decoded.getPixel(85, 40);
    expect(translucent.r, greaterThan(240));
    expect(translucent.g, inInclusiveRange(115, 140));
    expect(translucent.b, inInclusiveRange(115, 140));
    expect(original, before);
    expect(image.decodePng(original)!.getPixel(5, 5).a, 0);
  });
  test(
    'image processing rejects invalid headers oversized input and empty crop',
    () {
      expect(isQuestionImage(Uint8List(8)), isFalse);
      expect(
        () => processQuestionImage({
          'bytes': Uint8List(8),
          'turns': 0,
          'crop': [0.0, 0.0, 1.0, 1.0],
        }),
        throwsArgumentError,
      );
      expect(
        () => processQuestionImage({
          'bytes': Uint8List(10485761),
          'turns': 0,
          'crop': [0.0, 0.0, 1.0, 1.0],
        }),
        throwsArgumentError,
      );
      expect(
        () => processQuestionImage({
          'bytes': fixture(),
          'turns': 0,
          'crop': [0.5, 0.0, 0.5, 1.0],
        }),
        throwsArgumentError,
      );
    },
  );
  Future<void> mount(
    WidgetTester tester,
    FakeImages images,
    FakeMedia media, {
    bool parent = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          questionImageServiceProvider.overrideWithValue(images),
          questionMediaRepositoryProvider.overrideWithValue(media),
          activeParentFamilyProvider.overrideWithValue(
            parent ? 'family' : null,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const QuestionOcrScreen(childId: 'child', familyId: 'family'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> see(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> correct(WidgetTester tester, {bool prompt = false}) async {
    if (tester
            .widget<ReviewQuestionEditor>(find.byType(ReviewQuestionEditor))
            .ocrResult !=
        null) {
      await see(tester, '已核对题干的文字与字段归属');
      await tester.tap(find.text('已核对题干的文字与字段归属'));
    }
    if (prompt) {
      await see(tester, '题目');
      await tester.enterText(
        find.widgetWithText(TextFormField, '题目'),
        '手工补录题目',
      );
    }
    const label = '标准答案（一行一个可接受答案）';
    await see(tester, label);
    await tester.enterText(find.widgetWithText(TextFormField, label), '4');
    tester.testTextInput.hide();
    await tester.pump();
    const confirmation = '我已逐项核对原图、所有题目文字（含低置信/未知置信内容）及标准答案';
    await see(tester, confirmation);
    await tester.tap(find.text(confirmation));
    await tester.pumpAndSettle();
    await see(tester, '保存');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
  }

  testWidgets('OCR camera and gallery cannot be used without family PIN', (
    tester,
  ) async {
    final images = FakeImages();
    await mount(tester, images, FakeMedia(), parent: false);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '相册'))
          .onPressed,
      isNull,
    );
    expect(images.picks, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'OCR requires private-storage consent and does not save before correction',
    (tester) async {
      final images = FakeImages(), media = FakeMedia();
      await mount(tester, images, media);
      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      await see(tester, '设备端识别 / 重试');
      await tester.tap(find.text('设备端识别 / 重试'));
      await tester.pumpAndSettle();
      expect(images.recognitions, 1);
      expect(media.saves, 0);
      await see(tester, '校对、配置答案并保存');
      await tester.tap(find.text('校对、配置答案并保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请同意将图片保存'), findsOneWidget);
      expect(find.byType(ReviewQuestionEditor), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('recovering another image resets enhancement and consent', (
    tester,
  ) async {
    final images = FakeImages()..recoverImage = true;
    await mount(tester, images, FakeMedia());
    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();
    const enhancement = '增强对比度（可选，请预览确认不影响细节）';
    const consent = '同意将原图、处理图与识别结果保存至本家庭 Supabase 私有错题库（原图可能含拍摄元数据）';
    await see(tester, enhancement);
    await tester.tap(find.text(enhancement));
    await tester.pumpAndSettle();
    await see(tester, consent);
    await tester.tap(find.text(consent));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('恢复中断的图片选择（Android）'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('恢复中断的图片选择（Android）'));
    await tester.pumpAndSettle();
    await see(tester, enhancement);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, enhancement),
          )
          .value,
      isFalse,
    );
    await see(tester, consent);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, consent),
          )
          .value,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'failed OCR can fall back to confirmed manual entry retaining both images',
    (tester) async {
      final images = FakeImages()..fail = true, media = FakeMedia();
      await mount(tester, images, media);
      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      await see(tester, '设备端识别 / 重试');
      await tester.tap(find.text('设备端识别 / 重试'));
      await tester.pumpAndSettle();
      const consent = '同意将原图、处理图与识别结果保存至本家庭 Supabase 私有错题库（原图可能含拍摄元数据）';
      await see(tester, consent);
      await tester.tap(find.text(consent));
      await tester.pumpAndSettle();
      await see(tester, '转手工校对并保存图片');
      await tester.tap(find.text('转手工校对并保存图片'));
      await tester.pumpAndSettle();
      await correct(tester, prompt: true);
      expect(media.saves, 1);
      expect(media.recognition, isNull);
      expect(media.config!['prompt'], '手工补录题目');
      expect(media.config!['ocr_confirmed'], isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'lost save response retries the same OCR draft and confirmed configuration',
    (tester) async {
      final images = FakeImages(), media = FakeMedia()..fail = true;
      await mount(tester, images, media);
      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      await see(tester, '设备端识别 / 重试');
      await tester.tap(find.text('设备端识别 / 重试'));
      await tester.pumpAndSettle();
      const consent = '同意将原图、处理图与识别结果保存至本家庭 Supabase 私有错题库（原图可能含拍摄元数据）';
      await see(tester, consent);
      await tester.tap(find.text(consent));
      await tester.pumpAndSettle();
      await see(tester, '校对、配置答案并保存');
      await tester.tap(find.text('校对、配置答案并保存'));
      await tester.pumpAndSettle();
      await correct(tester);
      expect(media.saves, 1);
      media.fail = false;
      await see(tester, '重试保存已校对的错题');
      await tester.tap(find.text('重试保存已校对的错题'));
      await tester.pumpAndSettle();
      expect(media.saves, 2);
      expect(media.ids.toSet().length, 1);
      expect(media.recognition!['text'], '2+2=?');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'OCR editor refuses missing confirmation and keeps original OCR separate',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const ReviewQuestionEditor(
            pinyin: false,
            fromImage: true,
            initial: {
              'final_text': 'corrected',
              'answers': ['4'],
            },
            ocrResult: {
              'text': 'raw OCR',
              'lines': [
                {'text': 'raw OCR', 'confidence': null},
              ],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await see(tester, '保存');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请核对题目及低置信'), findsOneWidget);
      expect(find.byType(ReviewQuestionEditor), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';

// Synthetic print only: no camera, album, family account, or cloud calls.
Future<Uint8List> _printedFixture({required bool transparent}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  if (!transparent) canvas.drawColor(Colors.white, ui.BlendMode.src);
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(fontSize: 72, textDirection: ui.TextDirection.ltr),
  )..pushStyle(ui.TextStyle(color: Colors.black));
  builder.addText('学习星球\n语文 数学\n12345');
  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: 900));
  canvas.drawParagraph(paragraph, const ui.Offset(60, 45));
  final picture = recorder.endRecording();
  final raster = await picture.toImage(1000, 400);
  try {
    final data = await raster.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    raster.dispose();
    picture.dispose();
    paragraph.dispose();
  }
}

Future<Set<String>> _ocrFiles(Directory directory) async => {
  await for (final entry in directory.list(followLinks: false))
    if (entry is File &&
        RegExp(r'[/\\]question-ocr-[0-9a-f-]+\.jpg$').hasMatch(entry.path))
      entry.path,
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bundled native Chinese OCR, preprocessing and cleanup', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('原生 OCR 本机验证'))),
      ),
    );
    await tester.pumpAndSettle();
    final report = <String, dynamic>{
      'backend': 'none',
      'fixtures': 'synthetic-printed-chinese-and-digits',
      'mode': kProfileMode ? 'profile' : 'debug',
      'platform': Platform.operatingSystem,
      'device': const String.fromEnvironment(
        'TEST_DEVICE_LABEL',
        defaultValue: 'unspecified',
      ),
      'qualifies_for_prd_acceptance': false,
      'scope':
          'Real bundled ML Kit recognition; excludes camera/gallery permissions, real textbooks, Huawei and iPhone acceptance.',
      'cases': <Map<String, dynamic>>[],
    };
    binding.reportData = report;
    final service = DeviceQuestionImageService();
    final temporary = await getTemporaryDirectory();
    final before = await _ocrFiles(temporary);

    Future<void> verify(
      Uint8List original,
      String name, {
      int turns = 0,
      bool enhance = false,
    }) async {
      final processed = await service.process(original, turns, [
        0.03,
        0.03,
        0.97,
        0.97,
      ], enhance: enhance);
      final watch = Stopwatch()..start();
      final result = await service.recognize(processed);
      watch.stop();
      final text = (result['text'] as String).replaceAll(RegExp(r'\s+'), '');
      expect(text, contains('学习星球'));
      expect(text, contains('语文'));
      expect(text, contains('数学'));
      expect(text, contains('12345'));
      expect(result['provider'], 'mlkit-device-chinese');
      final decoded = image.decodeJpg(processed)!;
      final lines = (result['lines'] as List).cast<Map<String, dynamic>>();
      expect(lines, isNotEmpty);
      for (final line in lines) {
        final box = (line['box'] as List).cast<num>();
        expect(box.length, 4);
        expect(box.every((value) => value.isFinite), isTrue);
        expect(box[0], inInclusiveRange(0, decoded.width));
        expect(box[1], inInclusiveRange(0, decoded.height));
        expect(box[2], inInclusiveRange(box[0] + 1, decoded.width));
        expect(box[3], inInclusiveRange(box[1] + 1, decoded.height));
        final confidence = line['confidence'] as num?;
        if (confidence != null) expect(confidence, inInclusiveRange(0, 1));
      }
      expect(await _ocrFiles(temporary), before);
      (report['cases'] as List).add({
        'name': name,
        'expected_text_found': true,
        'recognition_ms': watch.elapsedMilliseconds,
        'line_count': lines.length,
        'temporary_files_restored': true,
      });
    }

    final opaque = await _printedFixture(transparent: false);
    await verify(opaque, 'printed_opaque');
    final transparent = await _printedFixture(transparent: true);
    await verify(transparent, 'printed_transparent');
    final upsideDown = Uint8List.fromList(
      image.encodePng(image.copyRotate(image.decodePng(opaque)!, angle: 180)),
    );
    await verify(upsideDown, 'rotate_crop_enhance', turns: 2, enhance: true);

    final blank = image.Image(width: 320, height: 160);
    image.fill(blank, color: image.ColorRgb8(255, 255, 255));
    await expectLater(
      service.recognize(Uint8List.fromList(image.encodeJpg(blank))),
      throwsStateError,
    );
    expect(await _ocrFiles(temporary), before);
    report['blank_image_rejected_and_cleaned'] = true;
    await verify(opaque, 'recognizer_recovers_after_empty_result');
    report['completed'] = true;
  }, timeout: const Timeout(Duration(minutes: 2)));
}

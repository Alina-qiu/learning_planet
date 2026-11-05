import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/data_management/data/child_export_repository.dart';
import 'package:learning_planet/features/data_management/domain/child_export.dart';
import 'package:learning_planet/features/data_management/presentation/child_export_screen.dart';

Map<String, dynamic> manifest(String id, {int count = 2}) => {
  'id': id,
  'child_id': 'child',
  'family_id': 'family',
  'schema_version': 1,
  'created_at': '2026-11-04T08:00:00Z',
  'expires_at': '2026-11-04T08:15:00Z',
  'sections': [
    {
      'name': 'tasks',
      'columns': ['id', 'title', 'amount', 'tags'],
      'count': count,
    },
    {
      'name': 'image_index',
      'columns': ['draft_id', 'path'],
      'count': 0,
    },
  ],
};
final sampleRows = <Map<String, dynamic>>[
  {
    'id': '1',
    'title': '中文,"声调 lǜ"\r\n下一行',
    'amount': -5,
    'tags': ['阅读', '数学'],
  },
  {
    'id': '2',
    'title': '=HYPERLINK("https://invalid.test")',
    'amount': 3,
    'tags': [],
  },
];

class FakeExport implements ChildExportRepository {
  int previews = 0, prepares = 0, pages = 0, validations = 0;
  bool corrupt = false, revoked = false;
  final closed = <String>[];
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> preview(String childId) async {
    previews++;
    return {
      'child_id': childId,
      'counts': {'tasks': 2, 'image_index': 0},
    };
  }

  @override
  Future<Map<String, dynamic>> prepare(
    String childId,
    String requestId,
    Map<String, dynamic> counts,
  ) async {
    prepares++;
    return _manifest(requestId);
  }

  @override
  Future<Map<String, dynamic>> manifest(String id) async {
    validations++;
    if (revoked) throw StateError('snapshot revoked');
    return _manifest(id);
  }

  Map<String, dynamic> _manifest(String id) => {
    'id': id,
    'child_id': 'child',
    'family_id': 'family',
    'schema_version': 1,
    'created_at': '2026-11-04T08:00:00Z',
    'expires_at': '2026-11-04T08:15:00Z',
    'sections': [
      {
        'name': 'tasks',
        'columns': ['id', 'title', 'amount', 'tags'],
        'count': 2,
      },
      {
        'name': 'image_index',
        'columns': ['draft_id', 'path'],
        'count': 0,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> page(
    String id,
    String section,
    int after,
  ) async {
    pages++;
    if (gate != null) await gate!.future;
    return {
      'section': section,
      'rows': [sampleRows[after]],
      'next_ordinal': corrupt ? after : after + 1,
      'total': 2,
      'done': after == 1,
    };
  }

  @override
  Future<void> close(String id) async {
    closed.add(id);
  }
}

class FakeExportOutput implements ChildExportOutput {
  Uint8List? bytes;
  String? filename;
  @override
  Future<bool> save(Uint8List bytes, String filename) async {
    this.bytes = bytes;
    this.filename = filename;
    return true;
  }
}

void main() {
  const temporaryFiles = MethodChannel(
    'learning_planet/export_temporary_files',
  );
  testWidgets(
    'iOS stages are purged before and after save, cancellation and failure',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temporaryFiles,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          temporaryFiles,
          null,
        );
      });
      for (final outcome in ['saved', 'cancelled', 'failed']) {
        calls.clear();
        final output = NativeChildExportOutput(
          saveFile: (bytes, filename) async {
            calls.add('save');
            if (outcome == 'failed') throw StateError('native error');
            return outcome == 'saved';
          },
        );
        if (outcome == 'failed') {
          await expectLater(
            output.save(Uint8List(0), 'export.zip'),
            throwsStateError,
          );
        } else {
          expect(
            await output.save(Uint8List(0), 'export.zip'),
            outcome == 'saved',
          );
        }
        expect(calls, ['purge', 'save', 'purge']);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  testWidgets(
    'failed iOS cleanup prevents new output and releases the save guard',
    (tester) async {
      var saves = 0, purges = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temporaryFiles,
        (call) async {
          purges++;
          throw PlatformException(code: 'export_cleanup_failed');
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          temporaryFiles,
          null,
        );
      });
      final output = NativeChildExportOutput(
        saveFile: (bytes, filename) async {
          saves++;
          return true;
        },
      );
      await expectLater(
        output.save(Uint8List(0), 'export.zip'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        output.save(Uint8List(0), 'export.zip'),
        throwsA(isA<PlatformException>()),
      );
      expect(purges, 2);
      expect(saves, 0);
      purges = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temporaryFiles,
        (call) async {
          if (++purges == 2) {
            throw PlatformException(code: 'export_cleanup_failed');
          }
          return null;
        },
      );
      await expectLater(
        output.save(Uint8List(0), 'export.zip'),
        throwsStateError,
      );
      expect(purges, 2);
      expect(saves, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  testWidgets('only one native save can run at a time', (tester) async {
    final gate = Completer<bool>();
    var saves = 0;
    final output = NativeChildExportOutput(
      saveFile: (bytes, filename) {
        saves++;
        return gate.future;
      },
    );
    final first = output.save(Uint8List(0), 'first.zip');
    await expectLater(
      output.save(Uint8List(0), 'second.zip'),
      throwsStateError,
    );
    expect(saves, 1);
    gate.complete(true);
    expect(await first, true);
  });
  test(
    'ZIP contains valid UTF8 CSV, lossless JSON, empty headers and verified file hashes',
    () {
      final bytes = buildChildExportZip({
        'manifest': manifest('job'),
        'records': {
          'tasks': sampleRows,
          'image_index': <Map<String, dynamic>>[],
        },
      });
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      String contents(String name) => utf8.decode(zip.findFile(name)!.content);
      expect(zip.findFile('tasks.csv')!.content.take(3), [0xef, 0xbb, 0xbf]);
      expect(zip.findFile('image_index.csv')!.content.take(3), [
        0xef,
        0xbb,
        0xbf,
      ]);
      expect(zip.files.map((file) => file.name).toSet(), {
        'tasks.csv',
        'image_index.csv',
        'data.json',
        'README.txt',
        'manifest.json',
      });
      expect(
        contents('tasks.csv'),
        startsWith('"id","title","amount","tags"\r\n'),
      );
      expect(contents('tasks.csv'), contains('中文,""声调 lǜ""\r\n下一行'));
      expect(contents('tasks.csv'), contains('"-5"'));
      expect(contents('tasks.csv'), contains('"\'=HYPERLINK('));
      expect(contents('image_index.csv'), '"draft_id","path"\r\n');
      final raw = jsonDecode(contents('data.json')) as Map;
      expect((raw['records'] as Map)['tasks'], sampleRows);
      final metadata = jsonDecode(contents('manifest.json')) as Map;
      final hashes = metadata['files_sha256'] as Map;
      for (final file in zip.files.where((f) => f.name != 'manifest.json')) {
        expect(sha256.convert(file.content).toString(), hashes[file.name]);
      }
    },
  );
  test(
    'CSV formula guards affect text only and archive rejects unsafe section paths or missing rows',
    () {
      for (final value in [
        '=1+1',
        '+CMD',
        '-CMD',
        '@SUM(A1)',
        '  =1',
        '\ttext',
        '\rtext',
      ]) {
        expect(exportCsvCell(value), startsWith('"\''));
      }
      expect(exportCsvCell(-10), '"-10"');
      final unsafe = manifest('job')
        ..['sections'] = [
          {
            'name': '../private',
            'columns': ['id'],
            'count': 0,
          },
        ];
      expect(
        () => buildChildExportZip({
          'manifest': unsafe,
          'records': {'../private': []},
        }),
        throwsFormatException,
      );
      expect(
        () => buildChildExportZip({
          'manifest': manifest('job'),
          'records': {'tasks': [], 'image_index': []},
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'pagination collects every row once and rejects non-advancing or truncated pages',
    () async {
      final repository = FakeExport();
      final progress = <int>[];
      final result = await collectChildExport(
        repository,
        manifest('job'),
        checkAccess: () {},
        onProgress: (done, total) {
          expect(total, 2);
          progress.add(done);
        },
      );
      expect((result['records'] as Map)['tasks'], sampleRows);
      expect(progress, [1, 2]);
      repository.corrupt = true;
      await expectLater(
        collectChildExport(
          repository,
          manifest('job'),
          checkAccess: () {},
          onProgress: (_, _) {},
        ),
        throwsFormatException,
      );
    },
  );

  Future<ProviderContainer> mount(
    WidgetTester tester,
    FakeExport repository,
    FakeExportOutput output, {
    bool parent = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          childExportRepositoryProvider.overrideWithValue(repository),
          childExportOutputProvider.overrideWithValue(output),
          parentModeProvider.overrideWith((ref) => parent),
          parentFamilyIdProvider.overrideWith((ref) => 'family'),
          parentAuthorizedUntilProvider.overrideWith(
            (ref) => DateTime.now().add(const Duration(hours: 1)),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const ChildExportScreen(
            childId: 'child',
            familyId: 'family',
            nickname: '小星',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(ChildExportScreen)),
    );
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(find.text('生成并保存 ZIP'));
    await tester.tap(find.text('生成并保存 ZIP'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '导出孩子数据');
    await tester.tap(find.text('确认导出'));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester, FakeExport repository) async {
    // compute() is a real isolate; allow real time while it serializes the sample.
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && repository.closed.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('child mode never requests export data', (tester) async {
    final repository = FakeExport();
    await mount(tester, repository, FakeExportOutput(), parent: false);
    expect(repository.previews, 0);
    expect(find.text('生成并保存 ZIP'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'secondary confirmation is required before snapshot creation and save revalidates server',
    (tester) async {
      final repository = FakeExport(), output = FakeExportOutput();
      await mount(tester, repository, output);
      await tester.ensureVisible(find.text('生成并保存 ZIP'));
      await tester.tap(find.text('生成并保存 ZIP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认导出'));
      await tester.pumpAndSettle();
      expect(repository.prepares, 0);
      expect(output.bytes, isNull);
      await tester.enterText(find.byType(TextField), '导出孩子数据');
      await tester.tap(find.text('确认导出'));
      await tester.pump();
      await finish(tester, repository);
      expect(output.filename, startsWith('learning-planet-child-'));
      expect(output.bytes, isNotNull);
      expect(repository.validations, 1);
      expect(repository.closed.length, 1);
      expect(
        ZipDecoder().decodeBytes(output.bytes!).findFile('image_index.csv'),
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'authorization loss during a page request discards late data and closes the snapshot',
    (tester) async {
      final repository = FakeExport()..gate = Completer(),
          output = FakeExportOutput();
      final container = await mount(tester, repository, output);
      await confirm(tester);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pump();
      repository.gate!.complete();
      await tester.pumpAndSettle();
      expect(output.bytes, isNull);
      expect(repository.closed.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'source cleanup before saving prevents output even after all pages downloaded',
    (tester) async {
      final repository = FakeExport()..revoked = true,
          output = FakeExportOutput();
      await mount(tester, repository, output);
      await confirm(tester);
      await finish(tester, repository);
      expect(output.bytes, isNull);
      expect(repository.closed.length, 1);
      expect(find.textContaining('导出未完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'cancel during download closes the snapshot without saving a partial archive',
    (tester) async {
      final repository = FakeExport()..gate = Completer(),
          output = FakeExportOutput();
      await mount(tester, repository, output);
      await confirm(tester);
      await tester.tap(find.text('取消导出'));
      await tester.pump();
      repository.gate!.complete();
      await tester.pumpAndSettle();
      expect(repository.closed.length, 1);
      expect(output.bytes, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

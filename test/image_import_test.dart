import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/image_drafts_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/question_ocr_screen.dart';
import 'ocr_management_test.dart' show fixture, FakeImages, FakeMedia;

class PickerStub extends Fake implements ImagePicker {
  List<XFile> files = [];
  LostDataResponse lost = LostDataResponse.empty();
  int? limit;
  bool? metadata;
  int recoveries = 0;
  Object? error;
  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async {
    this.limit = limit;
    metadata = requestFullMetadata;
    if (error != null) throw error!;
    return files;
  }

  @override
  Future<LostDataResponse> retrieveLostData() async {
    recoveries++;
    return lost;
  }
}

class CountedFile extends Fake implements XFile {
  CountedFile(this.size, this.bytes);
  final int size;
  final Uint8List bytes;
  int reads = 0;
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    return bytes;
  }
}

class BatchImages extends FakeImages {
  List<Uint8List> files = [fixture(), fixture()];
  Completer<List<Uint8List>>? pending;
  @override
  Future<List<Uint8List>> pickMany() async =>
      pending == null ? files : await pending!.future;
  @override
  Future<List<Uint8List>> recover() async => files;
}

class ExpiringImportStore extends OfflineStore {
  ExpiringImportStore() : super(NativeDatabase.memory());
  VoidCallback? afterInsert;
  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) async {
    await super.customStatement(statement, args);
    if (statement.startsWith('INSERT INTO image_drafts(')) afterInsert?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('native image selection adapter', () {
    late PickerStub picker;
    late DeviceQuestionImageService service;
    setUp(() {
      picker = PickerStub();
      service = DeviceQuestionImageService(picker: picker);
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test(
      'multi-select keeps all original bytes and requests bounded minimal metadata',
      () async {
        final first = fixture(), second = Uint8List.fromList(fixture());
        picker.files = [XFile.fromData(first), XFile.fromData(second)];
        final result = await service.pickMany();
        expect(result, [first, second]);
        expect(picker.limit, 10);
        expect(picker.metadata, isFalse);
        picker.files = [];
        expect(await service.pickMany(), isEmpty);
      },
    );

    test(
      'Android recovery returns every file and supports a legacy single result',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        picker.lost = LostDataResponse(
          files: [XFile.fromData(fixture()), XFile.fromData(fixture())],
        );
        expect(await service.recover(), hasLength(2));
        picker.lost = LostDataResponse(file: XFile.fromData(fixture()));
        expect(await service.recover(), hasLength(1));
        picker.lost = LostDataResponse.empty();
        expect(await service.recover(), isEmpty);
        picker.lost = LostDataResponse(
          exception: PlatformException(code: 'permission_denied'),
        );
        await expectLater(service.recover(), throwsA(isA<PlatformException>()));
        final calls = picker.recoveries;
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect(await service.recover(), isEmpty);
        expect(picker.recoveries, calls);
      },
    );

    test(
      'platform limit violations and oversized files are rejected before reading',
      () async {
        final file = CountedFile(10485761, fixture());
        picker.files = [for (var i = 0; i < 11; i++) file];
        await expectLater(service.pickMany(), throwsStateError);
        expect(file.reads, 0);
        picker.files = [file];
        await expectLater(service.pickMany(), throwsStateError);
        expect(file.reads, 0);
        picker.error = PlatformException(code: 'photo_access_denied');
        await expectLater(
          service.pickMany(),
          throwsA(isA<PlatformException>()),
        );
      },
    );

    test(
      'invalid or over-dimensioned later images fail the entire selection',
      () async {
        picker.files = [
          XFile.fromData(fixture()),
          XFile.fromData(Uint8List(8)),
        ];
        await expectLater(service.pickMany(), throwsStateError);
        final huge = Uint8List.fromList(fixture());
        final sof = Iterable<int>.generate(
          huge.length - 1,
        ).firstWhere((i) => huge[i] == 255 && huge[i + 1] == 192);
        huge[sof + 5] = huge[sof + 7] = 0x17;
        huge[sof + 6] = huge[sof + 8] =
            0x70; // 6000 x 6000, no pixel allocation.
        picker.files = [XFile.fromData(huge)];
        await expectLater(service.pickMany(), throwsStateError);
        picker.files = [
          XFile.fromData(Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10])),
        ];
        await expectLater(service.pickMany(), throwsStateError);
      },
    );
  });

  group('durable scoped image imports', () {
    late OfflineStore store;
    late OfflineQuestionMediaRepository repo;
    late FakeMedia remote;
    String? owner, family;
    void connect() {
      repo = OfflineQuestionMediaRepository(
        store: store,
        live: remote,
        accountId: () => owner,
        parentFamily: () => family,
        autoSync: false,
      );
    }

    setUp(() async {
      store = OfflineStore(NativeDatabase.memory());
      remote = FakeMedia();
      owner = 'parent';
      family = 'family';
      connect();
      await store.customSelect('SELECT 1').get();
    });
    tearDown(() async {
      await repo.dispose();
      await store.close();
    });

    test(
      'imports are independent unconsented drafts, isolated by owner and child',
      () async {
        final bytes = fixture();
        final ids = await repo.importImages(
          'child',
          'family',
          () async => [bytes, bytes],
        );
        expect(ids.toSet(), hasLength(2));
        final rows = await repo.drafts('child', 'family');
        expect(rows.map((r) => r['import_index']), [1, 2]);
        for (final id in ids) {
          final row = await repo.draft(id, 'family');
          expect(row['original'], bytes);
          expect(row['processed'], isNull);
          expect(row['stage'], 'editing');
          expect(row['metadata']['consent'], false);
          expect(row['metadata']['config'], isNull);
          expect(row['metadata']['recognition'], isNull);
        }
        expect(await repo.drafts('other-child', 'family'), isEmpty);
        await repo.synchronize();
        expect(remote.saves, 0);
        owner = 'other-parent';
        expect(await repo.drafts('child', 'family'), isEmpty);
        expect(
          await repo.importImages('child', 'family', () async => []),
          isEmpty,
        );
      },
    );

    test(
      'a quota failure rolls back all new images while preserving prior drafts',
      () async {
        for (var i = 0; i < 49; i++) {
          await repo.saveDraft(
            'child',
            'family',
            'existing-$i',
            {},
            fixture(),
            null,
          );
        }
        await expectLater(
          repo.importImages(
            'child',
            'family',
            () async => [fixture(), fixture()],
          ),
          throwsStateError,
        );
        final rows = await repo.drafts('child', 'family');
        expect(rows, hasLength(49));
        expect(
          rows.every(
            (row) => (row['draft_id'] as String).startsWith('existing-'),
          ),
          true,
        );
        expect(rows.every((row) => row['import_index'] == null), true);
      },
    );

    test(
      'account or PIN changes while the picker is open reject all returned images',
      () async {
        for (final change in [
          () => owner = 'other-parent',
          () => family = null,
        ]) {
          owner = 'parent';
          family = 'family';
          final selected = Completer<List<Uint8List>>();
          final importing = repo.importImages(
            'child',
            'family',
            () => selected.future,
          );
          final rejected = expectLater(importing, throwsStateError);
          change();
          selected.complete([fixture(), fixture()]);
          await rejected;
        }
        expect(await store.imageDrafts('parent'), isEmpty);
        expect(await store.imageDrafts('other-parent'), isEmpty);
      },
    );

    test(
      'privacy cleanup and invalid batches cannot repopulate local images',
      () async {
        final selected = Completer<List<Uint8List>>();
        final importing = repo.importImages(
          'child',
          'family',
          () => selected.future,
        );
        final rejected = expectLater(importing, throwsStateError);
        await store.removeAccountData('parent', 'deleting');
        selected.complete([fixture()]);
        await rejected;
        owner = 'fresh-parent';
        await expectLater(
          repo.importImages(
            'child',
            'family',
            () async => [fixture(), Uint8List(8)],
          ),
          throwsStateError,
        );
        await expectLater(
          repo.importImages(
            'child',
            'family',
            () async => List.generate(11, (_) => fixture()),
          ),
          throwsStateError,
        );
        expect(await repo.drafts('child', 'family'), isEmpty);
      },
    );

    test(
      'all imported originals and order survive a database restart',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'learning-planet-import-',
        );
        final file = File('${directory.path}/cache.sqlite');
        try {
          await repo.dispose();
          await store.close();
          store = OfflineStore(NativeDatabase(file));
          connect();
          final ids = await repo.importImages(
            'child',
            'family',
            () async => [fixture(), fixture()],
          );
          await repo.dispose();
          await store.close();
          store = OfflineStore(NativeDatabase(file));
          connect();
          expect(
            (await repo.drafts('child', 'family')).map((r) => r['draft_id']),
            ids,
          );
          expect((await repo.draft(ids.last, 'family'))['original'], fixture());
          expect(
            (await repo.draft(ids.first, 'family'))['metadata']['consent'],
            false,
          );
        } finally {
          await repo.dispose();
          await store.close();
          store = OfflineStore(NativeDatabase.memory());
          connect();
          await directory.delete(recursive: true);
        }
      },
    );

    Future<void> mount(
      WidgetTester tester,
      BatchImages images, {
      bool ocr = false,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            questionMediaRepositoryProvider.overrideWithValue(repo),
            questionImageServiceProvider.overrideWithValue(images),
            activeParentFamilyProvider.overrideWith(
              (ref) => ref.watch(parentFamilyIdProvider),
            ),
            parentFamilyIdProvider.overrideWith((ref) => 'family'),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: ocr
                ? const QuestionOcrScreen(childId: 'child', familyId: 'family')
                : const ImageDraftsScreen(childId: 'child', familyId: 'family'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    test(
      'PIN expiry after the first SQL insert rolls back the entire batch',
      () async {
        await repo.dispose();
        await store.close();
        final expiring = ExpiringImportStore();
        store = expiring;
        connect();
        expiring.afterInsert = () => family = null;
        await expectLater(
          repo.importImages(
            'child',
            'family',
            () async => [fixture(), fixture()],
          ),
          throwsStateError,
        );
        expect(await store.imageDrafts('parent'), isEmpty);
        expect(remote.saves, 0);
      },
    );

    testWidgets(
      'a delayed native selection is rejected after the page loses parent authorization',
      (tester) async {
        await tester.runAsync(() async {
          final images = BatchImages()..pending = Completer<List<Uint8List>>();
          await mount(tester, images);
          await tester.tap(find.text('多图导入（每次最多10张）'));
          await tester.pump();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ImageDraftsScreen)),
          );
          container.read(parentFamilyIdProvider.notifier).state = null;
          images.pending!.complete([fixture(), fixture()]);
          await tester.pumpAndSettle();
          expect(await store.imageDrafts('parent'), isEmpty);
          expect(find.textContaining('本次未导入'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );

    testWidgets(
      'OCR multi-import opens the durable list and keeps per-image consent separate',
      (tester) async {
        await tester.runAsync(() async {
          await mount(tester, BatchImages(), ocr: true);
          await tester.tap(find.text('多图导入（每次最多10张）'));
          await tester.pumpAndSettle();
          expect(find.byType(ImageDraftsScreen), findsOneWidget);
          expect(await repo.drafts('child', 'family'), hasLength(2));
          await tester.scrollUntilVisible(
            find.text('继续校对').first,
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('继续校对').first);
          await tester.pumpAndSettle();
          expect(find.text('导入图片 · 第1/2张'), findsOneWidget);
          final consent = find.textContaining('同意将原图、处理图');
          await tester.scrollUntilVisible(
            consent,
            180,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            tester
                .widget<CheckboxListTile>(
                  find.ancestor(
                    of: consent,
                    matching: find.byType(CheckboxListTile),
                  ),
                )
                .value,
            false,
          );
          final consentBox = find.descendant(
            of: find.ancestor(
              of: consent,
              matching: find.byType(CheckboxListTile),
            ),
            matching: find.byType(Checkbox),
          );
          await tester.ensureVisible(consentBox);
          await tester.pumpAndSettle();
          await tester.tap(consentBox);
          await tester.pumpAndSettle();
          final rows = await repo.drafts('child', 'family');
          expect(rows.first['import_index'], 1);
          expect(
            (await repo.draft(
              rows.first['draft_id'] as String,
              'family',
            ))['metadata']['consent'],
            true,
          );
          expect(
            (await repo.draft(
              rows.last['draft_id'] as String,
              'family',
            ))['metadata']['consent'],
            false,
          );
          expect(remote.saves, 0);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );

    testWidgets(
      'recovery imports every file and large text keeps batch controls usable',
      (tester) async {
        await tester.runAsync(() async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await mount(tester, BatchImages());
          final recover = find.text('恢复中断的图片选择（Android）');
          await tester.scrollUntilVisible(recover, 200);
          await tester.tap(recover);
          await tester.pumpAndSettle();
          expect(await repo.drafts('child', 'family'), hasLength(2));
          await tester.scrollUntilVisible(find.text('批量导入 · 第2/2张'), 200);
          expect(tester.takeException(), isNull);
          expect(remote.saves, 0);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  });
}

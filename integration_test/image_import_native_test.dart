import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/core/security/device_secrets.dart';
import 'package:learning_planet/core/security/encrypted_database.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/image_drafts_screen.dart';
import 'support/gallery_fixture.dart';

class _FixtureSecrets implements DeviceSecrets {
  _FixtureSecrets(this.prefix);
  final String prefix;
  final DeviceSecrets native = const NativeDeviceSecrets();
  @override
  Future<String?> read(String key) => native.read('$prefix.$key');
  @override
  Future<void> write(String key, String value) =>
      native.write('$prefix.$key', value);
  @override
  Future<void> delete(String key) => native.delete('$prefix.$key');
}

class _NoCloud implements QuestionMediaRepository {
  int uploads = 0;
  @override
  Future<void> save(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
  ) async {
    uploads++;
    throw StateError('Unconfirmed imports must never upload');
  }

  @override
  Future<String> imageUrl(String path) async =>
      throw StateError('No cloud in fixture');
  @override
  Future<Map<String, dynamic>?> provenance(String questionId) async => null;
  @override
  Future<void> archiveMany(
    String childId,
    List<String> ids,
    bool enabled,
  ) async => throw StateError('No cloud in fixture');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native multi-selection, cancellation and encrypted draft recovery',
    (tester) async {
      const runId = String.fromEnvironment('TEST_IMAGE_IMPORT_RUN');
      expect(runId, matches(RegExp(r'^[0-9a-f-]{36}$')));
      final directory = await getApplicationSupportDirectory();
      final root = await Directory(
        '${directory.path}/integration-fixtures',
      ).create(recursive: true);
      final run = await root.createTemp('gallery-');
      final secrets = _FixtureSecrets('integration.gallery.$runId');
      final cloud = _NoCloud();
      OfflineStore? store;
      OfflineQuestionMediaRepository? repository;
      final report = <String, dynamic>{
        'run': runId,
        'backend': 'none',
        'fixtures': 'synthetic-native-gallery',
        'mode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'device': const String.fromEnvironment('TEST_DEVICE_LABEL'),
        'completed': false,
        'qualifies_for_prd_acceptance': false,
        'scope':
            'Native gallery multi-selection/cancel and encrypted drafts; excludes camera, process-death recovery, Huawei and iPhone acceptance.',
      };
      binding.reportData = report;
      try {
        store = OfflineStore(await EncryptedDatabase.open(run, secrets));
        repository = OfflineQuestionMediaRepository(
          store: store,
          live: cloud,
          accountId: () => 'integration-parent',
          parentFamily: () => 'integration-family',
          autoSync: false,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              questionMediaRepositoryProvider.overrideWithValue(repository),
              activeParentFamilyProvider.overrideWithValue(
                'integration-family',
              ),
            ],
            child: const MaterialApp(
              home: ImageDraftsScreen(
                childId: 'integration-child',
                familyId: 'integration-family',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final importButton = find.text('多图导入（每次最多10张）');
        debugPrint('LP_IMAGE_IMPORT_SELECT_TWO');
        await tester.tap(importButton);
        final watch = Stopwatch()..start();
        var rows = <Map<String, dynamic>>[];
        while (watch.elapsed < const Duration(seconds: 90)) {
          await tester.pump(const Duration(milliseconds: 100));
          rows = await store.imageDrafts('integration-parent');
          if (rows.length == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(rows, hasLength(2));
        await tester.pumpAndSettle();
        final ids = rows.map((r) => r['draft_id'] as String).toList();
        final hashes = <String>[];
        for (final id in ids) {
          final row = (await store.imageDraft('integration-parent', id))!;
          hashes.add(sha256.convert(row['original'] as Uint8List).toString());
          expect(row['metadata']['consent'], false);
          expect(row['stage'], 'editing');
          expect(row['processed'], isNull);
        }
        expect(
          hashes,
          unorderedEquals([
            for (final index in [1, 2])
              sha256.convert(galleryFixture(index)).toString(),
          ]),
        );
        report['native_selected_originals_match'] = true;
        debugPrint('LP_IMAGE_IMPORT_CANCEL');
        await tester.tap(importButton);
        // The operator/test controller cancels the real system picker. Wait for
        // the button to become enabled after the native cancellation completes.
        await tester.pump(const Duration(milliseconds: 200));
        final cancelWatch = Stopwatch()..start();
        while (tester
                    .widget<OutlinedButton>(
                      find.widgetWithText(OutlinedButton, '多图导入（每次最多10张）'),
                    )
                    .onPressed ==
                null &&
            cancelWatch.elapsed < const Duration(seconds: 60)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '多图导入（每次最多10张）'),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          (await store.imageDrafts(
            'integration-parent',
          )).map((r) => r['draft_id']),
          ids,
        );
        report['native_cancel_preserves_drafts'] = true;
        expect(find.textContaining('草稿操作失败'), findsNothing);
        await repository.synchronize();
        expect(cloud.uploads, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await repository.dispose();
        repository = null;
        await store.close();
        store = null;
        final disk = await File(
          '${run.path}/${EncryptedDatabase.fileName}',
        ).readAsBytes();
        expect(latin1.decode(disk).startsWith('SQLite format 3'), false);
        store = OfflineStore(await EncryptedDatabase.open(run, secrets));
        expect(
          (await store.imageDrafts(
            'integration-parent',
          )).map((r) => r['draft_id']),
          ids,
        );
        for (var index = 0; index < ids.length; index++) {
          final row = (await store.imageDraft(
            'integration-parent',
            ids[index],
          ))!;
          expect(
            sha256.convert(row['original'] as Uint8List).toString(),
            hashes[index],
          );
          expect(row['metadata']['consent'], false);
        }
        report['encrypted_reopen_preserves_all_originals'] = true;
        report['unconfirmed_upload_count'] = cloud.uploads;
        report['completed'] = true;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await repository?.dispose();
        await store?.close();
        await secrets.delete(EncryptedDatabase.keyName);
        await run.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/question_ocr_screen.dart';
import 'ocr_management_test.dart' show FakeImages, FakeMedia, fixture;

class InterruptedImages extends FakeImages {
  final pickStarted = Completer<void>(), processStarted = Completer<void>();
  Completer<Uint8List?>? selection;
  Completer<Uint8List>? processing;
  bool processingFails = false;
  bool? camera;
  int processes = 0;

  @override
  Future<Uint8List?> pick(bool camera) async {
    this.camera = camera;
    if (!pickStarted.isCompleted) pickStarted.complete();
    return selection == null ? fixture() : await selection!.future;
  }

  @override
  Future<Uint8List> process(
    Uint8List original,
    int turns,
    List<double> crop, {
    bool enhance = false,
  }) async {
    processes++;
    if (!processStarted.isCompleted) processStarted.complete();
    if (processingFails) throw StateError('图片处理失败');
    return processing == null ? fixture() : await processing!.future;
  }
}

class RefusingImageStore extends OfflineStore {
  RefusingImageStore() : super(NativeDatabase.memory());
  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) {
    if (statement.startsWith('INSERT INTO image_drafts(')) {
      throw StateError('本机空间不足');
    }
    return super.customStatement(statement, args);
  }
}

class PausingImageStore extends OfflineStore {
  PausingImageStore(File file) : super(NativeDatabase(file));
  bool pauseNextWrite = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) async {
    if (pauseNextWrite && statement.startsWith('INSERT INTO image_drafts(')) {
      pauseNextWrite = false;
      entered.complete();
      await release.future;
    }
    return super.customStatement(statement, args);
  }
}

void main() {
  late Directory directory;
  late File databaseFile;
  late OfflineStore store;
  late OfflineQuestionMediaRepository repository;
  late InterruptedImages images;
  late FakeMedia remote;
  String? owner, parent;

  void connect() {
    repository = OfflineQuestionMediaRepository(
      store: store,
      live: remote,
      accountId: () => owner,
      parentFamily: () => parent,
      autoSync: false,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('learning-planet-pick-');
    databaseFile = File('${directory.path}/drafts.sqlite');
    store = OfflineStore(NativeDatabase(databaseFile));
    images = InterruptedImages();
    remote = FakeMedia();
    owner = 'original-owner';
    parent = 'family';
    connect();
    await store.customSelect('SELECT 1').get();
  });
  tearDown(() async {
    if (images.selection != null && !images.selection!.isCompleted) {
      images.selection!.complete(null);
    }
    if (images.processing != null && !images.processing!.isCompleted) {
      images.processing!.complete(fixture());
    }
    await repository.dispose();
    await store.close();
    // Only the freshly created synthetic fixture directory is removed.
    if (!directory.absolute.path.startsWith(
      Directory.systemTemp.absolute.path,
    )) {
      throw StateError('Unexpected fixture directory');
    }
    await directory.delete(recursive: true);
  });

  Future<void> idle(WidgetTester tester) async {
    for (var i = 0; i < 150; i++) {
      await tester.pumpAndSettle();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('Image operation did not finish');
  }

  Future<void> mount(
    WidgetTester tester, {
    bool child = false,
    String? draft,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          questionMediaRepositoryProvider.overrideWithValue(repository),
          questionImageServiceProvider.overrideWithValue(images),
          parentFamilyIdProvider.overrideWith((ref) => parent),
          activeParentFamilyProvider.overrideWith(
            (ref) => ref.watch(parentFamilyIdProvider),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: QuestionOcrScreen(
            childId: 'child',
            familyId: 'family',
            childInput: child,
            draftId: draft,
          ),
        ),
      ),
    );
    await idle(tester);
  }

  Future<void> reopenDatabase() async {
    await repository.dispose();
    await store.close();
    store = OfflineStore(NativeDatabase(databaseFile));
    connect();
  }

  for (final child in [false, true]) {
    testWidgets(
      'original survives closing the processing page and database (${child ? 'child gallery' : 'parent camera'})',
      (tester) async {
        await tester.runAsync(() async {
          if (child) parent = null;
          images.processing = Completer<Uint8List>();
          await mount(tester, child: child);
          await tester.tap(find.text(child ? '相册' : '拍照'));
          await images.processStarted.future.timeout(
            const Duration(seconds: 5),
          );
          final rows = await store.imageDrafts('original-owner');
          expect(rows, hasLength(1));
          final id = rows.single['draft_id'] as String;
          final pending = await store.imageDraft('original-owner', id);
          expect(pending!['original'], fixture());
          expect(pending['processed'], isNull);
          expect(pending['stage'], 'editing');
          expect(pending['metadata']['consent'], false);
          expect(pending['metadata']['requires_parent_review'] == true, child);
          expect(images.camera, !child);
          await tester.pumpWidget(const SizedBox());
          images.processing!.complete(fixture());
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await reopenDatabase();
          final recovered = await store.imageDraft('original-owner', id);
          expect(recovered!['original'], fixture());
          expect(recovered['processed'], isNull);
          expect(recovered['metadata']['config'], isNull);
          images.processing = null;
          await mount(tester, child: child, draft: id);
          await tester.scrollUntilVisible(
            find.text('预览处理图'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(find.text('预览处理图').hitTestable(), findsOneWidget);
          await tester.tap(find.text('预览处理图'));
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
            if ((await store.imageDraft('original-owner', id))!['processed'] !=
                null) {
              break;
            }
          }
          expect(
            (await store.imageDraft('original-owner', id))!['processed'],
            fixture(),
          );
          expect(
            (await store.imageDrafts('original-owner')).single['draft_id'],
            id,
          );
          expect(remote.saves, 0);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  }

  testWidgets(
    'processing failure still leaves the selected original for retry',
    (tester) async {
      await tester.runAsync(() async {
        images.processingFails = true;
        await mount(tester);
        await tester.tap(find.text('相册'));
        await idle(tester);
        final rows = await store.imageDrafts('original-owner');
        expect(rows, hasLength(1));
        final id = rows.single['draft_id'] as String;
        await tester.pumpWidget(const SizedBox());
        await reopenDatabase();
        final row = await store.imageDraft('original-owner', id);
        expect(row!['original'], fixture());
        expect(row['processed'], isNull);
        expect(row['metadata']['consent'], false);
        expect(remote.saves, 0);
      });
    },
  );

  for (final phase in ['picker', 'processor']) {
    testWidgets('a parent account change rejects the previous $phase result', (
      tester,
    ) async {
      await tester.runAsync(() async {
        if (phase == 'picker') {
          images.selection = Completer<Uint8List?>();
        } else {
          images.processing = Completer<Uint8List>();
        }
        await mount(tester);
        await tester.tap(find.text('相册'));
        await (phase == 'picker' ? images.pickStarted : images.processStarted)
            .future
            .timeout(const Duration(seconds: 5));
        owner = 'different-owner';
        // The new account is a parent in the same family; PIN alone is not an identity boundary.
        if (phase == 'picker') {
          images.selection!.complete(fixture());
        } else {
          images.processing!.complete(fixture());
        }
        await idle(tester);
        expect(await store.imageDrafts('different-owner'), isEmpty);
        expect(images.processes, phase == 'picker' ? 0 : 1);
        if (phase == 'processor') {
          final rows = await store.imageDrafts('original-owner');
          expect(rows, hasLength(1));
          expect(
            (await store.imageDraft(
              'original-owner',
              rows.single['draft_id'] as String,
            ))!['processed'],
            isNull,
          );
        }
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(remote.saves, 0);
        await tester.pumpWidget(const SizedBox());
      });
    });
  }

  testWidgets(
    'privacy cleanup during selection prevents late image processing',
    (tester) async {
      await tester.runAsync(() async {
        images.selection = Completer<Uint8List?>();
        await mount(tester);
        await tester.tap(find.text('相册'));
        await images.pickStarted.future;
        await store.removeChildData('child');
        images.selection!.complete(fixture());
        await idle(tester);
        expect(images.processes, 0);
        expect(await store.imageDrafts('original-owner'), isEmpty);
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(remote.saves, 0);
        await tester.pumpWidget(const SizedBox());
      });
    },
  );

  testWidgets(
    'PIN expiry during processing keeps only the unconsented original',
    (tester) async {
      await tester.runAsync(() async {
        images.processing = Completer<Uint8List>();
        await mount(tester);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QuestionOcrScreen)),
        );
        await tester.tap(find.text('相册'));
        await images.processStarted.future.timeout(const Duration(seconds: 5));
        parent = null;
        container.read(parentFamilyIdProvider.notifier).state = null;
        images.processing!.complete(fixture());
        await idle(tester);
        final rows = await store.imageDrafts('original-owner');
        expect(rows, hasLength(1));
        final row = await store.imageDraft(
          'original-owner',
          rows.single['draft_id'] as String,
        );
        expect(row!['processed'], isNull);
        expect(row['metadata']['consent'], false);
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(remote.saves, 0);
        await tester.pumpWidget(const SizedBox());
      });
    },
  );

  testWidgets('original storage failure stops processing before it starts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await repository.dispose();
      await store.close();
      store = RefusingImageStore();
      connect();
      await mount(tester);
      await tester.tap(find.text('相册'));
      await idle(tester);
      expect(images.processes, 0);
      expect(await store.imageDrafts('original-owner'), isEmpty);
      expect(remote.saves, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  for (final changeAccount in [true, false]) {
    testWidgets(
      'queued edits ${changeAccount ? 'cannot cross accounts' : 'finish after leaving the page'}',
      (tester) async {
        await tester.runAsync(() async {
          await repository.dispose();
          await store.close();
          final paused = PausingImageStore(databaseFile);
          store = paused;
          connect();
          addTearDown(() {
            if (!paused.release.isCompleted) paused.release.complete();
          });
          await mount(tester);
          await tester.tap(find.text('相册'));
          await idle(tester);
          final id =
              (await store.imageDrafts('original-owner')).single['draft_id']
                  as String;
          await tester.scrollUntilVisible(
            find.text('顺时针旋转90°'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          paused.pauseNextWrite = true;
          await tester.tap(find.text('顺时针旋转90°'));
          await paused.entered.future.timeout(const Duration(seconds: 5));
          await tester.pump();
          await tester.tap(find.text('顺时针旋转90°'));
          // The second edit is waiting behind an in-flight database write.
          if (changeAccount) {
            owner = 'different-owner';
          } else {
            await tester.pumpWidget(const SizedBox());
          }
          paused.release.complete();
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
            final row = await store.imageDraft('original-owner', id);
            if (changeAccount
                ? find.textContaining('账号或本机资料已变化').evaluate().isNotEmpty
                : row!['metadata']['turns'] == 2) {
              break;
            }
          }
          expect(await store.imageDrafts('different-owner'), isEmpty);
          final row = await store.imageDraft('original-owner', id);
          expect(row!['metadata']['turns'], changeAccount ? 1 : 2);
          expect(row['processed'], isNull);
          expect(row['metadata']['consent'], false);
          expect(tester.takeException(), isNull);
          expect(remote.saves, 0);
          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  }
}

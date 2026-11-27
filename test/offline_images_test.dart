import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/question_ocr_screen.dart';
import 'package:learning_planet/features/wrong_questions/presentation/image_drafts_screen.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'ocr_management_test.dart' show FakeMedia, FakeImages, fixture;

class PreviewDrafts extends OfflineQuestionMediaRepository {
  PreviewDrafts(OfflineStore store)
    : super(
        store: store,
        live: FakeMedia(),
        accountId: () => 'parent',
        parentFamily: () => 'family',
        autoSync: false,
      );
  Map<String, dynamic>? savedMetadata;
  @override
  Future<Map<String, dynamic>> draft(
    String id,
    String family, {
    bool childInput = false,
  }) async => {
    'child_id': 'child',
    'family_id': 'family',
    'stage': 'editing',
    'original': fixture(),
    'processed': fixture(),
    'metadata': {
      'consent': true,
      'editor': {
        'final_text': '已校对的题目',
        'answers': ['4'],
        'subject': 'math',
      },
    },
  };
  @override
  Future<void> saveDraft(
    String child,
    String family,
    String id,
    Map<String, dynamic> metadata,
    Uint8List? original,
    Uint8List? processed, {
    bool metadataOnly = false,
  }) async {
    savedMetadata = metadata;
  }
}

class ImageRemote extends FakeMedia implements GuardedQuestionMediaRepository {
  bool online = false, lostReply = false, denied = false;
  final committed = <String>{};
  Completer<void>? entered, barrier;
  @override
  Future<void> saveGuarded(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
    Future<void> Function() guard,
  ) async {
    await guard();
    saves++;
    ids.add(draftId);
    if (!online) throw const SocketException('offline');
    if (denied) {
      throw const PostgrestException(
        message: 'Parent authorization required or expired',
        code: '42501',
      );
    }
    if (entered != null && !entered!.isCompleted) entered!.complete();
    await barrier?.future;
    await guard();
    committed.add(draftId);
    if (lostReply) {
      lostReply = false;
      throw const SocketException('lost reply');
    }
  }
}

void main() {
  test(
    'real Supabase SDK retries partial uploads and unknown save replies with one payload hash',
    () async {
      const uid = '10000000-0000-0000-0000-000000000001';
      final hashes = <String>[];
      var stage = 'pending',
          originals = 0,
          processed = 0,
          recognitions = 0,
          creates = 0,
          saveCalls = 0;
      final transport = MockClient((request) async {
        final path = request.url.path;
        http.Response response(Object? data, [int status = 200]) =>
            http.Response(
              jsonEncode(data),
              status,
              headers: {'content-type': 'application/json'},
              request: request,
            );
        if (path.endsWith('/token')) {
          return response({
            'access_token':
                'header.${base64UrlEncode(utf8.encode(jsonEncode({'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600, 'sub': uid})))}.signature',
            'refresh_token': 'test-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': uid,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'parent@example.test',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-11-04T00:00:00Z',
            },
          });
        }
        if (path.endsWith('/begin_question_media_upload')) {
          hashes.add(
            (jsonDecode(request.body) as Map)['payload_hash'] as String,
          );
          return response({
            'status': stage,
            'original_path': 'family/draft/original.jpg',
            'processed_path': 'family/draft/processed.jpg',
          });
        }
        if (path.endsWith('/original.jpg')) {
          originals++;
          return originals == 1
              ? response({'Key': 'original'})
              : response({
                  'statusCode': '409',
                  'error': 'Duplicate',
                  'message': 'exists',
                }, 409);
        }
        if (path.endsWith('/processed.jpg')) {
          processed++;
          return processed == 1
              ? response({
                  'statusCode': '503',
                  'error': 'Unavailable',
                  'message': 'offline',
                }, 503)
              : response({'Key': 'processed'});
        }
        if (path.endsWith('/record_question_ocr')) {
          recognitions++;
          stage = 'recognized';
          return response(null);
        }
        if (path.endsWith('/save_review_question')) {
          saveCalls++;
          if (stage != 'saved') {
            creates++;
            stage = 'saved';
          }
          return saveCalls == 1
              ? response({'code': '503', 'message': 'reply lost'}, 503)
              : response('question-id');
        }
        throw StateError('Unexpected endpoint $path');
      });
      final client = SupabaseClient(
        'https://example.test',
        'public',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      try {
        await client.auth.signInWithPassword(
          email: 'parent@example.test',
          password: 'test-only',
        );
        final remote = SupabaseQuestionMediaRepository(
          client,
          SupabaseReviewRepository(client),
        );
        Future<void> save() => remote.save(
          'child',
          'draft',
          fixture(),
          fixture(),
          {'text': 'raw'},
          {
            'kind': 'question',
            'subject': 'math',
            'prompt': 'corrected',
            'answers': ['4'],
            'ocr_confirmed': true,
          },
        );
        await expectLater(save(), throwsA(isA<StorageException>()));
        await expectLater(save(), throwsA(isA<PostgrestException>()));
        await save();
        expect(hashes.length, 3);
        expect(hashes.toSet().length, 1);
        expect(originals, 2);
        expect(processed, 2);
        expect(recognitions, 1);
        expect(creates, 1);
      } finally {
        await client.dispose();
      }
    },
  );
  late OfflineStore store;
  late OfflineQuestionMediaRepository repo;
  late ImageRemote remote;
  String? owner, family;
  final config = <String, dynamic>{
    'kind': 'question',
    'subject': 'math',
    'prompt': '2+2',
    'answers': ['4'],
    'ocr_confirmed': true,
  };
  void make() {
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
    remote = ImageRemote();
    owner = 'parent';
    family = 'family';
    make();
    await store.customSelect('SELECT 1').get();
  });
  tearDown(() async {
    await repo.dispose();
    await store.close();
  });
  Future<void> seed({
    String id = 'draft',
    String child = 'child',
    bool consent = true,
  }) => repo.saveDraft(
    child,
    'family',
    id,
    {
      'consent': consent,
      'editor': {
        'final_text': 'incomplete',
        'answers': ['4'],
      },
      'recognition': {'text': '2+Z'},
    },
    fixture(),
    fixture(),
  );
  Future<void> queue({String id = 'draft'}) =>
      repo.save('child', id, fixture(), fixture(), {'text': '2+Z'}, config);
  test(
    'images and unfinished correction survive SQLite schema three upgrade and restart',
    () async {
      final directory = await Directory.systemTemp.createTemp('planet-images-');
      final file = File('${directory.path}/cache.sqlite');
      await repo.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      await store.write('parent', 'tasks:child', {'keep': true});
      await store.customStatement('DROP TABLE image_drafts');
      await store.customStatement('DROP TABLE discarded_image_drafts');
      await store.customStatement('DROP TABLE family_access');
      await store.customStatement('PRAGMA user_version=3');
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      make();
      expect(await store.read('parent', 'tasks:child'), {'keep': true});
      await seed();
      await repo.saveDraft(
        'child',
        'family',
        'draft',
        {
          'editor': {
            'final_text': 'corrected',
            'answers': ['4'],
          },
          'consent': false,
        },
        null,
        null,
        metadataOnly: true,
      );
      await repo.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      make();
      final row = await repo.draft('draft', 'family');
      expect((row['original'] as Uint8List), fixture());
      expect(row['metadata']['editor']['final_text'], 'corrected');
      expect(row['stage'], 'editing');
      expect(remote.saves, 0);
      await repo.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase.memory());
      make();
      await directory.delete(recursive: true);
    },
  );
  test(
    'consent and correction gate queue and queued payload cannot be changed',
    () async {
      await seed(consent: false);
      await expectLater(queue(), throwsStateError);
      expect(remote.saves, 0);
      await seed();
      await queue();
      await queue();
      expect((await repo.drafts('child', 'family')).length, 1);
      await expectLater(
        repo.save('child', 'draft', fixture(), fixture(), {
          'text': 'changed',
        }, config),
        throwsStateError,
      );
      await expectLater(
        repo.saveDraft(
          'child',
          'family',
          'draft',
          {'editor': {}},
          null,
          null,
          metadataOnly: true,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'network loss preserves original UUID and both images, then confirmed upload clears local private data',
    () async {
      await seed();
      await queue();
      await repo.synchronize();
      expect((await repo.draft('draft', 'family'))['stage'], 'retry');
      remote.online = true;
      remote.lostReply = true;
      await repo.synchronize(retryBlocked: true);
      expect(remote.committed, {'draft'});
      expect(await store.imageDraft('parent', 'draft'), isNotNull);
      await repo.synchronize(retryBlocked: true);
      expect(remote.ids, ['draft', 'draft', 'draft']);
      expect(await store.imageDraft('parent', 'draft'), isNull);
      await expectLater(seed(), throwsStateError);
      expect(remote.committed.length, 1);
    },
  );
  test(
    'expired parent authority preserves queue, renewed PIN retries without storing a PIN',
    () async {
      await seed();
      await queue();
      family = null;
      await repo.synchronize();
      expect(remote.saves, 0);
      await expectLater(repo.drafts('child', 'family'), throwsStateError);
      family = 'family';
      remote.online = true;
      remote.denied = true;
      await repo.synchronize();
      expect(
        (await repo.draft('draft', 'family'))['stage'],
        'needs_authorization',
      );
      await repo.synchronize();
      expect(remote.saves, 1);
      remote.denied = false;
      await repo.synchronize(retryBlocked: true);
      expect(await store.imageDraft('parent', 'draft'), isNull);
    },
  );
  test(
    'account change and deletion stop a request before subsequent upload steps',
    () async {
      await seed();
      await queue();
      remote.online = true;
      remote.entered = Completer();
      remote.barrier = Completer();
      final work = repo.synchronize();
      await remote.entered!.future;
      owner = 'other';
      remote.barrier!.complete();
      await work;
      expect(remote.committed, isEmpty);
      expect(await repo.drafts('child', 'family'), isEmpty);
      owner = 'parent';
      await store.removeAccountData('parent', 'delete-job');
      expect(await store.imageDraft('parent', 'draft'), isNull);
      await expectLater(seed(), throwsStateError);
    },
  );
  test(
    'child deletion clears only this child images and blocks a late upload callback',
    () async {
      await seed();
      await queue();
      await seed(id: 'sibling-draft', child: 'sibling');
      remote.online = true;
      remote.entered = Completer();
      remote.barrier = Completer();
      final work = repo.synchronize();
      await remote.entered!.future;
      await store.removeChildData('child');
      remote.barrier!.complete();
      await work;
      expect(remote.committed, isEmpty);
      expect(await store.imageDraft('parent', 'draft'), isNull);
      expect(await store.imageDraft('parent', 'sibling-draft'), isNotNull);
      await expectLater(seed(), throwsStateError);
    },
  );
  test(
    'discarding a pending image is durable and blocks metadata or late callback resurrection',
    () async {
      await seed();
      await queue();
      remote.online = true;
      remote.entered = Completer();
      remote.barrier = Completer();
      final work = repo.synchronize();
      await remote.entered!.future;
      await repo.discard('draft', 'family');
      remote.barrier!.complete();
      await work;
      expect(remote.committed, isEmpty);
      expect(await store.imageDraft('parent', 'draft'), isNull);
      await expectLater(seed(), throwsStateError);
    },
  );
  test(
    'stable upload fingerprint includes images, corrected answers and recognition independent of map order',
    () {
      final a = {
        'original': fixture(),
        'processed': fixture(),
        'config': config,
        'recognition': {'text': 'raw', 'lines': []},
      };
      final b = {
        'recognition': {'lines': [], 'text': 'raw'},
        'config': config,
        'processed': fixture(),
        'original': fixture(),
      };
      expect(mediaPayloadHash(a), mediaPayloadHash(b));
      expect(
        mediaPayloadHash({
          ...a,
          'config': {
            ...config,
            'answers': ['5'],
          },
        }),
        isNot(mediaPayloadHash(a)),
      );
    },
  );
  test(
    'draft limits reject a new row without evicting existing work',
    () async {
      for (var i = 0; i < 50; i++) {
        await seed(id: 'draft-$i');
      }
      await expectLater(seed(id: 'overflow'), throwsStateError);
      expect((await repo.drafts('child', 'family')).length, 50);
      await repo.discard('draft-0', 'family');
      await seed(id: 'replacement');
      expect((await repo.drafts('child', 'family')).length, 50);
    },
  );
  testWidgets(
    'restored OCR draft keeps corrected fields and autosaves new editing before submission',
    (tester) async {
      final preview = PreviewDrafts(store);
      addTearDown(() {
        unawaited(preview.dispose());
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            questionMediaRepositoryProvider.overrideWithValue(preview),
            questionImageServiceProvider.overrideWithValue(FakeImages()),
            activeParentFamilyProvider.overrideWith(
              (ref) => ref.watch(parentFamilyIdProvider),
            ),
            parentFamilyIdProvider.overrideWith((ref) => 'family'),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const QuestionOcrScreen(
              childId: 'child',
              familyId: 'family',
              draftId: 'draft',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('转手工校对并保存图片'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('转手工校对并保存图片'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(TextFormField, '题目'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('已校对的题目'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, '题目'),
        '继续校对的题目',
      );
      await tester.pumpAndSettle();
      expect(preview.savedMetadata?['editor']['final_text'], '继续校对的题目');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QuestionOcrScreen, skipOffstage: false)),
      );
      container.read(parentFamilyIdProvider.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('校对草稿已保留'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      container.read(parentFamilyIdProvider.notifier).state = 'family';
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(TextFormField, '题目'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('继续校对的题目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      unawaited(preview.dispose());
      await tester.pump();
    },
  );
  testWidgets(
    'image queue requires PIN and pending status fits a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget app(String? family) => ProviderScope(
        overrides: [
          questionMediaRepositoryProvider.overrideWithValue(repo),
          activeParentFamilyProvider.overrideWithValue(family),
          imageDraftsProvider.overrideWith(
            (ref, scope) async => [
              {
                'draft_id': 'draft',
                'stage': 'needs_authorization',
                'updated_at': DateTime.now().millisecondsSinceEpoch,
                'error': '需要重新验证家长 PIN',
              },
            ],
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const ImageDraftsScreen(childId: 'child', familyId: 'family'),
        ),
      );
      await tester.pumpWidget(app(null));
      await tester.pumpAndSettle();
      expect(find.text('验证家长 PIN 并继续'), findsOneWidget);
      expect(find.text('删除本机草稿'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app('family'));
      await tester.pumpAndSettle();
      expect(find.text('待重新验证家长授权'), findsOneWidget);
      expect(find.text('重新验证家长 PIN'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

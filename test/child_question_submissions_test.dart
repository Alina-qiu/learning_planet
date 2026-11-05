import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/child_question_submissions.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';
import 'package:learning_planet/features/wrong_questions/presentation/child_question_submissions_screen.dart';
import 'ocr_management_test.dart' show fixture, FakeMedia;
import 'support/mock_supabase.dart';

const submissionScope = (childId: 'child', familyId: 'family');
Map<String, dynamic> submissionValue() => {
  'owner_id': 'owner',
  'child_id': 'child',
  'family_id': 'family',
  'draft_id': 'draft',
  'created_by': 'owner',
  'state': 'pending',
  'question_id': null,
  'config': {
    'kind': 'question',
    'subject': 'math',
    'prompt': '2+2=?',
    'answers': [],
    'ocr_confirmed': true,
  },
  'recognition': {'text': '2+Z=?'},
  'original_path': null,
  'processed_path': null,
};
Map<String, dynamic> submissionPage() => {
  'owner_id': 'owner',
  'child_id': 'child',
  'family_id': 'family',
  'items': [
    {
      'id': 'draft',
      'title': '2+2=?',
      'state': 'pending',
      'submitted_at': '2026-11-05T00:00:00Z',
    },
  ],
  'next_cursor': null,
};

class SubmissionRemote implements ChildSubmissionRemote {
  Map<String, dynamic> value = submissionValue(), page = submissionPage();
  Future<Map<String, dynamic>> Function()? loading;
  Future<Map<String, dynamic>> Function()? saving;
  final requests = <({String id, Map<String, dynamic> config})>[];
  final images = <String>[];
  @override
  Future<Map<String, dynamic>> list(
    String child,
    Map<String, dynamic>? cursor,
  ) async => page;
  @override
  Future<Map<String, dynamic>> read(String draft) async =>
      loading == null ? value : loading!();
  @override
  Future<String> imageUrl(String path) async {
    images.add(path);
    return 'https://example.test/$path';
  }

  @override
  Future<Map<String, dynamic>> approve(
    String draft,
    String request,
    Map<String, dynamic> config,
  ) async {
    requests.add((id: request, config: config));
    return saving == null
        ? {
            ...value,
            'state': 'approved',
            'question_id': 'question',
            'confirmed_at': '2026-11-05T00:00:00Z',
          }
        : saving!();
  }
}

class SubmissionHarness {
  final store = OfflineStore(NativeDatabase.memory()),
      remote = SubmissionRemote();
  String? owner = 'owner';
  bool parent = false;
  int revision = 0;
  late final service = ChildQuestionSubmissions(
    store: store,
    remote: remote,
    owner: () => owner,
    parent: (_) => parent,
    revision: () => revision,
  );
  Future<void> close() async {
    service.dispose();
    await store.close();
  }
}

class NeverSaveReview extends Fake implements ReviewRepository {
  @override
  Future<void> save(
    String childId,
    Map<String, dynamic> config, {
    String? questionId,
  }) => throw StateError('Child input must not save a graded question');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'child draft mode remains immutable and cannot expose or promote parent drafts',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      String? parent = 'family';
      final repo = OfflineQuestionMediaRepository(
        store: store,
        live: FakeMedia(),
        accountId: () => 'owner',
        parentFamily: () => parent,
        autoSync: false,
      );
      addTearDown(() async {
        await repo.dispose();
        await store.close();
      });
      await repo.saveDraft(
        'child',
        'family',
        'parent',
        {'consent': true},
        fixture(),
        fixture(),
      );
      parent = null;
      final ids = await repo.importImages(
        'child',
        'family',
        () async => [fixture(), fixture()],
        childInput: true,
      );
      expect(
        await repo.drafts('child', 'family', includeChildDrafts: true),
        hasLength(2),
      );
      await expectLater(
        repo.draft('parent', 'family', childInput: true),
        throwsStateError,
      );
      await expectLater(
        repo.saveDraft(
          'child',
          'family',
          'parent',
          {'requires_parent_review': true},
          fixture(),
          fixture(),
        ),
        throwsStateError,
      );
      await expectLater(
        store.updateImageDraftMetadata('owner', 'child', 'family', 'parent', {
          'requires_parent_review': true,
        }),
        throwsStateError,
      );
      final child = await repo.draft(ids.first, 'family', childInput: true);
      await expectLater(
        store.updateImageDraftMetadata(
          'owner',
          'child',
          'family',
          ids.first,
          {},
        ),
        throwsStateError,
      );
      expect((child['metadata'] as Map)['requires_parent_review'], true);
      await repo.discard(ids.last, 'family', childInput: true);
      expect(
        await repo.drafts('child', 'family', includeChildDrafts: true),
        hasLength(1),
      );
    },
  );
  test(
    'child upload queue continues without PIN only after consent and preserves child review flag',
    () async {
      final store = OfflineStore(NativeDatabase.memory()), live = FakeMedia();
      final repo = OfflineQuestionMediaRepository(
        store: store,
        live: live,
        accountId: () => 'owner',
        parentFamily: () => null,
        autoSync: false,
      );
      addTearDown(() async {
        await repo.dispose();
        await store.close();
      });
      await repo.saveDraft(
        'child',
        'family',
        'draft',
        {'requires_parent_review': true, 'consent': false},
        fixture(),
        fixture(),
      );
      final config = {
        ...(submissionValue()['config'] as Map<String, dynamic>),
        'requires_parent_review': true,
      };
      await expectLater(
        repo.save('child', 'draft', fixture(), fixture(), null, config),
        throwsStateError,
      );
      await repo.saveDraft(
        'child',
        'family',
        'draft',
        {'requires_parent_review': true, 'consent': true},
        fixture(),
        fixture(),
      );
      await expectLater(
        repo.save('child', 'draft', fixture(), fixture(), null, {
          ...config,
          'requires_parent_review': false,
        }),
        throwsStateError,
      );
      await repo.save('child', 'draft', fixture(), fixture(), null, config);
      await repo.synchronize();
      expect(live.saves, 1);
      expect(live.config?['requires_parent_review'], true);
      expect(await store.imageDraft('owner', 'draft'), null);
    },
  );
  test(
    'native selection cannot move child input across accounts or privacy cleanup',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      String? owner = 'owner';
      final repo = OfflineQuestionMediaRepository(
        store: store,
        live: FakeMedia(),
        accountId: () => owner,
        parentFamily: () => null,
        autoSync: false,
      );
      addTearDown(() async {
        await repo.dispose();
        await store.close();
      });
      await expectLater(
        repo.importImages('child', 'family', () async {
          owner = 'new';
          return [fixture()];
        }, childInput: true),
        throwsStateError,
      );
      owner = 'owner';
      await expectLater(
        repo.importImages('child', 'family', () async {
          store.privacyGeneration++;
          return [fixture()];
        }, childInput: true),
        throwsStateError,
      );
      expect(await store.imageDrafts('owner'), isEmpty);
    },
  );
  test(
    'child media SDK uploads both images and submits without any parent or graded-question RPC',
    () async {
      final api = MockSupabase();
      addTearDown(api.close);
      await api.signIn();
      final live = SupabaseQuestionMediaRepository(
        api.client,
        NeverSaveReview(),
      );
      api.handle = (request) {
        if (request.url.path.endsWith('begin_child_question_upload')) {
          return MockSupabase.json(request, {
            'status': 'pending',
            'original_path': 'family/draft/original.jpg',
            'processed_path': 'family/draft/processed.jpg',
          });
        }
        if (request.url.path.endsWith('submit_child_question')) {
          return MockSupabase.json(request, {
            ...submissionValue(),
            'owner_id': MockSupabase.firstUser,
          });
        }
        if (request.url.path.contains('/storage/')) {
          return MockSupabase.json(request, {'Key': 'uploaded'});
        }
        throw StateError('Unexpected request: ${request.url.path}');
      };
      await live.save(
        'child',
        'draft',
        fixture(),
        fixture(),
        {'text': 'raw'},
        {
          ...(submissionValue()['config'] as Map<String, dynamic>),
          'requires_parent_review': true,
        },
      );
      expect(
        api.calls.where((r) => r.url.path.contains('/storage/')),
        hasLength(2),
      );
      expect(
        api.calls
            .where((r) => r.url.path.contains('/rpc/'))
            .map((r) => r.url.path.split('/').last),
        ['begin_child_question_upload', 'submit_child_question'],
      );
      expect(MockSupabase.body(api.calls.last)['recognition'], {'text': 'raw'});
      api.handle = (request) => MockSupabase.json(
        request,
        request.url.path.endsWith('begin_child_question_upload')
            ? {'status': 'recognized'}
            : {...submissionValue(), 'owner_id': 'foreign'},
      );
      await expectLater(
        live.save('child', 'draft', fixture(), fixture(), null, {
          'requires_parent_review': true,
        }),
        throwsStateError,
      );
    },
  );
  group('cloud submission guards', () {
    late SubmissionHarness h;
    setUp(() => h = SubmissionHarness());
    tearDown(() => h.close());
    test(
      'own pending content is readable without PIN but confirmation requires it',
      () async {
        final access = h.service.capture(submissionScope);
        expect(
          (await h.service.list(submissionScope, access))['items'],
          hasLength(1),
        );
        expect(
          (await h.service.read(submissionScope, access, 'draft'))['state'],
          'pending',
        );
        await expectLater(
          h.service.approve(submissionScope, access, 'draft', 'request', {}),
          throwsStateError,
        );
        expect(h.remote.requests, isEmpty);
        h.remote.value['created_by'] = 'another';
        await expectLater(
          h.service.read(submissionScope, access, 'draft'),
          throwsStateError,
        );
        h.parent = true;
        expect(
          await h.service.read(
            submissionScope,
            h.service.capture(submissionScope),
            'draft',
          ),
          isNotEmpty,
        );
      },
    );
    test(
      'late reads are fenced on owner PIN privacy and disposal changes',
      () async {
        for (final mutate in <void Function()>[
          () => h.owner = 'new',
          () => h.parent = true,
          () => h.revision++,
          () => h.store.privacyGeneration++,
          () => h.service.dispose(),
        ]) {
          final access = h.service.capture(submissionScope);
          h.remote.loading = () async {
            mutate();
            return h.remote.value;
          };
          await expectLater(
            h.service.read(submissionScope, access, 'draft'),
            throwsStateError,
          );
          h.owner = 'owner';
          h.parent = false;
        }
      },
    );
    test(
      'cross-scope receipts invalid pagination and foreign media paths are rejected',
      () async {
        final access = h.service.capture(submissionScope);
        for (final field in ['owner_id', 'child_id', 'family_id']) {
          h.remote.value = {...submissionValue(), field: 'foreign'};
          await expectLater(
            h.service.read(submissionScope, access, 'draft'),
            throwsStateError,
          );
        }
        h.remote.value = {
          ...submissionValue(),
          'processed_path': 'foreign/draft/processed.jpg',
        };
        await expectLater(
          h.service.read(submissionScope, access, 'draft'),
          throwsStateError,
        );
        expect(h.remote.images, isEmpty);
        h.remote.value = {
          ...submissionValue(),
          'processed_path': 'family/draft/processed.jpg',
        };
        expect(
          (await h.service.read(
            submissionScope,
            access,
            'draft',
          ))['image_urls'],
          hasLength(1),
        );
        h.remote.page['next_cursor'] = {
          'id': 'wrong',
          'created_at': '2026-11-05T00:00:00Z',
        };
        await expectLater(
          h.service.list(submissionScope, access),
          throwsStateError,
        );
        h.remote.page = {
          ...submissionPage(),
          'items': [{}, {}],
        };
        await expectLater(
          h.service.list(submissionScope, access),
          throwsStateError,
        );
      },
    );
    test(
      'approval sends a frozen payload and rejects unconfirmed or late unauthorized receipts',
      () async {
        h.parent = true;
        final access = h.service.capture(submissionScope),
            config = {
              'answers': ['4'],
            };
        final pending = h.service.approve(
          submissionScope,
          access,
          'draft',
          'request',
          config,
        );
        (config['answers'] as List)[0] = 'changed';
        expect((await pending)['state'], 'approved');
        expect(h.remote.requests.single.config['answers'], ['4']);
        h.remote.saving = () async => submissionValue();
        await expectLater(
          h.service.approve(
            submissionScope,
            access,
            'draft',
            'request',
            config,
          ),
          throwsStateError,
        );
        h.remote.saving = () async {
          h.parent = false;
          return {
            ...submissionValue(),
            'state': 'approved',
            'question_id': 'q',
            'confirmed_at': 'now',
          };
        };
        await expectLater(
          h.service.approve(
            submissionScope,
            access,
            'draft',
            'request',
            config,
          ),
          throwsStateError,
        );
      },
    );
    test(
      'SDK RPC arguments preserve cursor approval UUID and explicit config',
      () async {
        final api = MockSupabase();
        addTearDown(api.close);
        await api.signIn();
        api.handle = (r) => MockSupabase.json(r, submissionValue());
        final remote = SupabaseChildSubmissionRemote(api.client);
        await remote.list('child', {
          'created_at': '2026-11-05T00:00:00Z',
          'id': 'draft',
        });
        expect(MockSupabase.body(api.calls.last), {
          'target_child_id': 'child',
          'after_created_at': '2026-11-05T00:00:00Z',
          'after_id': 'draft',
        });
        await remote.read('draft');
        await remote.approve('draft', 'stable', {
          'answers': ['4'],
        });
        expect(MockSupabase.body(api.calls.last), {
          'target_draft_id': 'draft',
          'request_id': 'stable',
          'config': {
            'answers': ['4'],
          },
        });
      },
    );
  });
  testWidgets(
    'child editor allows missing answer but still requires OCR confirmation and excludes AI suggestions',
    (tester) async {
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ReviewQuestionEditor(
                        pinyin: false,
                        childSubmission: true,
                        fromImage: true,
                        familyId: 'family',
                        childId: 'child',
                        initial: {'final_text': '2+2=?'},
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('AI 分类建议（家长审核）'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('保存给家长确认'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('保存给家长确认'));
      await tester.pumpAndSettle();
      expect(result, null);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存给家长确认'));
      await tester.tap(find.text('保存给家长确认'));
      await tester.pumpAndSettle();
      expect(result?['answers'], isEmpty);
      expect(result?['ocr_confirmed'], true);
    },
  );
  testWidgets(
    'parent screen keeps the original approval intent across a lost response and hides data after PIN loss',
    (tester) async {
      final h = SubmissionHarness()..parent = true;
      addTearDown(h.close);
      final container = ProviderContainer(
        overrides: [
          childQuestionSubmissionsProvider.overrideWithValue(h.service),
          activeParentFamilyProvider.overrideWith(
            (ref) => ref.watch(parentFamilyIdProvider),
          ),
        ],
      );
      container.read(parentFamilyIdProvider.notifier).state = 'family';
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: const ChildQuestionSubmissionsScreen(
              childId: 'child',
              familyId: 'family',
            ),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
      }

      await settle();
      await tester.tap(find.text('2+2=?'));
      await settle();
      await tester.ensureVisible(find.text('核对标准答案并确认入库'));
      await tester.tap(find.text('核对标准答案并确认入库'));
      await tester.pumpAndSettle();
      final answer = find.widgetWithText(TextFormField, '标准答案（一行一个可接受答案）');
      await tester.scrollUntilVisible(
        find.text('已核对题干的文字与字段归属'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已核对题干的文字与字段归属'));
      await tester.scrollUntilVisible(
        answer,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(answer, '4');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('保存'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final finalConfirmation = find.widgetWithText(
        CheckboxListTile,
        '我已逐项核对原图、所有题目文字（含低置信/未知置信内容）及标准答案',
      );
      await tester.ensureVisible(finalConfirmation);
      await tester.pumpAndSettle();
      await tester.tap(finalConfirmation);
      await tester.pumpAndSettle();
      h.remote.saving = () async => throw const SocketException('reply lost');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await settle();
      expect(h.remote.requests, hasLength(1));
      await tester.ensureVisible(find.text('重试原确认请求'));
      await tester.tap(find.text('重试原确认请求'));
      await settle();
      expect(h.remote.requests, hasLength(2));
      expect(h.remote.requests[0].id, h.remote.requests[1].id);
      expect(h.remote.requests[0].config, h.remote.requests[1].config);
      h.remote.saving = null;
      await tester.tap(find.text('重试原确认请求'));
      await settle();
      expect(find.text('家长已确认并入库'), findsOneWidget);
      h.parent = false;
      container.read(parentFamilyIdProvider.notifier).state = null;
      container.read(parentAuthorizationRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(find.text('2+2=?'), findsNothing);
      expect(find.text('重试原确认请求'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/features/auth_family/data/family_creation_repository.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/auth_family/presentation/family_creation_screen.dart';
import 'package:learning_planet/features/auth_family/presentation/family_onboarding_screen.dart';
import 'widget_test.dart' show FakeFamilyRepository;

class CreationRemote implements FamilyCreationRemote {
  final receipts = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  bool loseReply = false;
  int created = 0;
  Completer<void>? wait;
  @override
  Future<Map<String, dynamic>> resolve(
    FamilyCreationDraft draft,
    String operation,
  ) async {
    calls.add(operation);
    await wait?.future;
    if (!receipts.containsKey(draft.requestId) && operation != 'inspect') {
      receipts[draft.requestId] = {
        'request_id': draft.requestId,
        'family_id': draft.familyId,
        'child_id': draft.childId,
        'status': operation == 'submit' ? 'created' : 'cancelled',
      };
      if (operation == 'submit') created++;
    }
    if (loseReply) {
      loseReply = false;
      throw const SocketException('response lost');
    }
    return receipts[draft.requestId] ??
        {
          'request_id': draft.requestId,
          'family_id': draft.familyId,
          'child_id': draft.childId,
          'status': 'unknown',
        };
  }
}

Future<FamilyCreationDraft> prepare(
  FamilyCreationRepository repository, {
  String? familyId,
}) => repository.prepare(
  familyId: familyId,
  familyName: '星星家',
  nickname: '小星星',
  grade: 2,
  textbookLabels: {'math': '校本教材'},
  avatarKey: 'rocket',
);

// SQLite transactions use real asynchronous work. Let it finish outside the
// widget test's fake clock, then settle animations normally.
Future<void> databaseAction(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(() async {
    await action();
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        return;
      }
    }
    throw StateError('SQLite UI did not finish within the test deadline');
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineStore store;
  late CreationRemote remote;
  late FamilyCreationRepository repository;
  String? owner;
  setUp(() async {
    store = OfflineStore(NativeDatabase.memory());
    await store.customSelect('SELECT 1').get();
    remote = CreationRemote();
    owner = 'parent';
    repository = FamilyCreationRepository(
      store: store,
      accountId: () => owner,
      remote: remote,
    );
  });
  tearDown(() => store.close());

  test(
    'creation request is immutable and durable before network, surviving SQLite restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'creation-restart-',
      );
      final file = File('${directory.path}/draft.sqlite');
      final disk = OfflineStore(NativeDatabase(file));
      final first = FamilyCreationRepository(
        store: disk,
        accountId: () => 'parent',
        remote: remote,
      );
      final labels = {'math': 'original'};
      final pending = first.prepare(
        familyName: 'family',
        nickname: 'child',
        grade: 2,
        textbookLabels: labels,
        avatarKey: 'star',
      );
      labels['math'] = 'changed';
      final draft = await pending;
      expect((draft.command['preferences'] as Map)['textbook_labels'], {
        'math': 'original',
      });
      draft.command['nickname'] = 'mutated';
      expect(draft.command['nickname'], 'child');
      expect(remote.calls, isEmpty);
      await expectLater(prepare(first), throwsStateError);
      await disk.close();
      final restarted = OfflineStore(NativeDatabase(file));
      final second = FamilyCreationRepository(
        store: restarted,
        accountId: () => 'parent',
        remote: remote,
      );
      final restored = (await second.pending(null))!;
      expect(restored.toJson(), draft.toJson());
      remote.loseReply = true;
      await expectLater(
        second.resolve(null, draft.requestId, 'submit'),
        throwsA(isA<SocketException>()),
      );
      expect((await second.pending(null))!.status, 'pending');
      expect(
        (await second.resolve(null, draft.requestId, 'inspect')).status,
        'created',
      );
      expect(remote.created, 1);
      await restarted.close();
      await directory.delete(recursive: true);
    },
  );

  test(
    'pending creation cannot be discarded or overwritten; cancellation fences old request',
    () async {
      final draft = await prepare(repository);
      await expectLater(
        repository.dismiss(null, draft.requestId),
        throwsStateError,
      );
      final result = await repository.resolve(null, draft.requestId, 'cancel');
      expect(result.status, 'cancelled');
      expect(
        (await repository.resolve(null, draft.requestId, 'submit')).status,
        'cancelled',
      );
      expect(remote.created, 0);
      await repository.dismiss(null, draft.requestId);
      final next = await prepare(repository);
      expect(next.requestId, isNot(draft.requestId));
      expect(next.childId, isNot(draft.childId));
      await expectLater(
        repository.resolve(null, draft.requestId, 'submit'),
        throwsStateError,
      );
    },
  );

  test(
    'account switch isolates requests and late receipt never writes into new account',
    () async {
      final draft = await prepare(repository);
      remote.wait = Completer<void>();
      final submission = repository.resolve(null, draft.requestId, 'submit');
      final assertion = expectLater(submission, throwsStateError);
      while (remote.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      owner = 'other';
      remote.wait!.complete();
      await assertion;
      expect(await repository.pending(null), isNull);
      owner = 'parent';
      expect((await repository.pending(null))!.status, 'pending');
      expect(
        (await repository.resolve(null, draft.requestId, 'inspect')).status,
        'created',
      );
    },
  );

  test(
    'child/account deletion erases creation payloads and prevents late acknowledgements restoring them',
    () async {
      final draft = await prepare(repository, familyId: 'family');
      remote.wait = Completer<void>();
      final submission = repository.resolve(
        'family',
        draft.requestId,
        'submit',
      );
      final assertion = expectLater(submission, throwsStateError);
      while (remote.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await store.removeChildData(draft.childId);
      remote.wait!.complete();
      await assertion;
      expect(await repository.pending('family'), isNull);
      await prepare(repository);
      await store.removeAccountData('parent', 'delete-job');
      await expectLater(repository.pending(null), throwsStateError);
      await expectLater(prepare(repository), throwsStateError);
      expect(
        await store.customSelect('SELECT * FROM offline_cache').get(),
        isEmpty,
      );
    },
  );

  test(
    'Supabase transport sends identical payload after unknown acknowledgement and validates returned IDs',
    () async {
      final sent = <Map<String, dynamic>>[];
      var mismatch = false;
      final client = SupabaseClient(
        'https://project.supabase.co',
        'public',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/resolve_family_creation');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          sent.add(body);
          if (sent.length == 1) {
            return http.Response(
              '{"code":"503","message":"unknown"}',
              503,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          final command = body['command'] as Map;
          return http.Response(
            jsonEncode({
              'request_id': body['request_id'],
              'family_id': command['family_id'],
              'child_id': mismatch ? 'wrong' : command['child_id'],
              'status': 'created',
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final actual = FamilyCreationRepository(
        store: store,
        accountId: () => owner,
        remote: SupabaseFamilyCreationRemote(client),
      );
      final draft = await prepare(actual);
      await expectLater(
        actual.resolve(null, draft.requestId, 'submit'),
        throwsA(isA<PostgrestException>()),
      );
      expect(
        (await actual.resolve(null, draft.requestId, 'submit')).status,
        'created',
      );
      expect(sent[0], sent[1]);
      mismatch = true;
      await expectLater(
        actual.resolve(null, draft.requestId, 'inspect'),
        throwsStateError,
      );
      expect((await actual.pending(null))!.status, 'created');
    },
  );

  testWidgets(
    'restored creation is frozen and a lost reply resolves without duplicate submit',
    (tester) async {
      await tester.runAsync(() async {
        final draft = await prepare(repository);
        remote.loseReply = true;
        await expectLater(
          repository.resolve(null, draft.requestId, 'submit'),
          throwsA(isA<SocketException>()),
        );
      });
      final families = FakeFamilyRepository();
      await databaseAction(
        tester,
        () => tester.pumpWidget(
          ProviderScope(
            overrides: [
              familyRepositoryProvider.overrideWithValue(families),
              familyCreationRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: buildAppTheme(),
              home: const FamilyCreationScreen(),
            ),
          ),
        ),
      );
      expect(find.text('有一条待确认的创建请求'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      await databaseAction(tester, () => tester.tap(find.text('核对并重试')));
      expect(find.text('创建成功，已保留服务器回执'), findsOneWidget);
      expect(remote.calls, ['submit', 'inspect']);
      expect(remote.created, 1);
      await databaseAction(tester, () => tester.tap(find.text('查看已创建的档案')));
      expect(find.textContaining('家庭列表暂未更新'), findsOneWidget);
      expect(
        (await tester.runAsync(() => repository.pending(null)))!.status,
        'created',
      );
      expect(find.byType(TextFormField), findsNothing);
    },
  );

  testWidgets(
    'pending child profile is hidden when parent PIN expires and resumes after renewal',
    (tester) async {
      final draft = (await tester.runAsync(
        () => prepare(repository, familyId: 'family'),
      ))!;
      final container = ProviderContainer(
        overrides: [
          familyRepositoryProvider.overrideWithValue(FakeFamilyRepository()),
          familyCreationRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await databaseAction(
        tester,
        () => tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildAppTheme(),
              home: const FamilyCreationScreen(familyId: 'family'),
            ),
          ),
        ),
      );
      expect(find.textContaining('孩子：小星星'), findsNothing);
      container.read(parentModeProvider.notifier).state = true;
      container.read(parentFamilyIdProvider.notifier).state = 'family';
      container.read(parentAuthorizedUntilProvider.notifier).state =
          DateTime.now().add(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(find.textContaining('孩子：小星星'), findsOneWidget);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.textContaining('孩子：小星星'), findsNothing);
      expect(
        (await tester.runAsync(() => repository.pending('family')))!.requestId,
        draft.requestId,
      );
      expect(remote.calls, isEmpty);
    },
  );

  testWidgets(
    'modifying an unconfirmed request checks server first and retains original input',
    (tester) async {
      await tester.runAsync(() => prepare(repository));
      await databaseAction(
        tester,
        () => tester.pumpWidget(
          ProviderScope(
            overrides: [
              familyRepositoryProvider.overrideWithValue(
                FakeFamilyRepository(),
              ),
              familyCreationRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: buildAppTheme(),
              home: const FamilyCreationScreen(),
            ),
          ),
        ),
      );
      await tester.tap(find.text('修改填写内容'));
      await tester.pumpAndSettle();
      await databaseAction(tester, () => tester.tap(find.text('核对并修改')));
      expect(remote.calls, ['cancel']);
      expect(remote.created, 0);
      expect(await tester.runAsync(() => repository.pending(null)), isNull);
      expect(find.text('小星星'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new family form persists before submission, restores after closing, and acknowledges only a visible child',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final families = FakeFamilyRepository();
      Widget screen() => ProviderScope(
        overrides: [
          familyRepositoryProvider.overrideWithValue(families),
          familyCreationRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.2)),
            child: child!,
          ),
          home: const FamilyOnboardingScreen(),
        ),
      );
      await databaseAction(tester, () => tester.pumpWidget(screen()));
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.enterText(field('家庭名称'), '测试家庭');
      await tester.enterText(field('孩子昵称'), '小星星');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.ensureVisible(find.text('创建并开始'));
      await tester.pumpAndSettle();
      remote.loseReply = true;
      await databaseAction(tester, () => tester.tap(find.text('创建并开始')));
      final original = (await tester.runAsync(() => repository.pending(null)))!;
      expect(original.command['family_name'], '测试家庭');
      expect(original.command['nickname'], '小星星');
      expect(remote.created, 1);
      expect(original.status, 'pending');
      await tester.pumpWidget(const SizedBox.shrink());
      await databaseAction(tester, () => tester.pumpWidget(screen()));
      expect(find.text('有一条待确认的创建请求'), findsOneWidget);
      await databaseAction(tester, () => tester.tap(find.text('核对并重试')));
      expect(remote.calls, ['submit', 'inspect']);
      families.families.add(
        Family(
          id: original.familyId,
          name: '测试家庭',
          timezone: 'Asia/Shanghai',
          children: [
            ChildProfile(
              id: original.childId,
              familyId: original.familyId,
              nickname: '小星星',
              grade: 1,
            ),
          ],
        ),
      );
      await databaseAction(tester, () => tester.tap(find.text('查看已创建的档案')));
      expect(await tester.runAsync(() => repository.pending(null)), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'modify request after a lost success keeps created profile and refuses a second form',
    (tester) async {
      final draft = (await tester.runAsync(() => prepare(repository)))!;
      await tester.runAsync(() => remote.resolve(draft, 'submit'));
      await databaseAction(
        tester,
        () => tester.pumpWidget(
          ProviderScope(
            overrides: [
              familyRepositoryProvider.overrideWithValue(
                FakeFamilyRepository(),
              ),
              familyCreationRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: buildAppTheme(),
              home: const FamilyCreationScreen(),
            ),
          ),
        ),
      );
      await tester.tap(find.text('修改填写内容'));
      await tester.pumpAndSettle();
      await databaseAction(tester, () => tester.tap(find.text('核对并修改')));
      expect(find.text('创建成功，已保留服务器回执'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(
        (await tester.runAsync(() => repository.pending(null)))!.status,
        'created',
      );
      expect(remote.created, 1);
    },
  );

  testWidgets(
    'deleted or inaccessible receipt erases local profile text and hides its preview',
    (tester) async {
      final draft = (await tester.runAsync(() => prepare(repository)))!;
      remote.receipts[draft.requestId] = {
        'request_id': draft.requestId,
        'family_id': draft.familyId,
        'child_id': draft.childId,
        'status': 'unavailable',
      };
      await databaseAction(
        tester,
        () => tester.pumpWidget(
          ProviderScope(
            overrides: [
              familyRepositoryProvider.overrideWithValue(
                FakeFamilyRepository(),
              ),
              familyCreationRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: buildAppTheme(),
              home: const FamilyCreationScreen(),
            ),
          ),
        ),
      );
      await databaseAction(tester, () => tester.tap(find.text('核对并重试')));
      expect(find.textContaining('原档案已删除'), findsOneWidget);
      expect(find.textContaining('小星星'), findsNothing);
      expect(await tester.runAsync(() => repository.pending(null)), isNull);
      expect(remote.calls, ['inspect']);
      expect(remote.created, 0);
    },
  );
}

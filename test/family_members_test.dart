import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/family_members_repository.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/presentation/family_members_screen.dart';
import 'family_creation_test.dart' show databaseAction;
import 'widget_test.dart' as fixture;

Map<String, dynamic> roster({bool admin = true}) => {
  'family_id': 'family',
  'viewer_id': 'parent',
  'can_manage': admin,
  'members': [
    {
      'user_id': 'parent',
      'email': 'parent@example.test',
      'role': admin ? 'admin' : 'parent',
      'is_self': true,
      'is_owner': admin,
    },
    {
      'user_id': 'other',
      'email': admin ? 'other@example.test' : 'o***@example.test',
      'role': 'parent',
      'is_self': false,
      'is_owner': false,
    },
  ],
  'invitations': admin
      ? [
          {
            'id': 'invitation',
            'email': 'pending@example.test',
            'version': 3,
            'expires_at': '2026-10-01T12:00:00Z',
            'expired': true,
          },
        ]
      : [],
};

class _Remote implements FamilyMembersRemote {
  Map<String, dynamic> data = roster();
  final receipts = <String, Map<String, dynamic>>{};
  final calls = <(String, String)>[];
  bool loseReply = false, badReceipt = false;
  int applied = 0, loads = 0;
  Completer<void>? wait, loadWait;
  @override
  Future<Map<String, dynamic>> load(String familyId) async {
    loads++;
    await loadWait?.future;
    return data;
  }

  @override
  Future<Map<String, dynamic>> resolve(
    FamilyInvitationRequest request,
    String operation,
  ) async {
    calls.add((request.requestId, operation));
    await wait?.future;
    if (!receipts.containsKey(request.requestId) && operation != 'inspect') {
      if (operation == 'submit') applied++;
      receipts[request.requestId] = {
        'request_id': request.requestId,
        'family_id': request.familyId,
        'kind': request.command['kind'],
        'status': operation == 'submit' ? 'applied' : 'abandoned',
      };
    }
    if (loseReply) {
      loseReply = false;
      throw const SocketException('private server detail');
    }
    return badReceipt
        ? {'request_id': 'wrong', 'status': 'applied'}
        : receipts[request.requestId] ??
              {
                'request_id': request.requestId,
                'family_id': request.familyId,
                'kind': request.command['kind'],
                'status': 'unknown',
              };
  }
}

class _Auth extends fixture.FakeAuthRepository {
  AuthSession? session = const AuthSession(userId: 'parent');
  final changes = StreamController<AuthSession?>.broadcast();
  @override
  AuthSession? get currentSession => session;
  @override
  Stream<AuthSession?> watchSession() async* {
    yield session;
    yield* changes.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineStore store;
  late _Remote remote;
  late FamilyMembersRepository repository;
  String? owner;
  late bool authorized;
  late int revision;
  FamilyMembersRepository make(OfflineStore db) => FamilyMembersRepository(
    store: db,
    remote: remote,
    accountId: () => owner,
    isAuthorized: (_) => authorized,
    authorizationRevision: () => revision,
  );
  Future<FamilyInvitationRequest> prepare() => repository.prepare('family', {
    'kind': 'invite',
    'email': 'new@example.test',
  });
  setUp(() async {
    store = OfflineStore(NativeDatabase.memory());
    await store.customSelect('SELECT 1').get();
    remote = _Remote();
    owner = 'parent';
    authorized = true;
    revision = 1;
    repository = make(store);
  });
  tearDown(() => store.close());

  test(
    'invitation intent persists before network, immutable and restored after database reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('family-invitation-');
      final file = File('${dir.path}/cache.sqlite');
      final disk = OfflineStore(NativeDatabase(file));
      final first = make(disk);
      final command = {'kind': 'invite', 'email': 'original@example.test'};
      final future = first.prepare('family', command);
      command['email'] = 'changed@example.test';
      final request = await future;
      request.command['email'] = 'mutated@example.test';
      expect(request.command['email'], 'original@example.test');
      expect(remote.calls, isEmpty);
      await disk.close();
      final reopened = OfflineStore(NativeDatabase(file));
      try {
        final restored = (await make(reopened).pending('family'))!;
        expect(restored.toJson(), request.toJson());
        expect(restored.toJson().toString(), isNot(contains('PIN')));
      } finally {
        await reopened.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'lost reply is inspected with original id; pending cannot be dismissed or replaced',
    () async {
      final request = await prepare();
      remote.loseReply = true;
      await expectLater(
        repository.resolve('family', request.requestId, 'submit'),
        throwsA(isA<SocketException>()),
      );
      expect((await repository.pending('family'))!.status, 'pending');
      await expectLater(
        repository.dismiss('family', request.requestId),
        throwsStateError,
      );
      await expectLater(prepare(), throwsStateError);
      final result = await repository.resolve(
        'family',
        request.requestId,
        'inspect',
      );
      expect(result.status, 'applied');
      expect(remote.applied, 1);
      expect(remote.calls.map((c) => c.$1).toSet(), {request.requestId});
      await repository.dismiss('family', request.requestId);
      expect(await repository.pending('family'), isNull);
      expect((await prepare()).requestId, isNot(request.requestId));
    },
  );
  test(
    'unknown status preserves pending and cancel barrier prevents later application',
    () async {
      final request = await prepare();
      expect(
        (await repository.resolve(
          'family',
          request.requestId,
          'inspect',
        )).status,
        'pending',
      );
      expect(
        (await repository.resolve(
          'family',
          request.requestId,
          'cancel',
        )).status,
        'abandoned',
      );
      expect(
        (await repository.resolve(
          'family',
          request.requestId,
          'submit',
        )).status,
        'abandoned',
      );
      expect(remote.applied, 0);
      await repository.dismiss('family', request.requestId);
    },
  );
  test(
    'mismatched receipt and roster never become trusted local results',
    () async {
      final request = await prepare();
      remote.badReceipt = true;
      await expectLater(
        repository.resolve('family', request.requestId, 'submit'),
        throwsStateError,
      );
      expect((await repository.pending('family'))!.status, 'pending');
      remote.data = {...roster(), 'viewer_id': 'other'};
      await expectLater(repository.load('family'), throwsStateError);
      remote.data = {...roster(), 'family_id': 'other'};
      await expectLater(repository.load('family'), throwsStateError);
    },
  );
  for (final boundary in [
    'account',
    'PIN',
    'revision',
    'privacy',
    'deletion',
  ]) {
    test('late invitation reply cannot cross $boundary boundary', () async {
      final request = await prepare();
      remote.wait = Completer<void>();
      final result = repository.resolve('family', request.requestId, 'submit');
      final check = expectLater(result, throwsStateError);
      while (remote.calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      switch (boundary) {
        case 'account':
          owner = 'other';
        case 'PIN':
          authorized = false;
        case 'revision':
          revision++;
        case 'privacy':
          store.privacyGeneration++;
        case 'deletion':
          await store.removeAccountData('parent', 'delete-job');
      }
      remote.wait!.complete();
      await check;
      expect(await store.read('other', 'invitation-command:family'), isNull);
      final saved = await store.read('parent', 'invitation-command:family');
      expect(saved?['status'], boundary == 'deletion' ? null : 'pending');
    });
  }
  test(
    'concurrent prepare accepts one and account isolation preserves other requests',
    () async {
      final values = await Future.wait([
        prepare().then((_) => true, onError: (_) => false),
        prepare().then((_) => true, onError: (_) => false),
      ]);
      expect(values.where((v) => v), hasLength(1));
      owner = 'other';
      expect(await repository.pending('family'), isNull);
      await prepare();
      owner = 'parent';
      expect(await repository.pending('family'), isNotNull);
      authorized = false;
      await expectLater(repository.load('family'), throwsStateError);
      expect(remote.loads, 0);
    },
  );
  test(
    'successful family refresh prunes only removed family intents for the same owner; late replies cannot recreate them',
    () async {
      final request = await prepare();
      await store.write('parent', 'invitation-command:kept', {
        'status': 'pending',
      });
      await store.write('other', 'invitation-command:family', {
        'status': 'pending',
      });
      await store.write('parent', 'creation:family', {'status': 'pending'});
      remote.wait = Completer<void>();
      final future = repository.resolve('family', request.requestId, 'submit');
      final result = expectLater(future, throwsStateError);
      while (remote.calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await store.pruneFamilyInvitations('parent', {'kept'});
      remote.wait!.complete();
      await result;
      expect(await repository.pending('family'), isNull);
      expect(await store.read('parent', 'invitation-command:kept'), isNotNull);
      expect(await store.read('other', 'invitation-command:family'), isNotNull);
      expect(await store.read('parent', 'creation:family'), isNotNull);
    },
  );
  test(
    'Supabase adapter sends scoped RPCs and exact durable command without authorization material',
    () async {
      final calls = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-test-key',
        httpClient: MockClient((request) async {
          calls.add(request);
          if (request.url.path.endsWith('load_family_members')) {
            return http.Response(
              jsonEncode(roster()),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          final body = jsonDecode(request.body) as Map;
          return http.Response(
            jsonEncode({
              'request_id': body['request_id'],
              'family_id': body['target_family_id'],
              'kind': (body['command'] as Map)['kind'],
              'status': 'applied',
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final adapter = SupabaseFamilyMembersRemote(client);
      expect((await adapter.load('family'))['viewer_id'], 'parent');
      final request = await prepare();
      await adapter.resolve(request, 'submit');
      expect(jsonDecode(calls[0].body), {'target_family_id': 'family'});
      expect(jsonDecode(calls[1].body), {
        'target_family_id': 'family',
        'request_id': request.requestId,
        'command': request.command,
        'operation': 'submit',
      });
      final removal = FamilyInvitationRequest({
        'request_id': 'removal',
        'family_id': 'family',
        'status': 'pending',
        'display_label': 'other@example.test',
        'command': {'kind': 'remove', 'user_id': 'other', 'version': 7},
      });
      await adapter.resolve(removal, 'submit');
      expect(calls.last.url.path, endsWith('/resolve_family_member_removal'));
      expect(jsonDecode(calls.last.body), {
        'target_family_id': 'family',
        'request_id': 'removal',
        'command': removal.command,
        'operation': 'submit',
      });
      await client.dispose();
    },
  );

  Future<ProviderContainer> show(
    WidgetTester tester, {
    _Auth? auth,
    double scale = 1,
  }) async {
    final source = auth ?? _Auth();
    addTearDown(source.changes.close);
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(source),
        familyRepositoryProvider.overrideWithValue(
          fixture.FakeFamilyRepository.withChild(),
        ),
        familyMembersRepositoryProvider.overrideWithValue(repository),
        authorizationClockProvider.overrideWith(
          (ref) => Stream.value(DateTime.now()),
        ),
      ],
    );
    container.read(parentFamilyIdProvider.notifier).state = 'family';
    container.read(parentModeProvider.notifier).state = true;
    container.read(parentAuthorizedUntilProvider.notifier).state =
        DateTime.now().add(const Duration(minutes: 5));
    addTearDown(container.dispose);
    await databaseAction(
      tester,
      () => tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const FamilyMembersScreen(familyId: 'family'),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('ordinary parent can read roster without invitation controls', (
    tester,
  ) async {
    remote.data = roster(admin: false);
    await show(tester);
    expect(find.text('o***@example.test'), findsOneWidget);
    expect(find.text('创建邀请'), findsNothing);
    expect(find.text('撤销邀请'), findsNothing);
    expect(find.textContaining('其他成员的邮箱已作隐藏处理'), findsOneWidget);
  });
  testWidgets(
    'member removal confirms identity, preserves original version on lost reply, and never offers removal of admin',
    (tester) async {
      remote.data = roster();
      (remote.data['members'] as List)[0]['can_remove'] = true;
      (remote.data['members'] as List)[0]['version'] = 1;
      (remote.data['members'] as List)[1]['can_remove'] = true;
      (remote.data['members'] as List)[1]['version'] = 7;
      await show(tester);
      expect(find.text('移除家长'), findsOneWidget);
      await tester.tap(find.text('移除家长'));
      await tester.pumpAndSettle();
      expect(find.textContaining('孩子、任务和奖励仍会保留'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(remote.calls, isEmpty);
      await tester.tap(find.text('移除家长'));
      await tester.pumpAndSettle();
      remote.loseReply = true;
      await databaseAction(tester, () => tester.tap(find.text('确认')));
      final request = (await tester.runAsync(
        () => repository.pending('family'),
      ))!;
      expect(request.command, {
        'kind': 'remove',
        'user_id': 'other',
        'version': 7,
      });
      expect(request.displayLabel, 'other@example.test');
      expect(find.text('移除成员：other@example.test'), findsOneWidget);
      await databaseAction(tester, () => tester.tap(find.text('重试原请求')));
      expect(remote.applied, 1);
      expect(remote.calls.last, (request.requestId, 'inspect'));
    },
  );
  testWidgets(
    'admin validates email and lost response restores exact request for inspection',
    (tester) async {
      await show(tester);
      await tester.enterText(find.byType(TextFormField), 'bad');
      await tester.tap(find.text('创建邀请'));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效邮箱'), findsOneWidget);
      expect(remote.calls, isEmpty);
      await tester.enterText(find.byType(TextFormField), ' NEW@example.test ');
      remote.loseReply = true;
      await databaseAction(tester, () => tester.tap(find.text('创建邀请')));
      expect(find.text('核对结果'), findsOneWidget);
      expect(find.textContaining('private server detail'), findsNothing);
      final request = (await tester.runAsync(
        () => repository.pending('family'),
      ))!;
      expect(request.command['email'], 'new@example.test');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await show(tester);
      expect(find.text('重试原请求'), findsOneWidget);
      await databaseAction(tester, () => tester.tap(find.text('重试原请求')));
      expect(remote.applied, 1);
      expect(remote.calls.last, (request.requestId, 'inspect'));
      expect(find.text('操作已确认，请以最新成员和邀请列表为准。'), findsOneWidget);
      await databaseAction(tester, () => tester.tap(find.text('继续')));
      expect(await tester.runAsync(() => repository.pending('family')), isNull);
    },
  );
  testWidgets(
    'PIN expiry hides roster and invitation confirmation; reauthorization cannot submit old dialog',
    (tester) async {
      final container = await show(tester);
      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, '撤销邀请'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销邀请'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已加入的成员不会被移除'), findsOneWidget);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.textContaining('pending@example.test'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认'))
            .onPressed,
        isNull,
      );
      container.read(parentModeProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(remote.calls, isEmpty);
    },
  );
  testWidgets('account change during load never displays previous members', (
    tester,
  ) async {
    final auth = _Auth();
    final container = await show(tester, auth: auth);
    remote.loadWait = Completer<void>();
    await tester.tap(find.byTooltip('刷新成员'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    auth.session = const AuthSession(userId: 'other');
    owner = 'other';
    auth.changes.add(auth.session);
    await tester.pumpAndSettle();
    remote.loadWait!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('parent@example.test'), findsNothing);
    expect(find.text('other@example.test'), findsNothing);
    container.read(parentModeProvider.notifier).state = false;
    await tester.pumpAndSettle();
  });
  testWidgets(
    'account switch while cancellation dialog is open hides email and blocks confirmation',
    (tester) async {
      final auth = _Auth();
      await show(tester, auth: auth);
      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, '撤销邀请'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销邀请'));
      await tester.pumpAndSettle();
      auth.session = const AuthSession(userId: 'other');
      owner = 'other';
      auth.changes.add(auth.session);
      await tester.pumpAndSettle();
      expect(find.textContaining('pending@example.test'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(remote.calls, isEmpty);
    },
  );
  testWidgets(
    '360px at double text size can reach renewal and cancel without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, scale: 2);
      await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, '续期7天'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('续期7天'));
      await tester.pumpAndSettle();
      expect(find.textContaining('延长至操作成功后的7天'), findsOneWidget);
      await databaseAction(tester, () => tester.tap(find.text('确认')));
      expect(remote.applied, 1);
      expect(
        (await tester.runAsync(() => repository.pending('family')))!.command,
        {'kind': 'renew', 'invitation_id': 'invitation', 'version': 3},
      );
      expect(tester.takeException(), isNull);
    },
  );
}

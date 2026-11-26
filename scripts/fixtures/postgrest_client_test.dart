// Run only through scripts/test_postgrest.mjs. Actual app repositories and HTTP;
// sessions are synthetic and do not validate Supabase Auth/email or Storage.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/auth_family/data/family_time_repository.dart';
import 'package:learning_planet/features/auth_family/domain/parent_authorization_clock.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_start_origin.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_confidence.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class FaultTransport extends http.BaseClient {
  final http.Client inner = http.Client();
  bool offline = false, loseAnswerReply = false;
  bool loseManualSaveReply = false;
  int lostReplies = 0;
  final paths = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.pathSegments.last);
    if (offline) throw http.ClientException('Injected offline transport');
    final response = await inner.send(request);
    if (loseManualSaveReply &&
        request.url.path.endsWith('/rpc/save_manual_review_question') &&
        response.statusCode == 200) {
      loseManualSaveReply = false;
      await response.stream.drain<void>();
      lostReplies++;
      throw http.ClientException(
        'Injected reply loss after manual question save',
      );
    }
    if (loseAnswerReply &&
        request.url.path.endsWith('/rpc/apply_task_command') &&
        request is http.Request &&
        jsonDecode(request.body)['command']['kind'] == 'review_answer') {
      loseAnswerReply = false;
      if (response.statusCode != 200) return response;
      await response.stream.drain<void>();
      lostReplies++;
      throw http.ClientException('Injected reply loss after server commit');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final raw = Platform.environment['LP_HTTP_CONFIG'];
  if (raw == null) throw StateError('Run node scripts/test_postgrest.mjs');
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final url = config['url'] as String;
  final uri = Uri.parse(url);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('This test only supports a disposable loopback backend');
  }
  const uuid = Uuid();
  final clients = <SupabaseClient>[];
  Future<SupabaseClient> connect(
    String? identity, {
    http.Client? transport,
  }) async {
    final client = SupabaseClient(
      url,
      config['anon'] as String,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: transport,
    );
    clients.add(client);
    if (identity != null) {
      final value = config[identity] as Map<String, dynamic>;
      await client.auth.recoverSession(
        jsonEncode({
          'access_token': value['token'],
          'token_type': 'bearer',
          'expires_in': 1800,
          'refresh_token': 'synthetic-test-only',
          'user': {
            'id': value['id'],
            'email': value['email'],
            'aud': 'authenticated',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'app_metadata': <String, dynamic>{},
          },
        }),
      );
    }
    return client;
  }

  late SupabaseClient parent, peer, other, anon;
  late SupabaseFamilyRepository families;
  late String family;
  setUpAll(() async {
    parent = await connect('parent');
    peer = await connect('peer');
    other = await connect('other');
    anon = await connect(null);
    families = SupabaseFamilyRepository(parent);
    await families.createFamilyWithChild(
      familyName: '星球 HTTP 验证',
      timezone: 'Asia/Shanghai',
      childNickname: '小星',
      grade: 2,
      textbookLabels: const {'math': '人教版'},
    );
    final result = (await families.loadFamilies()).single;
    family = result.id;
    expect(result.name, '星球 HTTP 验证');
    expect(result.children.single.textbookLabels, {'math': '人教版'});
    await families.setParentPin(familyId: family, pin: '2468');
  });
  tearDownAll(() async {
    for (final client in clients.reversed) {
      await client.dispose();
    }
  });
  Future<String> child(String name) async {
    await families.createChild(familyId: family, nickname: name, grade: 2);
    return (await families.loadFamilies()).single.children
        .singleWhere((c) => c.nickname == name)
        .id;
  }

  test('embedded and parent row caps preserve tied order and RLS', () async {
    final transport = FaultTransport();
    final active = await connect('large', transport: transport);
    final capped = await active
        .from('families')
        .select('id,children(id)')
        .order('created_at')
        .order('id');
    expect(capped, hasLength(1000));
    expect(capped.first['children'], hasLength(1000));
    transport.paths.clear();
    final expected = ['1', for (var i = 1001; i >= 2; i--) i.toString()];
    final listing = await SupabaseFamilyRepository(active).loadFamilies();
    expect(listing.map((family) => family.name), expected);
    expect(listing.first.children.map((child) => child.nickname), expected);
    expect(listing.skip(1).every((family) => family.children.isEmpty), isTrue);
    expect(transport.paths, [
      'accept_family_invitations',
      'families',
      'children',
      'families',
    ]);
    expect(await SupabaseFamilyRepository(other).loadFamilies(), isEmpty);
    await expectLater(
      SupabaseFamilyRepository(anon).loadFamilies(),
      throwsA(isA<PostgrestException>()),
    );
  });

  test(
    'session PIN, anonymous and cross-family access use real HTTP roles',
    () async {
      await expectLater(
        families.createChild(familyId: family, nickname: 'blocked', grade: 2),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      final verification = await families.verifyParentPin(
        familyId: family,
        pin: '2468',
      );
      expect(verification.verified, isTrue);
      expect(
        verification.authorizedUntil!.isAfter(
          ParentAuthorizationClock.device.now(),
        ),
        isTrue,
      );
      expect(await SupabaseFamilyRepository(other).loadFamilies(), isEmpty);
      await expectLater(
        SupabaseFamilyRepository(
          peer,
        ).createChild(familyId: family, nickname: 'blocked peer', grade: 2),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      await expectLater(
        anon.rpc<dynamic>(
          'family_time_settings',
          params: {'target_family_id': family},
        ),
        throwsA(isA<PostgrestException>()),
      );
      await expectLater(
        parent.from('families').update({'timezone': 'UTC'}).eq('id', family),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
    },
  );

  test(
    'expired or forged JWT and private settlement RPC cannot bypass HTTP authorization',
    () async {
      final token = (config['parent'] as Map)['token'] as String;
      final parts = token.split('.');
      parts[2] =
          '${parts[2].startsWith('A') ? 'B' : 'A'}${parts[2].substring(1)}';
      for (final invalid in [config['expired'] as String, parts.join('.')]) {
        final response = await http.get(
          Uri.parse('$url/rest/v1/families'),
          headers: {'Authorization': 'Bearer $invalid'},
        );
        expect(response.statusCode, 401);
      }
      final response = await http.post(
        Uri.parse('$url/rest/v1/rpc/submit_review_answer_with_confidence'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'target_task_id': uuid.v4(),
          'target_question_id': uuid.v4(),
          'answer': '4',
          'command_id': uuid.v4(),
          'completion_at': null,
          'answer_confidence': 3,
        }),
      );
      expect(response.statusCode, anyOf(401, 403, 404));
    },
  );

  test(
    'task repositories generate, pause, resume and settle exactly once over HTTP',
    () async {
      final id = await child('任务 HTTP');
      final tasks = SupabaseTaskRepository(parent);
      final today = await parent.rpc<String>(
        'family_today',
        params: {'target_child_id': id},
      );
      await tasks.createOneTimeTask(
        childId: id,
        title: '阅读 中文与 emoji 🌟',
        dueDate: DateTime.parse(today),
        coinReward: 20,
        xpReward: 30,
      );
      final task = (await tasks.loadTasks(id)).single;
      expect(task.title, '阅读 中文与 emoji 🌟');
      await tasks.start(task.id);
      await tasks.pause(task.id);
      expect((await tasks.loadTasks(id)).single.status, TaskStatus.paused);
      await tasks.resume(task.id);
      await tasks.complete(task.id);
      await tasks.complete(task.id);
      expect((await tasks.loadTasks(id)).single.status, TaskStatus.completed);
      final wallet = await tasks.loadWallet(id);
      expect(wallet.coins, 20);
      expect(wallet.xp, 30);
      expect(await other.from('wallets').select().eq('child_id', id), isEmpty);
    },
  );

  test(
    'resubmitting a manual question after a lost HTTP reply preserves a single record',
    () async {
      final transport = FaultTransport();
      final client = await connect('parent', transport: transport);
      final reviews = SupabaseReviewRepository(client);
      final id = await child('保存重试');
      final requestId = uuid.v4();
      const draft = {
        'kind': 'question',
        'subject': 'math',
        'prompt': '6 × 7 = ?',
        'answers': ['42'],
      };
      transport.loseManualSaveReply = true;
      await expectLater(
        reviews.save(id, draft, requestId: requestId),
        throwsA(isA<http.ClientException>()),
      );
      expect(transport.lostReplies, 1);
      final saved = (await reviews.questions(id)).single;
      await reviews.save(id, draft, requestId: requestId);
      final replay = (await reviews.questions(id)).single;
      expect(replay['id'], saved['id']);
      expect(replay['content_version'], saved['content_version']);
    },
  );

  test(
    'another session can change the daily preview up to first start',
    () async {
      final id = await child('双端复习清单');
      final editor = SupabaseReviewRepository(parent);
      final reader = SupabaseReviewRepository(peer);
      final tasks = SupabaseTaskRepository(peer);
      Future<void> save(String prompt, String answer, {String? question}) =>
          editor.save(id, {
            'kind': 'question',
            'subject': 'math',
            'prompt': prompt,
            'answers': [answer],
          }, questionId: question);
      List<Map<String, dynamic>> items(Map<String, dynamic> snapshot) =>
          (snapshot['items'] as List).cast<Map<String, dynamic>>();

      await save('1 + 1', '2');
      final taskId = (await tasks.loadTasks(id)).single.id;
      final original = items(await reader.task(taskId)).single;
      await editor.archive(original['wrong_question_id'] as String, true);
      final withdrawn = await reader.task(taskId);
      expect(withdrawn['task']['review_waiting_for_due'], isTrue);
      expect(items(withdrawn), isEmpty);
      expect(await tasks.loadTasks(id), isEmpty);
      await save('2 + 2', '4');
      expect((await tasks.loadTasks(id)).single.id, taskId);
      final amended = items(await reader.task(taskId));
      expect(amended.map((q) => q['prompt']), ['2 + 2']);

      // No preview request between this edit and starting on the other device.
      await save('3 + 3', '6');
      await startReviewWithOrigin(reader, taskId, TaskStartOrigin.childMode);
      final started = await reader.task(taskId);
      expect(started['task']['status'], 'in_progress');
      final frozen = items(started);
      expect(
        frozen.map((q) => q['prompt']),
        unorderedEquals(['2 + 2', '3 + 3']),
      );

      final editedId = amended.single['wrong_question_id'] as String;
      await save('4 + 4', '8', question: editedId);
      await save('5 + 5', '10');
      expect((await tasks.loadTasks(id)).single.id, taskId);
      expect(items(await reader.task(taskId)), frozen);
      final graded = await reader.answer(taskId, editedId, '4', uuid.v4());
      expect(
        items(
          graded,
        ).singleWhere((q) => q['wrong_question_id'] == editedId)['result'],
        isTrue,
      );
      final remaining = frozen.singleWhere(
        (q) => q['wrong_question_id'] != editedId,
      );
      final done = await reader.answer(
        taskId,
        remaining['wrong_question_id'] as String,
        '6',
        uuid.v4(),
      );
      expect(done['task']['status'], 'completed');
      expect(items(done).every((q) => q['result'] == true), isTrue);
    },
  );

  test(
    'a restored review opens directly from the wrong-question book',
    () async {
      final id = await child('从错题本开始');
      final editor = SupabaseReviewRepository(parent);
      final store = OfflineStore(NativeDatabase.memory());
      final tasks = OfflineTaskRepository(
        store: store,
        remote: SupabaseTaskSyncRemote(peer),
        live: SupabaseTaskRepository(peer),
        accountId: () => peer.auth.currentUser?.id,
        autoSync: false,
      )..setForeground(false);
      final reviews = CachedReviewRepository(
        SupabaseReviewRepository(peer),
        store,
        tasks.accountId,
        tasks: tasks,
      );
      try {
        await editor.save(id, {
          'kind': 'question',
          'subject': 'math',
          'prompt': '5 + 5',
          'answers': ['10'],
        });
        final taskId = (await editor.overview(id))['task_id'] as String;
        final questionId = (await editor.questions(id)).single['id'] as String;
        await editor.archive(questionId, true);
        expect(await tasks.loadTasks(id), isEmpty);
        await editor.archive(questionId, false);
        expect((await reviews.overview(id))['task_id'], taskId);
        expect((await reviews.task(taskId))['task']['status'], 'ready');
        await startReviewWithOrigin(reviews, taskId, TaskStartOrigin.childMode);
        expect((await editor.task(taskId))['task']['status'], 'in_progress');
        await reviews.answer(taskId, questionId, '10', uuid.v4());
        await tasks.synchronize(id);
        await tasks.synchronize(id);
        final paid = await parent
            .from('ledger_entries')
            .select('asset_type,amount')
            .eq('source_id', taskId);
        expect(
          paid,
          unorderedEquals([
            {'asset_type': 'coin', 'amount': 15},
            {'asset_type': 'xp', 'amount': 15},
          ]),
        );
        expect((await editor.task(taskId))['task']['status'], 'completed');
      } finally {
        await tasks.dispose();
        await store.close();
      }
    },
  );

  test(
    'four/five-argument review overloads preserve confidence and automatically settle final answer',
    () async {
      final id = await child('复习 HTTP');
      final reviews = SupabaseReviewRepository(parent),
          tasks = SupabaseTaskRepository(parent);
      for (var index = 0; index < 3; index++) {
        await reviews.save(id, {
          'kind': 'question',
          'subject': 'math',
          'prompt': '2+2 = ? $index',
          'answers': ['4'],
        });
      }
      final task = (await tasks.loadTasks(id)).single;
      final snapshot = await reviews.task(task.id);
      final items = (snapshot['items'] as List).cast<Map<String, dynamic>>();
      await reviews.transition(task.id, 'start');
      for (var index = 0; index < 3; index++) {
        final result = await reviews.answer(
          task.id,
          items[index]['wrong_question_id'] as String,
          '4',
          uuid.v4(),
          confidence: index == 2 ? null : ReviewConfidence.values[index],
        );
        expect(
          result['task']['status'],
          index == 2 ? 'completed' : 'in_progress',
        );
        expect(
          result['items'][index]['answer_confidence'],
          index == 2 ? null : index + 1,
        );
      }
      await reviews.answer(
        task.id,
        items[0]['wrong_question_id'] as String,
        '4',
        uuid.v4(),
        confidence: ReviewConfidence.unsure,
      );
      await reviews.complete(task.id, uuid.v4());
      await expectLater(
        reviews.answer(
          task.id,
          items[0]['wrong_question_id'] as String,
          '4',
          uuid.v4(),
          confidence: ReviewConfidence.confident,
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect((await tasks.loadWallet(id)).coins, 45);
      expect((await tasks.loadWallet(id)).xp, 45);
      expect(
        (await reviews.questions(id)).map((q) => q['last_answer_confidence']),
        unorderedEquals([1, 2, null]),
      );
    },
  );

  test(
    'an offline answer stays with the original question until the child adopts the revised preview',
    () async {
      final id = await child('离线题单变更');
      final editor = SupabaseReviewRepository(parent);
      final transport = FaultTransport();
      final client = await connect('peer', transport: transport);
      final owner = client.auth.currentUser!.id;
      final store = OfflineStore(NativeDatabase.memory());
      final tasks = OfflineTaskRepository(
        store: store,
        remote: SupabaseTaskSyncRemote(client),
        live: SupabaseTaskRepository(client),
        accountId: () => client.auth.currentUser?.id,
        autoSync: false,
      )..setForeground(false);
      final reviews = CachedReviewRepository(
        SupabaseReviewRepository(client),
        store,
        tasks.accountId,
        tasks: tasks,
      );
      Future<void> setQuestion(
        String prompt,
        String answer, {
        String? questionId,
      }) => editor.save(id, {
        'kind': 'question',
        'subject': 'math',
        'prompt': prompt,
        'answers': [answer],
      }, questionId: questionId);
      Map<String, dynamic> onlyItem(Map<String, dynamic> snapshot) =>
          (snapshot['items'] as List).cast<Map<String, dynamic>>().single;

      try {
        await setQuestion('6 + 6', '12');
        final taskId = (await tasks.loadTasks(id)).single.id;
        final original = onlyItem(await reviews.task(taskId));
        final question = original['wrong_question_id'] as String;
        transport.offline = true;
        await startReviewWithOrigin(reviews, taskId, TaskStartOrigin.childMode);
        final saved = await reviews.answer(taskId, question, '12', uuid.v4());
        expect(saved['local_completion'], isTrue);

        // The same question ID now has a different prompt and answer key.
        await setQuestion('7 + 7', '14', questionId: question);
        transport.offline = false;
        await tasks.synchronize(id);
        final conflict = await reviews.task(taskId);
        expect(conflict['sync_conflict'], isTrue);
        expect(onlyItem(conflict)['prompt'], '6 + 6');
        expect(onlyItem(conflict)['conflict_answer'], '12');
        final server = await editor.task(taskId);
        expect(server['task']['status'], 'ready');
        expect(onlyItem(server)['prompt'], '7 + 7');
        expect(onlyItem(server)['result'], isNull);
        final remoteTasks = SupabaseTaskRepository(parent);
        expect((await remoteTasks.loadWallet(id)).coins, 0);

        await tasks.acceptServer(id, taskId);
        final adopted = await reviews.task(taskId);
        expect(onlyItem(adopted)['prompt'], '7 + 7');
        expect(onlyItem(adopted)['conflict_answer'], isNull);
        expect(await store.commands(owner), isEmpty);
        await startReviewWithOrigin(reviews, taskId, TaskStartOrigin.childMode);
        await reviews.answer(taskId, question, '14', uuid.v4());
        await tasks.synchronize(id);
        await tasks.synchronize(id);
        final done = await editor.task(taskId);
        expect(done['task']['status'], 'completed');
        expect(onlyItem(done)['result'], isTrue);
        final wallet = await remoteTasks.loadWallet(id);
        expect((wallet.coins, wallet.xp), (15, 15));
        final ledger = await parent
            .from('ledger_entries')
            .select('asset_type,amount')
            .eq('source_id', taskId);
        expect(
          ledger,
          unorderedEquals([
            {'asset_type': 'coin', 'amount': 15},
            {'asset_type': 'xp', 'amount': 15},
          ]),
        );
      } finally {
        await tasks.dispose();
        await store.close();
        transport.close();
      }
    },
  );

  test(
    'file outbox survives restart, clock correction and a lost HTTP answer reply without duplicate rewards',
    () async {
      final id = await child('离线 HTTP');
      final transport = FaultTransport();
      final client = await connect('parent', transport: transport);
      final live = SupabaseReviewRepository(client);
      await live.save(id, {
        'kind': 'question',
        'subject': 'math',
        'prompt': '2+2 = ?',
        'answers': ['4'],
      });
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-http-outbox-',
      );
      final file = File('${directory.path}/outbox.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      var deviceClockOffset = const Duration(days: 1);
      late OfflineTaskRepository tasks;
      late CachedReviewRepository reviews;
      void repositories() {
        tasks = OfflineTaskRepository(
          store: store,
          remote: SupabaseTaskSyncRemote(client),
          live: SupabaseTaskRepository(client),
          accountId: () => client.auth.currentUser?.id,
          clock: () => DateTime.now().add(deviceClockOffset),
          autoSync: false,
        )..setForeground(false);
        reviews = CachedReviewRepository(
          live,
          store,
          () => client.auth.currentUser?.id,
          tasks: tasks,
        );
      }

      repositories();
      try {
        final task = (await tasks.loadTasks(id)).single;
        final initial = await reviews.task(task.id);
        final question = initial['items'][0]['wrong_question_id'] as String;
        transport.offline = true;
        await reviews.transition(task.id, 'start');
        final local = await reviews.answer(
          task.id,
          question,
          '4',
          uuid.v4(),
          confidence: ReviewConfidence.somewhat,
        );
        expect(local['local_completion'], isTrue);
        expect((await tasks.loadWallet(id)).coins, 0);
        final owner = client.auth.currentUser!.id;
        final queued = await store.commands(owner);
        expect(queued.map((r) => (r['command'] as Map)['kind']), [
          'review_start',
          'review_answer',
          'review_complete',
        ]);
        await tasks.dispose();
        await store.close();
        store = OfflineStore(NativeDatabase(file));
        repositories();
        expect(await store.commands(owner), queued);
        transport.offline = false;
        transport.loseAnswerReply = true;
        await tasks.synchronize(id);
        expect(transport.lostReplies, 1);
        expect((await SupabaseTaskRepository(parent).loadWallet(id)).coins, 15);
        await tasks.dispose();
        await store.close();
        deviceClockOffset = Duration.zero;
        store = OfflineStore(NativeDatabase(file));
        repositories();
        await tasks.synchronize(id);
        expect(await store.commands(owner), isEmpty);
        expect((await tasks.loadWallet(id)).coins, 15);
        expect(
          (await reviews.task(task.id))['items'][0]['answer_confidence'],
          2,
        );
        await tasks.synchronize(id);
        expect((await SupabaseTaskRepository(parent).loadWallet(id)).coins, 15);
      } finally {
        await tasks.dispose();
        await store.close();
        transport.close();
        // Preserve disposable files for failure diagnosis; no workspace data is removed.
      }
    },
  );

  test(
    'timezone repository parses real JSON, replays original request and surfaces stale HTTP versions',
    () async {
      final settings = FamilyTimeRepository(
        remote: SupabaseFamilyTimeRemote(parent),
        accountId: () => parent.auth.currentUser?.id,
        isAuthorized: (_) => true,
        authorizationRevision: () => 0,
        changeConfiguration: (_, action) => action(),
      );
      final before = await settings.load(family);
      expect(before.timezone, 'Asia/Shanghai');
      final saved = await settings.save(before, 'America/Los_Angeles');
      expect(saved.version, before.version + 1);
      expect(
        (await settings.save(before, 'America/Los_Angeles')).version,
        saved.version,
      );
      await expectLater(
        settings.save(before, 'UTC'),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '40001'),
        ),
      );
      final restored = await settings.save(saved, 'Asia/Shanghai');
      expect(restored.version, before.version + 2);
    },
  );

  test(
    'PIN revocation affects the next pooled HTTP request and cannot be restored by JWT replay',
    () async {
      await families.revokeParentAuthorization();
      await expectLater(
        parent.rpc<dynamic>(
          'family_time_settings',
          params: {'target_family_id': family},
        ),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      expect((await families.loadFamilies()).single.id, family);
      final params = {'target_family_id': family, 'candidate_pin': '2468'};
      final legacy =
          (await parent.rpc<List<dynamic>>(
                'verify_parent_pin',
                params: params,
              )).single
              as Map<String, dynamic>;
      expect(
        legacy.keys,
        unorderedEquals([
          'verified',
          'remaining_attempts',
          'retry_at',
          'authorized_until',
        ]),
      );
      expect(legacy['verified'], isTrue);
      final timed =
          (await parent.rpc<List<dynamic>>(
                'verify_parent_pin_timed',
                params: params,
              )).single
              as Map<String, dynamic>;
      expect(timed['verified'], isTrue);
      final serverNow = DateTime.parse(timed['server_now'] as String);
      final expires = DateTime.parse(timed['authorized_until'] as String);
      expect(
        expires.difference(serverNow).inSeconds,
        inInclusiveRange(599, 600),
      );
      final context =
          (await parent.rpc<List<dynamic>>('account_deletion_context')).single
              as Map<String, dynamic>;
      expect(context['id'], family);
      expect(context['authorized'], isTrue);
      expect(DateTime.parse(context['authorized_until'] as String), expires);
      final checkedAt = DateTime.parse(context['server_now'] as String);
      expect(checkedAt.isBefore(serverNow), isFalse);
      expect(checkedAt.isBefore(expires), isTrue);
      final renewed = await families.verifyParentPin(
        familyId: family,
        pin: '2468',
      );
      expect(renewed.verified, isTrue);
      expect(
        (await parent.rpc<Map<String, dynamic>>(
          'family_time_settings',
          params: {'target_family_id': family},
        ))['timezone'],
        'Asia/Shanghai',
      );
    },
  );
}

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
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_confidence.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class FaultTransport extends http.BaseClient {
  final http.Client inner = http.Client();
  bool offline = false, loseAnswerReply = false;
  int lostReplies = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) throw http.ClientException('Injected offline transport');
    final response = await inner.send(request);
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
      expect(verification.authorizedUntil!.isAfter(DateTime.now()), isTrue);
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
    'file outbox survives restart and a lost HTTP answer reply without duplicate rewards',
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
      late OfflineTaskRepository tasks;
      late CachedReviewRepository reviews;
      void repositories() {
        tasks = OfflineTaskRepository(
          store: store,
          remote: SupabaseTaskSyncRemote(client),
          live: SupabaseTaskRepository(client),
          accountId: () => client.auth.currentUser?.id,
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

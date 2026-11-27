// Real email sessions and repositories against disposable Auth/PostgREST.
// Transport faults discard replies only after a real successful server commit.
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/email_otp.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';

class ConcurrentTransport extends http.BaseClient {
  final inner = http.Client();
  bool offline = false, loseCompletion = false;
  int lost = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) throw const SocketException('Controlled client network loss');
    final response = await inner.send(request);
    if (loseCompletion &&
        response.statusCode == 200 &&
        request.url.path.endsWith('/apply_task_command') &&
        request is http.Request &&
        (jsonDecode(request.body) as Map)['command']['kind'] == 'complete') {
      final bytes = await response.stream.toBytes();
      final result = jsonDecode(utf8.decode(bytes)) as Map;
      if (result['outcome'] == 'applied') {
        loseCompletion = false;
        lost++;
        throw http.ClientException('Reply lost after committed completion');
      }
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
        request: request,
        contentLength: bytes.length,
        reasonPhrase: response.reasonPhrase,
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

class ConcurrentDevice {
  ConcurrentDevice(this.client, this.network, this.file, this.child);
  final SupabaseClient client;
  final ConcurrentTransport network;
  final File file;
  final String child;
  late OfflineStore store;
  late OfflineTaskRepository tasks;
  bool opened = false;
  String get owner => client.auth.currentUser!.id;
  void open() {
    store = OfflineStore(NativeDatabase(file));
    tasks = OfflineTaskRepository(
      store: store,
      remote: SupabaseTaskSyncRemote(client),
      live: SupabaseTaskRepository(client),
      accountId: () => client.auth.currentUser?.id,
      autoSync: false,
    )..setForeground(false);
    opened = true;
  }

  Future<void> close() async {
    if (!opened) return;
    opened = false;
    await tasks.dispose();
    await store.close();
  }
}

void main() {
  final raw = Platform.environment['LP_CONCURRENT_CONFIG'];
  if (raw == null) throw StateError('Run npm run test:concurrency');
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final url = config['url'] as String, key = config['anon'] as String;
  final origin = Uri.parse(url);
  if (origin.scheme != 'http' || origin.host != '127.0.0.1') {
    throw StateError('Disposable loopback backend required');
  }
  const uuid = Uuid();
  final users =
      <({SupabaseClient client, ConcurrentTransport network, String email})>[];
  final authRepositories = <SupabaseAuthRepository>[];
  final devices = <ConcurrentDevice>[];
  final checks = <Map<String, dynamic>>[];
  late String family;
  late List<String> children;
  late Directory directory;
  final previousDatabaseWarning =
      driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  Future<void> account() async {
    final network = ConcurrentTransport();
    final client = SupabaseClient(
      url,
      key,
      httpClient: network,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final email = 'concurrency-${uuid.v4()}@example.test';
    users.add((client: client, network: network, email: email));
    final auth = SupabaseAuthRepository(
      client,
      emailOtp: EmailOtpTransport(
        () => GoTrueClient(
          url: '$url/auth/v1',
          headers: {'apikey': key},
          autoRefreshToken: false,
          flowType: AuthFlowType.implicit,
        ),
      ),
    );
    authRepositories.add(auth);
    await auth.sendEmailOtp(email);
    final mail = await http.get(
      Uri.parse('$url/__test/mail').replace(queryParameters: {'email': email}),
      headers: {'x-test-mailbox-key': config['mailboxKey'] as String},
    );
    expect(mail.statusCode, 200);
    await auth.verifyEmailOtp(
      email,
      (jsonDecode(mail.body) as Map)['code'] as String,
      isCurrent: () => true,
    );
  }

  Future<void> authorize(SupabaseClient client) async {
    expect(
      (await SupabaseFamilyRepository(
        client,
      ).verifyParentPin(familyId: family, pin: '2468')).verified,
      true,
    );
  }

  Future<Map<String, dynamic>> evidence(String child) async {
    final client = users.first.client;
    return {
      'wallet': await client.rpc(
        'wallet_overview',
        params: {'target_child_id': child},
      ),
      'ledger': await client
          .from('ledger_entries')
          .select('id,asset_type,amount,frozen_delta,source_type,source_id')
          .eq('child_id', child)
          .order('id'),
      'pending': await client
          .from('pending_coin_awards')
          .select('id,amount,status,source_id')
          .eq('child_id', child)
          .order('id'),
    };
  }

  Future<void> writeReport() async {
    await Directory('build/concurrency_integration').create(recursive: true);
    final report = {
      'passed': checks.length == 2,
      'runId': config['runId'],
      'checks': checks,
      'scope':
          'Four distinct parent sessions, two children with independent file-backed queues, two separate stock-test children, plus an unrelated account. Local HTTP only; no cloud or device acceptance.',
    };
    await File(
      'build/concurrency_integration/client.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  }

  setUpAll(() async {
    // Independent physical databases, never multiple executors for one file.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    for (var i = 0; i < 5; i++) {
      await account();
    }
    expect(
      users.map((u) => u.client.auth.currentUser!.id).toSet(),
      hasLength(5),
    );
    final parents = SupabaseFamilyRepository(users.first.client);
    await parents.createFamilyWithChild(
      familyName: '并发验证家庭',
      timezone: 'Asia/Shanghai',
      childNickname: '孩子甲',
      grade: 2,
    );
    family = (await parents.loadFamilies()).single.id;
    await parents.setParentPin(familyId: family, pin: '2468');
    await authorize(users.first.client);
    await parents.createChild(familyId: family, nickname: '孩子乙', grade: 2);
    children = (await parents.loadFamilies()).single.children
        .map((c) => c.id)
        .toList();
    expect(children, hasLength(2));
    for (final user in users.skip(1).take(3)) {
      await parents.inviteParent(familyId: family, email: user.email);
      expect(
        (await SupabaseFamilyRepository(user.client).loadFamilies()).single.id,
        family,
      );
      await authorize(user.client);
    }
    directory = await Directory.systemTemp.createTemp(
      'learning-planet-concurrency-',
    );
    for (var index = 0; index < 4; index++) {
      final user = users[index];
      devices.add(
        ConcurrentDevice(
          user.client,
          user.network,
          File('${directory.path}/device-$index.sqlite'),
          children[index ~/ 2],
        )..open(),
      );
    }
    expect(devices.map((d) => d.file.absolute.path).toSet(), hasLength(4));
  });
  tearDownAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        previousDatabaseWarning;
    for (final device in devices) {
      await device.close();
    }
    for (final auth in authRepositories) {
      await auth.dispose();
    }
    for (final user in users) {
      await user.client.dispose();
      user.network.close();
    }
  });

  test(
    'four offline queues compete, recover lost replies and reconcile twenty tasks',
    () async {
      final watch = Stopwatch()..start();
      final live = SupabaseTaskRepository(users.first.client);
      for (final child in children) {
        final snapshot = await SupabaseTaskSyncRemote(
          users.first.client,
        ).snapshot(child);
        final localTime = tz.TZDateTime.from(
          DateTime.parse(snapshot['server_at'] as String),
          tz.getLocation(snapshot['timezone'] as String),
        );
        final day = DateTime(localTime.year, localTime.month, localTime.day);
        for (var index = 0; index < 10; index++) {
          await live.createOneTimeTask(
            childId: child,
            title: '并发任务 $index',
            dueDate: day,
            coinReward: 25,
            xpReward: 20,
          );
        }
      }
      final originals = <List<Map<String, dynamic>>>[];
      // Every device reads the same initial versions before any device submits.
      await Future.wait(devices.map((d) => d.tasks.synchronize(d.child)));
      for (final device in devices) {
        final tasks = await device.tasks.loadTasks(device.child);
        expect(tasks, hasLength(10));
        device.network.offline = true;
        for (final task in tasks) {
          await device.tasks.start(task.id);
          await device.tasks.complete(task.id);
        }
        expect((await device.tasks.loadWallet(device.child)).coins, 0);
        final queued = await device.store.commands(device.owner);
        expect(queued, hasLength(20));
        originals.add(
          queued
              .map((r) => Map<String, dynamic>.from(r['command'] as Map))
              .toList(),
        );
        await device.close();
        device.open();
        expect(await device.store.commands(device.owner), queued);
        device.network.offline = false;
        device.network.loseCompletion = true;
      }
      var rounds = 0;
      for (; rounds < 8; rounds++) {
        await Future.wait(devices.map((d) => d.tasks.synchronize(d.child)));
        final pending = await Future.wait(
          devices.map(
            (d) async => (await d.store.commands(
              d.owner,
            )).where((r) => r['state'] == 'pending').length,
          ),
        );
        if (pending.every((count) => count == 0)) break;
      }
      expect(rounds, lessThan(8));
      final lost = devices.fold<int>(0, (sum, d) => sum + d.network.lost);
      expect(lost, greaterThanOrEqualTo(2));
      var conflicts = 0;
      for (final device in devices) {
        final queue = await device.store.commands(device.owner);
        final ids = queue.map((r) => r['task_id'] as String).toSet();
        conflicts += ids.length;
        for (final task in ids) {
          await device.tasks.acceptServer(device.child, task);
        }
        expect(await device.store.commands(device.owner), isEmpty);
        final tasks = await device.tasks.loadTasks(device.child);
        expect(tasks, hasLength(10));
        expect(
          tasks.every(
            (t) =>
                t.childId == device.child && t.status == TaskStatus.completed,
          ),
          true,
        );
      }
      expect(conflicts, greaterThan(0));
      final before = <String, Map<String, dynamic>>{};
      for (final child in children) {
        final state = before[child] = await evidence(child);
        final wallet = state['wallet'] as Map;
        expect(wallet['coin_balance'], 150);
        expect(wallet['frozen_balance'], 0);
        expect(wallet['xp'], 200);
        expect(wallet['reconciled'], true);
        final ledger = (state['ledger'] as List).cast<Map>();
        expect(ledger, hasLength(20));
        expect(
          ledger.map((r) => '${r['source_id']}:${r['asset_type']}').toSet(),
          hasLength(20),
        );
        expect(
          ledger.every((r) => r['source_type'] == 'task_completion'),
          true,
        );
        expect(
          (state['pending'] as List).fold<int>(
            0,
            (sum, r) => sum + (r['amount'] as int),
          ),
          100,
        );
      }
      // Reissue all original UUIDs, including both winning and conflicting chains.
      await Future.wait(
        List.generate(devices.length, (index) async {
          final device = devices[index];
          device.network.loseCompletion = false;
          for (final command in originals[index]) {
            final result = await SupabaseTaskSyncRemote(
              device.client,
            ).apply(command);
            expect([
              'applied',
              'already_completed',
              'conflict',
            ], contains(result['outcome']));
          }
        }),
      );
      for (final child in children) {
        expect(await evidence(child), before[child]);
        expect(
          await users.last.client
              .from('task_instances')
              .select('id')
              .eq('child_id', child),
          isEmpty,
        );
        expect(
          await users.last.client
              .from('ledger_entries')
              .select('id')
              .eq('child_id', child),
          isEmpty,
        );
        await expectLater(
          SupabaseTaskSyncRemote(users.last.client).snapshot(child),
          throwsA(isA<PostgrestException>()),
        );
      }
      checks.add({
        'name': 'task_sync',
        'devices': 4,
        'children': 2,
        'tasks': 20,
        'durableCommands': 80,
        'replayedCommands': 80,
        'lostCommittedReplies': lost,
        'conflictTasksResolved': conflicts,
        'syncRounds': rounds + 1,
        'perChild': {
          'coins': 150,
          'xp': 200,
          'pendingCoins': 100,
          'ledgerRows': 20,
        },
        'elapsedMs': watch.elapsedMilliseconds,
      });
      await writeReport();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'shared stock admits one winner and concurrent refunds return the exact amount once',
    () async {
      final economy = SupabaseEconomyRepository(users.first.client);
      final parents = SupabaseFamilyRepository(users.first.client);
      final stockChildren = <String>[];
      for (var index = 0; index < 2; index++) {
        final nickname = '兑换隔离孩子$index';
        await parents.createChild(
          familyId: family,
          nickname: nickname,
          grade: 2,
        );
        final child = (await parents.loadFamilies()).single.children
            .singleWhere((child) => child.nickname == nickname)
            .id;
        stockChildren.add(child);
        await economy.adjust(child, {
          'coins': 150,
          'xp_amount': 200,
          'reason': '并发兑换验证',
          'command_id': uuid.v4(),
        });
      }
      await economy.saveReward(family, {
        'title': '唯一名额',
        'cost': 100,
        'stock_total': 1,
      });
      final reward =
          (await economy.load(stockChildren.first, family))['rewards'][0]
              as Map;
      final keys = List.generate(4, (_) => uuid.v4());
      final outcomes = await Future.wait(
        List.generate(4, (index) async {
          try {
            await SupabaseEconomyRepository(devices[index].client).request(
              stockChildren[index ~/ 2],
              reward['id'] as String,
              keys[index],
              reward['version'] as int,
            );
            return true;
          } on PostgrestException catch (error) {
            expect(error.message, anyOf(contains('库存'), contains('可用金币不足')));
            return false;
          }
        }),
      );
      expect(outcomes.where((ok) => ok), hasLength(1));
      final winner = outcomes.indexOf(true), child = stockChildren[winner ~/ 2];
      final rows = await users.first.client
          .from('redemptions')
          .select()
          .eq('reward_id', reward['id']);
      expect(rows, hasLength(1));
      expect(rows.single['child_id'], child);
      final frozen = (await evidence(child))['wallet'];
      expect(frozen['coin_balance'], 50);
      expect(frozen['frozen_balance'], 100);
      await Future.wait(
        devices.map(
          (device) => SupabaseEconomyRepository(
            device.client,
          ).transition(rows.single['id'] as String, 'reject', '并发退回验证'),
        ),
      );
      final refunded = await evidence(child);
      expect(refunded['wallet']['coin_balance'], 150);
      expect(refunded['wallet']['frozen_balance'], 0);
      expect(refunded['wallet']['reconciled'], true);
      expect(
        (refunded['ledger'] as List).where(
          (r) => r['source_type'] == 'redemption_refund',
        ),
        hasLength(1),
      );
      await Future.wait(
        devices.map(
          (device) => SupabaseEconomyRepository(
            device.client,
          ).transition(rows.single['id'] as String, 'reject', '并发退回验证'),
        ),
      );
      expect(await evidence(child), refunded);
      // The failed competing attempts did not create additional requests or spend.
      expect(
        await users.first.client
            .from('redemptions')
            .select('id')
            .eq('reward_id', reward['id']),
        hasLength(1),
      );
      for (final id in stockChildren) {
        final wallet = (await evidence(id))['wallet'];
        expect(wallet['coin_balance'], 150);
        expect(wallet['frozen_balance'], 0);
        expect(wallet['xp'], 200);
      }
      checks.add({
        'name': 'shared_stock',
        'competingRequests': 4,
        'stock': 1,
        'winners': 1,
        'concurrentRefundCalls': 8,
        'refundLedgerRows': 1,
      });
      await writeReport();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:learning_planet/core/offline/network_failure.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_sync_state.dart';
import 'package:learning_planet/features/tasks/presentation/task_sync_banner.dart';

Map<String, dynamic> clone(Map<String, dynamic> data) =>
    jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

class FakeTaskRemote implements TaskSyncRemote {
  FakeTaskRemote(this.now);
  final DateTime Function() now;
  bool online = true, failAfterCommit = false, forbidden = false;
  Completer<void>? snapshotBarrier;
  final receipts = <String, Map<String, dynamic>>{};
  final requests = <Map<String, dynamic>>[];
  final tasks = <String, Map<String, dynamic>>{};
  final wallets = <String, Map<String, dynamic>>{};

  void seed(String child, {int minimum = 0}) {
    tasks['task-$child'] = {
      'id': 'task-$child',
      'child_id': child,
      'title': '学习任务',
      'status': 'ready',
      'coin_reward': 10,
      'xp_reward': 20,
      'due_date': '2026-09-16',
      'accumulated_seconds': 0,
      'active_started_at': null,
      'minimum_seconds': minimum,
      'sync_version': 0,
    };
    wallets[child] = {'coin_balance': 100, 'frozen_balance': 0, 'xp': 200};
  }

  void check() {
    if (forbidden) {
      throw const PostgrestException(
        message: 'Child access required',
        code: '42501',
      );
    }
    if (!online) throw const SocketException('Offline');
  }

  @override
  Future<Map<String, dynamic>> snapshot(String childId) async {
    check();
    await snapshotBarrier?.future;
    return clone({
      'lease_id': 'lease-$childId',
      'lease_expires_at': now().add(const Duration(days: 7)).toIso8601String(),
      'server_at': now().toIso8601String(),
      'timezone': 'Asia/Shanghai',
      'day': '2026-09-16',
      'tasks': tasks.values
          .where((task) => task['child_id'] == childId)
          .toList(),
      'wallet': wallets[childId],
    });
  }

  @override
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command) async {
    check();
    requests.add(clone(command));
    final task = tasks[command['task_id']]!;
    final wallet = wallets[task['child_id']]!;
    Map<String, dynamic> result(String outcome) => clone({
      'outcome': outcome,
      'reason': '另一台设备已修改任务',
      'task': task,
      'wallet': wallet,
      'server_at': now().toIso8601String(),
    });
    final id = command['command_id'] as String;
    if (receipts.containsKey(id)) {
      return result(receipts[id]!['outcome'] as String);
    }
    final expected = command['predecessor_id'] == null
        ? command['expected_version']
        : receipts[command['predecessor_id']]?['version'];
    if (task['status'] == 'completed') {
      receipts[id] = {
        'outcome': 'already_completed',
        'version': task['sync_version'],
      };
      return result('already_completed');
    }
    if (task['status'] == 'abandoned') {
      if (command['kind'] != 'abandon') return result('conflict');
      receipts[id] = {
        'outcome': 'already_abandoned',
        'version': task['sync_version'],
      };
      return result('already_abandoned');
    }
    if (expected != task['sync_version'] || task['status'] == 'skipped') {
      return result('conflict');
    }
    final at = DateTime.parse(command['occurred_at'] as String);
    if (['pause', 'complete', 'abandon'].contains(command['kind'])) {
      final active = task['active_started_at'];
      task['accumulated_seconds'] =
          (task['accumulated_seconds'] as int) +
          (active == null
              ? 0
              : at.difference(DateTime.parse(active as String)).inSeconds);
    }
    task['status'] = switch (command['kind']) {
      'start' || 'resume' => 'in_progress',
      'pause' => 'paused',
      'complete' => 'completed',
      'abandon' => 'abandoned',
      _ => throw StateError('Invalid command'),
    };
    task['active_started_at'] =
        command['kind'] == 'start' || command['kind'] == 'resume'
        ? command['occurred_at']
        : null;
    task['sync_version'] = (task['sync_version'] as int) + 1;
    if (command['kind'] == 'abandon') {
      task['abandoned_at'] = command['occurred_at'];
    }
    if (command['kind'] == 'complete') {
      wallet['coin_balance'] = (wallet['coin_balance'] as int) + 10;
      wallet['xp'] = (wallet['xp'] as int) + 20;
    }
    receipts[id] = {'outcome': 'applied', 'version': task['sync_version']};
    if (failAfterCommit) {
      failAfterCommit = false;
      throw const SocketException('Lost acknowledgement');
    }
    return result('applied');
  }
}

void main() {
  late OfflineStore store;
  late OfflineTaskRepository repository;
  late FakeTaskRemote remote;
  late DateTime now;
  String? owner;
  OfflineTaskRepository make({bool automatic = false}) => OfflineTaskRepository(
    store: store,
    remote: remote,
    live: const UnconfiguredTaskRepository(),
    accountId: () => owner,
    clock: () => now,
    autoSync: automatic,
    syncInterval: const Duration(milliseconds: 30),
  );

  setUp(() async {
    now = DateTime.utc(2026, 9, 16, 8);
    owner = 'user-a';
    store = OfflineStore(NativeDatabase.memory());
    remote = FakeTaskRemote(() => now)..seed('child');
    repository = make()..setForeground(false);
    await repository.loadTasks('child');
  });
  tearDown(() async {
    await repository.dispose();
    await store.close();
  });

  Future<void> offline() async {
    remote.online = false;
    now = now.add(const Duration(seconds: 11));
    await repository.synchronize('child');
  }

  test(
    'offline intervals persist, exclude pauses, and do not mint local rewards',
    () async {
      remote.tasks['task-child']!['minimum_seconds'] = 60;
      await repository.synchronize('child');
      await offline();
      await repository.start('task-child');
      now = now.add(const Duration(seconds: 20));
      await repository.pause('task-child');
      now = now.add(const Duration(seconds: 100));
      await repository.resume('task-child');
      now = now.add(const Duration(seconds: 60));
      await repository.complete('task-child');
      await repository.complete('task-child');
      final task = (await repository.loadTasks('child')).single;
      expect(task.status, TaskStatus.completed);
      expect(task.accumulatedSeconds, 80);
      expect((await repository.loadWallet('child')).coins, 100);
      final rows = await store.commands('user-a');
      expect(rows.length, 4);
      expect(rows.map((row) => row['command_id']).toSet().length, 4);
      expect(
        (rows[1]['command'] as Map)['predecessor_id'],
        rows[0]['command_id'],
      );
      remote.online = true;
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect((await repository.loadWallet('child')).coins, 110);
      expect(remote.tasks['task-child']!['accumulated_seconds'], 80);
      await repository.synchronize('child');
      expect((await repository.loadWallet('child')).coins, 110);
    },
  );

  test(
    'SQLite file survives repository and database restart with original UUIDs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-offline-test-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}cache.sqlite',
      );
      await repository.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      repository = make()..setForeground(false);
      await repository.loadTasks('child');
      await offline();
      await repository.start('task-child');
      await repository.complete('task-child');
      final ids = (await store.commands(
        'user-a',
      )).map((row) => row['command_id']).toList();
      await repository.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      repository = make()..setForeground(false);
      expect(
        (await repository.loadTasks('child')).single.status,
        TaskStatus.completed,
      );
      expect(
        (await store.commands(
          'user-a',
        )).map((row) => row['command_id']).toList(),
        ids,
      );
      remote.online = true;
      await repository.synchronize('child');
      expect((await repository.loadWallet('child')).coins, 110);
      await repository.dispose();
      await store.close();
      await directory.delete(recursive: true);
      store = OfflineStore(NativeDatabase.memory());
      repository = make()..setForeground(false);
    },
  );

  test(
    'offline abandonment persists elapsed time, survives restart and lost acknowledgement without payout',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-abandon-',
      );
      await repository.dispose();
      await store.close();
      final file = File(
        '${directory.path}${Platform.pathSeparator}cache.sqlite',
      );
      store = OfflineStore(NativeDatabase(file));
      repository = make()..setForeground(false);
      await repository.loadTasks('child');
      await offline();
      await repository.start('task-child');
      now = now.add(const Duration(seconds: 35));
      await repository.abandon('task-child');
      await repository.abandon('task-child');
      final commands = await store.commands('user-a');
      expect(commands.length, 2);
      final id = commands.last['command_id'];
      expect((await repository.loadWallet('child')).coins, 100);
      await repository.dispose();
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      repository = make()..setForeground(false);
      now = now.add(const Duration(hours: 1));
      final abandoned = (await repository.loadTasks('child')).single;
      expect(abandoned.status, TaskStatus.abandoned);
      expect(abandoned.activeStartedAt, isNull);
      expect(abandoned.elapsedSeconds(now), 35);
      expect(abandoned.abandonedAt, isNotNull);
      expect((await store.commands('user-a')).last['command_id'], id);
      await expectLater(repository.complete('task-child'), throwsStateError);
      await expectLater(repository.resume('task-child'), throwsStateError);
      remote.online = true;
      remote.failAfterCommit = true;
      await repository.synchronize('child');
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect(remote.tasks['task-child']!['status'], 'abandoned');
      expect(remote.tasks['task-child']!['accumulated_seconds'], 35);
      expect(remote.receipts.length, 2);
      expect((await repository.loadWallet('child')).coins, 100);
      await repository.dispose();
      await store.close();
      await directory.delete(recursive: true);
      store = OfflineStore(NativeDatabase.memory());
      repository = make()..setForeground(false);
    },
  );

  test(
    'remote completion overrides pending abandonment and server abandonment rejects pending completion',
    () async {
      await offline();
      await repository.abandon('task-child');
      remote.tasks['task-child']!.addAll({
        'status': 'completed',
        'sync_version': 9,
      });
      remote.wallets['child']!['coin_balance'] = 110;
      remote.online = true;
      await repository.synchronize('child');
      expect(
        (await repository.loadTasks('child')).single.status,
        TaskStatus.completed,
      );
      expect((await repository.loadWallet('child')).coins, 110);
      expect(await store.commands('user-a'), isEmpty);
      remote.seed('second');
      await repository.loadTasks('second');
      remote.online = false;
      await repository.start('task-second');
      await repository.complete('task-second');
      remote.tasks['task-second']!.addAll({
        'status': 'abandoned',
        'sync_version': 9,
      });
      remote.online = true;
      await repository.synchronize('second');
      expect(repository.state.conflicts.length, 2);
      expect(
        (await repository.loadTasks('second')).single.status,
        TaskStatus.abandoned,
      );
      expect((await repository.loadWallet('second')).coins, 100);
      await repository.acceptServer('second', 'task-second');
      expect(await store.commands('user-a'), isEmpty);
    },
  );

  test(
    'automatic review permits offline abandonment but cannot bypass answer-based completion',
    () async {
      remote.tasks['task-child']!.addAll({
        'source_type': 'automatic_wrong_review',
        'status': 'in_progress',
        'active_started_at': now.toIso8601String(),
      });
      await repository.synchronize('child');
      await offline();
      await expectLater(repository.complete('task-child'), throwsStateError);
      await repository.abandon('task-child');
      expect(
        (await repository.loadTasks('child')).single.status,
        TaskStatus.abandoned,
      );
      remote.online = true;
      remote.tasks['task-child']!.addAll({
        'status': 'abandoned',
        'active_started_at': null,
        'sync_version': 2,
      });
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect((await repository.loadWallet('child')).coins, 100);
    },
  );

  test(
    'lost server acknowledgement retries same UUID without a second reward',
    () async {
      await offline();
      await repository.start('task-child');
      await repository.complete('task-child');
      remote.online = true;
      remote.failAfterCommit = true;
      await repository.synchronize('child');
      expect(repository.state.phase, TaskSyncPhase.offline);
      expect((await store.commands('user-a')).first['attempts'], 1);
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect(
        remote.requests[0]['command_id'],
        remote.requests[1]['command_id'],
      );
      expect((await repository.loadWallet('child')).coins, 110);
      // Lose acknowledgement specifically for the reward-bearing command as well.
      remote.seed('second');
      await repository.loadTasks('second');
      await repository.start('task-second');
      await repository.synchronize('second');
      await repository.complete('task-second');
      remote.failAfterCommit = true;
      await repository.synchronize('second');
      expect(remote.wallets['second']!['coin_balance'], 110);
      expect((await store.commands('user-a')).length, 1);
      await repository.synchronize('second');
      expect((await repository.loadWallet('second')).coins, 110);
    },
  );

  test(
    'lost abandonment acknowledgement retries the original UUID with no additional state change',
    () async {
      await offline();
      await repository.abandon('task-child');
      remote.online = true;
      remote.failAfterCommit = true;
      await repository.synchronize('child');
      expect((await store.commands('user-a')).length, 1);
      expect(remote.tasks['task-child']!['sync_version'], 1);
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect(
        remote.requests.map((request) => request['command_id']).toSet().length,
        1,
      );
      expect(remote.tasks['task-child']!['sync_version'], 1);
      expect((await repository.loadWallet('child')).coins, 100);
    },
  );

  test(
    'conflicts block whole task chain; offline resolution never discards it',
    () async {
      await offline();
      await repository.start('task-child');
      await repository.complete('task-child');
      remote.tasks['task-child']!.addAll({
        'status': 'paused',
        'sync_version': 99,
      });
      remote.online = true;
      await repository.synchronize('child');
      expect(repository.state.phase, TaskSyncPhase.conflict);
      expect(repository.state.conflicts.length, 2);
      expect(
        (await repository.loadTasks('child')).single.status,
        TaskStatus.paused,
      );
      await expectLater(repository.resume('task-child'), throwsStateError);
      remote.online = false;
      await expectLater(
        repository.acceptServer('child', 'task-child'),
        throwsA(isA<SocketException>()),
      );
      expect((await store.commands('user-a')).length, 2);
      remote.online = true;
      await repository.acceptServer('child', 'task-child');
      expect(await store.commands('user-a'), isEmpty);
      expect((await repository.loadWallet('child')).coins, 100);
    },
  );

  test(
    'another device completion merges pending chain without additional rewards',
    () async {
      await offline();
      await repository.start('task-child');
      await repository.complete('task-child');
      remote.tasks['task-child']!.addAll({
        'status': 'completed',
        'sync_version': 7,
      });
      remote.wallets['child']!['coin_balance'] = 110;
      remote.online = true;
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect((await repository.loadWallet('child')).coins, 110);
      expect(repository.state.conflicts, isEmpty);
    },
  );

  test(
    'logout and account switch hide caches and never replay another user outbox',
    () async {
      await offline();
      await repository.start('task-child');
      owner = null;
      repository.scopeChanged();
      expect(repository.state.pending, 0);
      await expectLater(repository.loadTasks('child'), throwsStateError);
      owner = 'user-b';
      repository.scopeChanged();
      await expectLater(repository.loadTasks('child'), throwsStateError);
      expect(await store.commands('user-b'), isEmpty);
      expect((await store.commands('user-a')).length, 1);
      expect(remote.requests, isEmpty);
      owner = 'user-a';
      repository.scopeChanged();
      expect(
        (await repository.loadTasks('child')).single.status,
        TaskStatus.inProgress,
      );
      remote.online = true;
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
    },
  );

  test(
    'late snapshot after account switch cannot populate either account cache',
    () async {
      remote.seed('late');
      remote.snapshotBarrier = Completer<void>();
      final future = repository.loadTasks('late');
      final assertion = expectLater(future, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      owner = 'user-b';
      repository.scopeChanged();
      remote.snapshotBarrier!.complete();
      await assertion;
      expect(await store.read('user-a', 'tasks:late'), isNull);
      expect(await store.read('user-b', 'tasks:late'), isNull);
    },
  );

  test(
    'authorization errors purge stale cache rather than reporting offline success',
    () async {
      remote.forbidden = true;
      await expectLater(
        repository.synchronize('child'),
        throwsA(isA<PostgrestException>()),
      );
      expect(await store.read('user-a', 'tasks:child'), isNull);
      expect(repository.state.phase, TaskSyncPhase.conflict);
      await expectLater(
        repository.loadTasks('child'),
        throwsA(isA<PostgrestException>()),
      );
    },
  );

  test(
    'cached reads and durable clicks do not wait for a stalled network request',
    () async {
      remote.snapshotBarrier = Completer<void>();
      final pending = repository.synchronize('child');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        (await repository
                .loadTasks('child')
                .timeout(const Duration(milliseconds: 500)))
            .single
            .status,
        TaskStatus.ready,
      );
      await repository
          .start('task-child')
          .timeout(const Duration(milliseconds: 500));
      await repository
          .complete('task-child')
          .timeout(const Duration(milliseconds: 500));
      expect((await store.commands('user-a')).length, 2);
      remote.snapshotBarrier!.complete();
      await pending;
      expect((await repository.loadWallet('child')).coins, 110);
    },
  );

  test(
    'child deletion rejects a late sync response and stops its pending commands',
    () async {
      await offline();
      await repository.start('task-child');
      remote.online = true;
      remote.snapshotBarrier = Completer();
      final started = repository.changes.firstWhere(
        (state) => state.phase == TaskSyncPhase.syncing,
      );
      final pending = repository.synchronize('child');
      await started;
      await repository.forgetChild('child');
      remote.snapshotBarrier!.complete();
      await pending;
      expect(await store.read('user-a', 'tasks:child'), isNull);
      expect(await store.commands('user-a', childId: 'child'), isEmpty);
      expect(remote.requests, isEmpty);
      await expectLater(repository.loadTasks('child'), throwsStateError);
    },
  );

  test(
    'server denial plus a deletion marker clears stale review data on reconnect',
    () async {
      await repository.dispose();
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/child_deletion_tombstones');
          return http.Response(
            jsonEncode({'child_id': 'child'}),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      repository = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: SupabaseTaskRepository(client),
        accountId: () => 'user-a',
        clock: () => now,
        autoSync: false,
      );
      await store.write('user-a', 'review-questions:child', {
        'items': ['private'],
      });
      remote.forbidden = true;
      final removed = repository.remoteDeletions.first;
      await repository.synchronize('child');
      expect(await removed, 'child');
      expect(await store.isChildDeleted('child'), true);
      expect(await store.read('user-a', 'review-questions:child'), isNull);
      expect(await store.read('user-a', 'tasks:child'), isNull);
    },
  );

  test(
    'expired cache cannot enqueue activity or invent next-day review completion',
    () async {
      await offline();
      now = now.add(const Duration(days: 8));
      await expectLater(repository.start('task-child'), throwsStateError);
      expect(await store.commands('user-a'), isEmpty);
      now = DateTime.utc(2026, 9, 16, 8);
      remote.online = true;
      remote.tasks['task-child']!['source_type'] = 'automatic_wrong_review';
      await repository.synchronize('child');
      await expectLater(repository.start('task-child'), throwsStateError);
      expect(await store.commands('user-a'), isEmpty);
    },
  );

  test(
    'cached family date advances in family timezone, not device timezone',
    () async {
      await offline();
      now = DateTime.utc(2026, 9, 16, 16, 1);
      expect(await repository.today('child'), DateTime(2026, 9, 17));
    },
  );

  test(
    'minimum duration, invalid transitions and clock reversal enqueue nothing',
    () async {
      remote.tasks['task-child']!['minimum_seconds'] = 60;
      await repository.synchronize('child');
      await offline();
      await expectLater(repository.pause('task-child'), throwsStateError);
      await repository.start('task-child');
      await expectLater(repository.complete('task-child'), throwsStateError);
      now = now.subtract(const Duration(hours: 1));
      await expectLater(repository.pause('task-child'), throwsStateError);
      expect((await store.commands('user-a')).length, 1);
    },
  );

  test(
    'simultaneous complete clicks create only one durable completion command',
    () async {
      await offline();
      await repository.start('task-child');
      await Future.wait([
        repository.complete('task-child'),
        repository.complete('task-child'),
      ]);
      expect((await store.commands('user-a')).length, 2);
    },
  );

  test(
    'online recovery resets exponential backoff and syncs queues across children',
    () async {
      remote.seed('second');
      await repository.loadTasks('second');
      remote.online = false;
      await repository.synchronize('second');
      await repository.start('task-second');
      await repository.complete('task-second');
      await repository.loadTasks('child');
      await repository.start('task-child');
      final first = (await store.commands('user-a')).first;
      await store.retry(
        'user-a',
        first['command_id'] as String,
        10,
        now.add(const Duration(hours: 1)),
        'offline',
      );
      remote.online = true;
      await repository.synchronize('child');
      expect(await store.commands('user-a'), isEmpty);
      expect((await repository.loadWallet('second')).coins, 110);
      expect(
        (await repository.loadTasks('child')).single.status,
        TaskStatus.inProgress,
      );
    },
  );

  test('automatic foreground poll retries without user refresh', () async {
    await repository.dispose();
    repository = make(automatic: true);
    await offline();
    await repository.start('task-child');
    await repository.complete('task-child');
    final done = repository.changes.firstWhere(
      (state) => state.phase == TaskSyncPhase.synced && state.pending == 0,
    );
    remote.online = true;
    await done.timeout(const Duration(seconds: 5));
    expect(remote.wallets['child']!['coin_balance'], 110);
  });

  test(
    'family cache allows offline entry but never hides a known permission denial',
    () async {
      await store.write('user-a', 'families', {
        'items': [
          {
            'id': 'family',
            'name': '家庭',
            'timezone': 'Asia/Shanghai',
            'children': [
              {
                'id': 'child',
                'family_id': 'family',
                'nickname': '孩子',
                'grade': 1,
              },
            ],
          },
        ],
      });
      var denied = false;
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        httpClient: MockClient((request) async {
          if (!denied) throw const SocketException('Offline');
          return http.Response(
            jsonEncode({'code': '42501', 'message': 'Access required'}),
            403,
            headers: {'content-type': 'application/json'},
            request: request,
            reasonPhrase: 'Forbidden',
          );
        }),
      );
      try {
        final families = OfflineFamilyRepository(client, store, () => owner);
        expect(
          (await families.loadFamilies()).single.children.single.nickname,
          '孩子',
        );
        owner = 'user-b';
        await expectLater(
          families.loadFamilies(),
          throwsA(isA<SocketException>()),
        );
        owner = 'user-a';
        denied = true;
        await expectLater(
          families.loadFamilies(),
          throwsA(isA<PostgrestException>()),
        );
        expect(await store.read('user-a', 'families'), isNull);
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'parent manual completion is never queued for later PIN bypass',
    () async {
      await offline();
      await expectLater(
        repository.manualComplete('task-child', 'reason'),
        throwsStateError,
      );
      expect(await store.commands('user-a'), isEmpty);
    },
  );

  test(
    'network classification retries transient failures, not permission or business errors',
    () {
      expect(isNetworkFailure(const SocketException('offline')), isTrue);
      expect(isNetworkFailure(TimeoutException('timeout')), isTrue);
      expect(
        isNetworkFailure(
          const PostgrestException(message: 'unavailable', code: '503'),
        ),
        isTrue,
      );
      expect(
        isNetworkFailure(
          const PostgrestException(message: 'PIN required', code: '42501'),
        ),
        isFalse,
      );
      expect(
        isNetworkFailure(
          const PostgrestException(message: 'minimum', code: 'P0001'),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'sync banner distinguishes locally saved actions and confirmed wallet',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(repository),
            taskSyncStateProvider.overrideWith(
              (ref) => Stream.value(
                const TaskSyncState(
                  phase: TaskSyncPhase.offline,
                  pending: 2,
                  pendingTaskIds: {'task-child'},
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const Scaffold(body: TaskSyncBanner(childId: 'child')),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('离线 · 联网后自动同步'), findsOneWidget);
      expect(find.textContaining('本账号2项待同步'), findsOneWidget);
      expect(find.textContaining('钱包仅显示服务端已确认余额'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

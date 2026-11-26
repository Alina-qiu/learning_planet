import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'offline_tasks_test.dart' show FakeTaskRemote;

class _ObservedStore extends OfflineStore {
  _ObservedStore(super.executor);

  int queueReads = 0;
  final _transactionScope = Object();
  Future<void> Function()? afterInsert;
  Future<void> Function()? afterCommit;

  @override
  Future<List<Map<String, dynamic>>> commands(String owner, {String? childId}) {
    queueReads++;
    return super.commands(owner, childId: childId);
  }

  @override
  Future<void> enqueue(
    String owner,
    String childId,
    Map<String, dynamic> command,
  ) async {
    await super.enqueue(owner, childId, command);
    await afterInsert?.call();
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final outermost = Zone.current[_transactionScope] == null;
    final result = await super.transaction(
      () => runZoned(action, zoneValues: {_transactionScope: true}),
      requireNew: requireNew,
    );
    if (outermost && afterCommit != null) {
      final callback = afterCommit!;
      afterCommit = null;
      await callback();
    }
    return result;
  }
}

OfflineTaskRepository _tasks(OfflineStore store) {
  final time = DateTime.utc(2026, 9, 16, 8);
  return OfflineTaskRepository(
    store: store,
    remote: FakeTaskRemote(() => time)..seed('child'),
    live: const UnconfiguredTaskRepository(),
    accountId: () => 'parent',
    clock: () => time,
    autoSync: false,
  )..setForeground(false);
}

void main() {
  test(
    'completion publishes the committed account queue with a single read',
    () async {
      final dir = await Directory.systemTemp.createTemp('lp-task-commit');
      final file = File('${dir.path}/commands.sqlite');
      final store = _ObservedStore(NativeDatabase(file));
      final tasks = _tasks(store);
      addTearDown(() async {
        await tasks.dispose();
        await store.close();
        await dir.delete(recursive: true);
      });
      await tasks.loadTasks('child');
      await tasks.start('task-child');
      await store.enqueue('parent', 'other', {
        'command_id': 'foreign-task-start',
        'task_id': 'task-other',
        'kind': 'start',
      });
      await store.conflict('parent', 'task-other', 'server conflict');
      final initialRevision = tasks.state.revision;
      final observer = sqlite3.open(file.path);
      addTearDown(observer.close);
      int committed() =>
          observer
                  .select(
                    "SELECT count(*) AS n FROM task_outbox WHERE owner='parent' AND task_id='task-child'",
                  )
                  .single['n']
              as int;
      final inserted = Completer<void>(), release = Completer<void>();
      store.afterInsert = () async {
        inserted.complete();
        await release.future;
      };
      store.queueReads = 0;
      final finish = tasks.complete('task-child');
      await inserted.future;
      try {
        expect(committed(), 1);
        expect(tasks.state.revision, initialRevision);
      } finally {
        release.complete();
      }
      await finish;
      expect(committed(), 2);
      expect(store.queueReads, 1);
      expect(tasks.state.pending, 2);
      expect(tasks.state.pendingTaskIds, {'task-child'});
      expect(tasks.state.conflicts.single['task_id'], 'task-other');
    },
  );

  test(
    'child deletion at commit cannot publish the previous queue or report success',
    () async {
      final store = _ObservedStore(NativeDatabase.memory());
      final tasks = _tasks(store);
      addTearDown(() async {
        await tasks.dispose();
        await store.close();
      });
      await tasks.loadTasks('child');
      await tasks.start('task-child');
      store.afterCommit = () => store.removeChildData('child');
      await expectLater(tasks.complete('task-child'), throwsStateError);
      expect(tasks.state.pendingTaskIds, isEmpty);
      expect(await store.commands('parent'), isEmpty);
    },
  );

  test(
    'standalone enqueue preserves the priority of overlapping access denials',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      Future<void> enqueue() => store.enqueue('parent', 'child', {
        'task_id': 'task-child',
        'command_id': 'c',
        'kind': 'start',
      });
      Future<void> denied(String text) => expectLater(
        enqueue(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', text)),
      );
      await store.applyFamilyAccess('parent', [
        FamilyAccessState(
          familyId: 'family',
          version: 2,
          active: false,
          lastRevokedVersion: 2,
          childIds: {'child'},
        ),
      ]);
      await denied('家庭访问权限已撤销');
      await store.removeChildData('child');
      await denied('孩子已删除，不能继续离线打卡');
      await store.removeAccountData('parent', 'job');
      await denied('账号已申请注销，不能继续离线打卡');
      expect(await store.commands('parent'), isEmpty);
    },
  );
}

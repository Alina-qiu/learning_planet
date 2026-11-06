import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../security/device_secrets.dart';
import '../security/encrypted_database.dart';
import '../security/local_file_protection.dart';
import 'family_access_state.dart';

/// Account-scoped durable cache and outbox. No JWT, PIN or speculative rewards.
class OfflineStore extends GeneratedDatabase {
  OfflineStore(super.executor);

  final Map<String, int> _reviewGenerations = {};
  int privacyGeneration = 0;
  final Map<String, int> _familyAccessGenerations = {};
  int familyAccessGeneration(String owner) =>
      _familyAccessGenerations[owner] ?? 0;
  int reviewGeneration(String owner) => _reviewGenerations[owner] ?? 0;

  Future<void> writeReviewCache(
    String owner,
    String key,
    Map<String, dynamic> data,
    int generation,
  ) => transaction(() async {
    if (reviewGeneration(owner) != generation) {
      throw StateError('错题缓存已清理，请重新加载');
    }
    if (key.startsWith('review-task:')) {
      final old = await read(owner, key);
      final oldVersion = (old?['task'] as Map?)?['sync_version'] as num?;
      final version = (data['task'] as Map?)?['sync_version'] as num?;
      if (oldVersion != null && version != null && oldVersion > version) return;
    }
    await write(owner, key, data);
  });

  static Future<OfflineStore> open() async {
    final directory = await getApplicationSupportDirectory();
    await protectLocalFiles(directory);
    final store = OfflineStore(
      await EncryptedDatabase.open(directory, const NativeDeviceSecrets()),
    );
    try {
      // Force lazy Drift initialization here so storage failures reach the
      // startup recovery screen, before any auth/UI/sync work can start.
      await store.customSelect('SELECT 1').get();
      await protectLocalFiles(directory);
      return store;
    } catch (_) {
      await store.close();
      throw const LocalDataException('本机数据暂时无法打开，资料已保留，请重试。');
    }
  }

  @override
  int get schemaVersion => 5;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''CREATE TABLE offline_cache (
      owner TEXT NOT NULL, cache_key TEXT NOT NULL, payload TEXT NOT NULL,
      PRIMARY KEY(owner, cache_key))''');
      await customStatement('''CREATE TABLE task_outbox (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL,
      command_id TEXT NOT NULL, child_id TEXT NOT NULL, task_id TEXT NOT NULL,
      payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
      error TEXT, UNIQUE(owner, command_id))''');
      await customStatement(
        'CREATE INDEX outbox_owner_order ON task_outbox(owner, sequence)',
      );
      await _createDeletionMarkers();
      await _createAccountDeletionMarkers();
      await _createImageDrafts();
      await _createFamilyAccess();
    },
    onUpgrade: (_, from, to) async {
      if (from < 2) await _createDeletionMarkers();
      if (from < 3) await _createAccountDeletionMarkers();
      if (from < 4) await _createImageDrafts();
      if (from < 5) await _createFamilyAccess();
    },
  );

  Future<void> _createFamilyAccess() =>
      customStatement('''CREATE TABLE family_access (
    owner TEXT NOT NULL,family_id TEXT NOT NULL,version INTEGER NOT NULL,
    active INTEGER NOT NULL,last_revoked_version INTEGER NOT NULL,child_ids TEXT NOT NULL,
    notification_pending INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(owner,family_id))''');

  Future<bool> familyAccessRevoked(
    String owner, {
    String? familyId,
    String? childId,
  }) async {
    final rows = await customSelect(
      'SELECT family_id,child_ids FROM family_access WHERE owner=? AND active=0',
      variables: [Variable(owner)],
    ).get();
    return rows.any(
      (row) =>
          row.read<String>('family_id') == familyId ||
          childId != null &&
              (jsonDecode(row.read<String>('child_ids')) as List).contains(
                childId,
              ),
    );
  }

  String? _cacheFamily(String key, Map<String, dynamic> data) {
    for (final prefix in [
      'invitation-command:',
      'parent-notification-mode:',
      'parent-notification-seen:',
      'parent-notification-policy:',
      'family-activity:',
    ]) {
      if (key.startsWith(prefix)) return key.substring(prefix.length);
    }
    return data['family_id'] as String? ??
        (data['command'] as Map?)?['family_id'] as String?;
  }

  Future<List<FamilyAccessChange>> applyFamilyAccess(
    String owner,
    List<FamilyAccessState> states,
  ) => transaction(() async {
    if (await accountDeletionJob(owner) != null) return [];
    final changes = <FamilyAccessChange>[];
    for (final state in states) {
      final previous = await customSelect(
        'SELECT * FROM family_access WHERE owner=? AND family_id=?',
        variables: [Variable(owner), Variable(state.familyId)],
      ).getSingleOrNull();
      if (previous != null && previous.read<int>('version') >= state.version) {
        continue;
      }
      final revoked =
          state.lastRevokedVersion >
          (previous?.read<int>('last_revoked_version') ?? 0);
      if (previous != null &&
          state.lastRevokedVersion <
              previous.read<int>('last_revoked_version')) {
        throw StateError('家庭权限版本不一致');
      }
      final children = <String>{
        ...state.childIds,
        if (previous != null)
          ...(jsonDecode(previous.read<String>('child_ids')) as List)
              .cast<String>(),
      };
      final cached = await read(owner, 'families');
      if (revoked) {
        for (final family in cached?['items'] as List? ?? []) {
          if (family['id'] == state.familyId) {
            children.addAll(
              (family['children'] as List).map((c) => c['id'] as String),
            );
          }
        }
      }
      await customStatement(
        'INSERT OR REPLACE INTO family_access VALUES(?,?,?,?,?,?,?)',
        [
          owner,
          state.familyId,
          state.version,
          state.active ? 1 : 0,
          state.lastRevokedVersion,
          jsonEncode(children.toList()),
          revoked || previous != null ? 1 : 0,
        ],
      );
      if (previous != null || revoked) {
        privacyGeneration++;
        _familyAccessGenerations[owner] = familyAccessGeneration(owner) + 1;
        _reviewGenerations[owner] = reviewGeneration(owner) + 1;
      }
      if (!revoked) continue;
      final rows = await customSelect(
        'SELECT cache_key,payload FROM offline_cache WHERE owner=?',
        variables: [Variable(owner)],
      ).get();
      for (final row in rows) {
        final key = row.read<String>('cache_key'),
            data =
                jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
        if (_cacheFamily(key, data) == state.familyId ||
            children.contains(_cacheChild(key, data))) {
          await remove(owner, key);
        } else if (key == 'configuration-time-v1') {
          await write(owner, key, {
            ...data,
            'events': [
              for (final event in data['events'] as List? ?? [])
                if (event['family_id'] != state.familyId) event,
            ],
          });
        }
      }
      // The old membership's family snapshot is removed even when already rejoined.
      // The fresh online family load will replace it after this transaction.
      if (cached != null) {
        await write(owner, 'families', {
          ...cached,
          'items': [
            for (final family in cached['items'] as List)
              if (family['id'] != state.familyId) family,
          ],
        });
      }
      for (final child in children) {
        await customStatement(
          'DELETE FROM task_outbox WHERE owner=? AND child_id=?',
          [owner, child],
        );
      }
      await customStatement(
        'INSERT OR IGNORE INTO discarded_image_drafts SELECT owner,draft_id FROM image_drafts WHERE owner=? AND family_id=?',
        [owner, state.familyId],
      );
      await customStatement(
        'DELETE FROM image_drafts WHERE owner=? AND family_id=?',
        [owner, state.familyId],
      );
      changes.add(
        FamilyAccessChange(owner, state.familyId, state.version, children),
      );
    }
    return changes;
  });

  Future<List<FamilyAccessChange>> pendingFamilyAccessChanges(
    String owner,
  ) async => [
    for (final row in await customSelect(
      'SELECT * FROM family_access WHERE owner=? AND notification_pending=1',
      variables: [Variable(owner)],
    ).get())
      FamilyAccessChange(
        owner,
        row.read<String>('family_id'),
        row.read<int>('version'),
        (jsonDecode(row.read<String>('child_ids')) as List)
            .cast<String>()
            .toSet(),
      ),
  ];
  Future<void> acknowledgeFamilyAccessChange(
    FamilyAccessChange change,
  ) => customStatement(
    'UPDATE family_access SET notification_pending=0 WHERE owner=? AND family_id=? AND version=?',
    [change.owner, change.familyId, change.version],
  );

  Future<void> _createImageDrafts() async {
    await customStatement('''CREATE TABLE image_drafts (
      owner TEXT NOT NULL, draft_id TEXT NOT NULL, child_id TEXT NOT NULL,
      family_id TEXT NOT NULL, stage TEXT NOT NULL DEFAULT 'editing',
      metadata TEXT NOT NULL, original BLOB, processed BLOB,
      attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
      error TEXT, updated_at INTEGER NOT NULL, PRIMARY KEY(owner,draft_id))''');
    await customStatement(
      'CREATE INDEX image_drafts_scope ON image_drafts(owner,child_id)',
    );
    await customStatement(
      'CREATE TABLE discarded_image_drafts(owner TEXT NOT NULL,draft_id TEXT NOT NULL,PRIMARY KEY(owner,draft_id))',
    );
  }

  Future<void> _createDeletionMarkers() => customStatement(
    'CREATE TABLE deleted_children (child_id TEXT PRIMARY KEY)',
  );

  Future<void> _createAccountDeletionMarkers() => customStatement(
    'CREATE TABLE deleted_accounts (owner TEXT PRIMARY KEY, job_id TEXT NOT NULL)',
  );

  Future<String?> accountDeletionJob(String owner) async => (await customSelect(
    'SELECT job_id FROM deleted_accounts WHERE owner=?',
    variables: [Variable(owner)],
  ).getSingleOrNull())?.read<String>('job_id');

  Future<void> removeAccountData(String owner, String jobId) => transaction(
    () async {
      if (await accountDeletionJob(owner) != null) return;
      privacyGeneration++;
      _reviewGenerations[owner] = reviewGeneration(owner) + 1;
      await customStatement('INSERT INTO deleted_accounts VALUES(?,?)', [
        owner,
        jobId,
      ]);
      await customStatement('DELETE FROM offline_cache WHERE owner=?', [owner]);
      await customStatement('DELETE FROM task_outbox WHERE owner=?', [owner]);
      await customStatement('DELETE FROM image_drafts WHERE owner=?', [owner]);
      await customStatement('DELETE FROM family_access WHERE owner=?', [owner]);
    },
  );

  Future<bool> isChildDeleted(String childId) async =>
      await customSelect(
        'SELECT child_id FROM deleted_children WHERE child_id=?',
        variables: [Variable(childId)],
      ).getSingleOrNull() !=
      null;

  String? _cacheChild(String key, Map<String, dynamic> data) {
    if (key.startsWith('creation:') ||
        key.startsWith('ai-request:') ||
        key.startsWith('economy-command:') ||
        key.startsWith('economy-view:') ||
        key.startsWith('task-note:') ||
        key.startsWith('review-page:')) {
      return data['child_id'] as String?;
    }
    for (final prefix in [
      'tasks:',
      'review-questions:',
      'review-overview:',
      'reminders:',
      'reminder-version:',
      'schedules:',
      'schedule-version:',
      'growth:',
      'growth-version:',
    ]) {
      if (key.startsWith(prefix)) return key.substring(prefix.length);
    }
    if (key.startsWith('review-task:')) {
      return (data['task'] as Map?)?['child_id'] as String?;
    }
    return null;
  }

  /// Explicit deletion markers are global child UUIDs, so every account's stale
  /// copy on this device is removed without touching other children's queues.
  Future<void> removeChildData(String childId) => transaction(() async {
    if (await isChildDeleted(childId)) return;
    privacyGeneration++;
    await customStatement('INSERT INTO deleted_children VALUES(?)', [childId]);
    final rows = await customSelect(
      'SELECT owner,cache_key,payload FROM offline_cache',
    ).get();
    final affectedOwners = <String>{};
    for (final row in rows) {
      final owner = row.read<String>('owner'),
          key = row.read<String>('cache_key');
      affectedOwners.add(owner);
      final data =
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      // Family-level delivery suppression can contain IDs for multiple children.
      // Clear it on child deletion; server receipts still suppress normal replay.
      if (_cacheChild(key, data) == childId ||
          key == 'configuration-time-v1' ||
          key.startsWith('family-activity:') ||
          key.startsWith('parent-notification-seen:')) {
        await remove(owner, key);
      } else if (key.startsWith('parent-notification-policy:')) {
        final policy = data['policy'];
        final children = policy is Map ? policy['child_ids'] : null;
        if (children is! List || children.contains(childId)) {
          await remove(owner, key);
        }
      } else if (key == 'families') {
        await write(owner, key, data);
      }
    }
    for (final owner in affectedOwners) {
      _reviewGenerations[owner] = reviewGeneration(owner) + 1;
    }
    await customStatement('DELETE FROM task_outbox WHERE child_id=?', [
      childId,
    ]);
    await customStatement('DELETE FROM image_drafts WHERE child_id=?', [
      childId,
    ]);
  });

  Future<Map<String, dynamic>?> read(String owner, String key) async {
    if (await accountDeletionJob(owner) != null) return null;
    final row = await customSelect(
      'SELECT payload FROM offline_cache WHERE owner=? AND cache_key=?',
      variables: [Variable(owner), Variable(key)],
    ).getSingleOrNull();
    if (row == null) return null;
    final data =
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
    if (await familyAccessRevoked(
      owner,
      familyId: _cacheFamily(key, data),
      childId: _cacheChild(key, data),
    )) {
      return null;
    }
    return data;
  }

  /// A price/stock change can affect siblings too. Retire this account's
  /// displayed economy snapshots without touching pending commands or wallets.
  Future<void> invalidateEconomyViews(String owner) => transaction(() async {
    final previous =
        (await read(owner, 'economy-cache-version'))?['value'] as int? ?? 0;
    await write(owner, 'economy-cache-version', {'value': previous + 1});
    await customStatement(
      "DELETE FROM offline_cache WHERE owner=? AND cache_key LIKE 'economy-view:%'",
      [owner],
    );
  });

  Future<void> write(String owner, String key, Map<String, dynamic> data) =>
      transaction(() async {
        if (await accountDeletionJob(owner) != null) {
          throw StateError('账号已申请注销，不能恢复本地缓存');
        }
        final child = _cacheChild(key, data);
        if (await familyAccessRevoked(
          owner,
          familyId: _cacheFamily(key, data),
          childId: child,
        )) {
          throw StateError('家庭访问权限已撤销，不能恢复本机缓存');
        }
        if (child != null && await isChildDeleted(child)) {
          throw StateError('孩子已删除，不能恢复本地缓存');
        }
        if (key == 'families') {
          final revoked = (await customSelect(
            'SELECT family_id FROM family_access WHERE owner=? AND active=0',
            variables: [Variable(owner)],
          ).get()).map((row) => row.read<String>('family_id')).toSet();
          final deleted = (await customSelect(
            'SELECT child_id FROM deleted_children',
          ).get()).map((row) => row.read<String>('child_id')).toSet();
          data = {
            ...data,
            'items': [
              for (final family in data['items'] as List)
                if (!revoked.contains(family['id']))
                  {
                    ...family as Map<String, dynamic>,
                    'children': [
                      for (final child in family['children'] as List)
                        if (!deleted.contains(child['id'])) child,
                    ],
                  },
            ],
          };
        }
        if (key == 'configuration-time-v1') {
          final events = <dynamic>[];
          for (final event in data['events'] as List? ?? []) {
            if (!await familyAccessRevoked(
              owner,
              familyId: event['family_id'] as String?,
            )) {
              events.add(event);
            }
          }
          data = {...data, 'events': events};
        }
        await customStatement(
          'INSERT OR REPLACE INTO offline_cache VALUES(?,?,?)',
          [owner, key, jsonEncode(data)],
        );
      });

  Future<void> remove(String owner, String key) => customStatement(
    'DELETE FROM offline_cache WHERE owner=? AND cache_key=?',
    [owner, key],
  );

  /// Call only after a complete, successful online family refresh. An offline
  /// fallback must not erase unresolved commands for families it cannot verify.
  Future<void> pruneFamilyInvitations(
    String owner,
    Set<String> familyIds,
  ) => transaction(() async {
    final rows = await customSelect(
      "SELECT cache_key FROM offline_cache WHERE owner=? AND cache_key LIKE 'invitation-command:%'",
      variables: [Variable(owner)],
    ).get();
    for (final row in rows) {
      final key = row.read<String>('cache_key');
      if (!familyIds.contains(key.substring('invitation-command:'.length))) {
        await remove(owner, key);
      }
    }
  });

  /// Purge snapshots and answer-bearing chains; ordinary tasks remain intact.
  Future<void> removeReviewCache(
    String owner, {
    String? childId,
    Set<String>? questionIds,
    bool discardCommands = true,
  }) {
    _reviewGenerations[owner] = reviewGeneration(owner) + 1;
    return transaction(() async {
      final taskIds = <String>{};
      final caches = await customSelect(
        "SELECT cache_key,payload FROM offline_cache WHERE owner=? AND (cache_key LIKE 'review-%' OR cache_key LIKE 'ai-request:%')",
        variables: [Variable(owner)],
      ).get();
      for (final row in caches) {
        final key = row.read<String>('cache_key');
        final data =
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
        if (childId == null || _cacheChild(key, data) == childId) {
          if (key.startsWith('ai-request:') && !discardCommands) continue;
          if (key.startsWith('review-task:')) {
            if (!discardCommands ||
                (questionIds != null &&
                    !(data['items'] as List? ?? []).any(
                      (item) => questionIds.contains(
                        (item as Map)['wrong_question_id'],
                      ),
                    ))) {
              continue;
            }
            taskIds.add(key.substring('review-task:'.length));
          }
          await remove(owner, key);
        }
      }
      if (discardCommands) {
        final rows = await commands(owner, childId: childId);
        for (final row in rows) {
          final command = row['command'] as Map;
          if ((command['kind'] as String).startsWith('review_') &&
              (questionIds == null ||
                  questionIds.contains(command['question_id']))) {
            taskIds.add(row['task_id'] as String);
          }
        }
        for (final taskId in taskIds) {
          await discard(owner, taskId);
        }
      }
    });
  }

  Future<List<Map<String, dynamic>>> commands(
    String owner, {
    String? childId,
  }) async {
    final rows = await customSelect(
      'SELECT * FROM task_outbox WHERE owner=?${childId == null ? '' : ' AND child_id=?'} ORDER BY sequence',
      variables: [Variable(owner), if (childId != null) Variable(childId)],
    ).get();
    return [
      for (final row in rows)
        {
          ...row.data,
          'command':
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        },
    ];
  }

  Future<void> enqueue(
    String owner,
    String childId,
    Map<String, dynamic> command,
  ) => transaction(() async {
    if (await accountDeletionJob(owner) != null) {
      throw StateError('账号已申请注销，不能继续离线打卡');
    }
    if (await isChildDeleted(childId)) throw StateError('孩子已删除，不能继续离线打卡');
    if (await familyAccessRevoked(owner, childId: childId)) {
      throw StateError('家庭访问权限已撤销');
    }
    await customStatement(
      'INSERT INTO task_outbox(owner,command_id,child_id,task_id,payload) VALUES(?,?,?,?,?)',
      [
        owner,
        command['command_id'],
        childId,
        command['task_id'],
        jsonEncode(command),
      ],
    );
  });

  /// Cache confirmation and outbox removal commit together, including crash recovery.
  Future<void> acknowledge(
    String owner,
    String childId,
    String commandId,
    Map<String, dynamic> snapshot, {
    Map<String, dynamic>? review,
    int? reviewGeneration,
  }) => transaction(() async {
    if (review != null) {
      await writeReviewCache(
        owner,
        'review-task:${(review['task'] as Map)['id']}',
        review,
        reviewGeneration!,
      );
    }
    await write(owner, 'tasks:$childId', snapshot);
    await customStatement(
      'DELETE FROM task_outbox WHERE owner=? AND command_id=?',
      [owner, commandId],
    );
  });

  Future<void> retry(
    String owner,
    String id,
    int attempts,
    DateTime next,
    String error,
  ) => customStatement(
    'UPDATE task_outbox SET attempts=?,next_attempt=?,error=? WHERE owner=? AND command_id=?',
    [attempts, next.millisecondsSinceEpoch, error, owner, id],
  );

  Future<void> conflict(
    String owner,
    String taskId,
    String error,
  ) => customStatement(
    "UPDATE task_outbox SET state='conflict',error=? WHERE owner=? AND task_id=?",
    [error, owner, taskId],
  );

  Future<void> discard(String owner, String taskId) => customStatement(
    'DELETE FROM task_outbox WHERE owner=? AND task_id=?',
    [owner, taskId],
  );
}

import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../../../core/offline/network_failure.dart';
import '../../../core/diagnostics/runtime_diagnostics.dart';
import '../../../core/offline/offline_store.dart';
import '../domain/task.dart';
import '../domain/task_item.dart';
import '../domain/task_sync_state.dart';
import '../domain/sync_diagnostics.dart';
import '../domain/wallet_summary.dart';
import '../domain/task_start_origin.dart';
import '../../wrong_questions/domain/review_confidence.dart';
import 'task_repository.dart';
import 'task_sync_remote.dart';

/// All child transitions use a write-ahead outbox, online and offline alike.
class OfflineTaskRepository implements TaskRepository, AttributedTaskStarter {
  OfflineTaskRepository({
    required this.store,
    required this.remote,
    required this.live,
    required this.accountId,
    DateTime Function()? clock,
    bool autoSync = true,
    Duration syncInterval = const Duration(seconds: 15),
    RuntimeDiagnostics? diagnostics,
    this.refreshFamilyAccess,
  }) : clock = clock ?? DateTime.now,
       _diagnostics = diagnostics ?? runtimeDiagnostics {
    tz_data.initializeTimeZones();
    if (autoSync) {
      _timer = Timer.periodic(syncInterval, (_) {
        if (_foreground && _activeChild != null) _backgroundSync(_activeChild!);
      });
    }
  }

  final OfflineStore store;
  final TaskSyncRemote remote;
  final TaskRepository live;
  final RuntimeDiagnostics _diagnostics;
  final String? Function() accountId;
  final Future<void> Function()? refreshFamilyAccess;
  final DateTime Function() clock;
  final _events = StreamController<TaskSyncState>.broadcast();
  final _remoteDeletions = StreamController<String>.broadcast();
  Stream<String> get remoteDeletions => _remoteDeletions.stream;
  final _lastAttempt = <String, DateTime>{};
  Future<void> _tail = Future.value();
  Future<void>? _inFlight;
  String? _syncOwner, _syncChild;
  bool _syncAgain = false;
  Timer? _timer;
  String? _owner, _activeChild;
  bool _foreground = true, _disposed = false;
  TaskSyncState _state = const TaskSyncState();
  TaskSyncState get state => _state;
  Stream<TaskSyncState> get changes => _events.stream;
  SupabaseClient? get client => live is SupabaseTaskRepository
      ? (live as SupabaseTaskRepository).client
      : null;

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void scopeChanged() {
    if (_owner == accountId()) return;
    _owner = accountId();
    _activeChild = null;
    _lastAttempt.clear();
    _emit(const TaskSyncState());
  }

  Future<void> forgetAccount(String owner, String jobId) async {
    _activeChild = null;
    _syncAgain = false;
    await store.removeAccountData(owner, jobId);
    _lastAttempt.clear();
    _emit(const TaskSyncState());
  }

  Future<void> forgetChild(String childId, {bool notifyUi = false}) async {
    if (_activeChild == childId) _activeChild = null;
    _syncAgain = false;
    _lastAttempt.remove(childId);
    await store.removeChildData(childId);
    if (notifyUi && !_disposed) _remoteDeletions.add(childId);
    if (accountId() != null) await _publish(_account(), TaskSyncPhase.synced);
  }

  Future<bool> _forgetIfDeleted(String owner, String childId) async {
    final backend = client;
    if (backend == null) return false;
    Map<String, dynamic>? marker;
    try {
      marker = await backend
          .from('child_deletion_tombstones')
          .select('child_id')
          .eq('child_id', childId)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      if (marker == null) {
        final notices = await backend
            .from('family_access_revocations')
            .select('child_ids')
            .contains('child_ids', [childId])
            .limit(1)
            .timeout(const Duration(seconds: 10));
        if (notices.isNotEmpty) marker = {'child_id': childId};
      }
    } catch (_) {
      // A permission/network failure does not prove that the child was deleted.
      return false;
    }
    _check(owner);
    if (marker == null) return false;
    await forgetChild(childId, notifyUi: true);
    return true;
  }

  String _account() {
    scopeChanged();
    final owner = _owner;
    if (owner == null) throw StateError('请先登录；离线缓存不会跨账号开放');
    return owner;
  }

  void _check(String owner) {
    if (_disposed || accountId() != owner) throw StateError('登录账号已变化，请重新打开任务');
  }

  void _emit(TaskSyncState value) {
    if (_disposed) return;
    _state = value;
    _events.add(value);
  }

  Future<void> _publish(
    String owner,
    TaskSyncPhase phase, {
    String? message,
  }) async {
    final rows = await store.commands(owner);
    _check(owner);
    final conflicts = [
      for (final row in rows)
        if (row['state'] == 'conflict') row,
    ];
    _emit(
      TaskSyncState(
        phase: conflicts.isNotEmpty && phase != TaskSyncPhase.syncing
            ? TaskSyncPhase.conflict
            : phase,
        pending: rows.where((row) => row['state'] == 'pending').length,
        conflicts: conflicts,
        message: message,
        revision: _state.revision + 1,
        pendingTaskIds: {
          for (final row in rows)
            if (row['state'] == 'pending') row['task_id'] as String,
        },
      ),
    );
  }

  /// Read the durable queue without fetching, replaying, or exposing answers.
  Future<SyncDiagnostics> diagnostics(String childId) => _locked(() async {
    final owner = _account();
    return store.transaction(() async {
      if (await store.accountDeletionJob(owner) != null ||
          await store.isChildDeleted(childId)) {
        throw StateError('本机数据已清理');
      }
      final rows = await store.commands(owner);
      final cache = await store.read(owner, 'tasks:$childId');
      final confirmed = <String, TaskItem>{
        for (final row in cache?['tasks'] as List? ?? [])
          if (row['child_id'] == childId)
            row['id'] as String: TaskItem.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
      };
      final grouped = <String, List<SyncOperation>>{};
      for (final row in rows.where((r) => r['child_id'] == childId)) {
        grouped
            .putIfAbsent(row['task_id'] as String, () => [])
            .add(SyncOperation.fromRow(row));
      }
      _check(owner);
      return SyncDiagnostics(
        owner: owner,
        childId: childId,
        confirmedAt: DateTime.tryParse(cache?['server_at'] as String? ?? ''),
        leaseExpiresAt: DateTime.tryParse(
          cache?['lease_expires_at'] as String? ?? '',
        ),
        otherChildOperations: rows
            .where((r) => r['child_id'] != childId)
            .length,
        groups: [
          for (final entry in grouped.entries)
            TaskSyncGroup(
              taskId: entry.key,
              confirmed: confirmed[entry.key],
              operations: entry.value,
            ),
        ],
      );
    });
  });

  void _backgroundSync(String childId, {bool followUp = false}) {
    if (_disposed) return;
    if (accountId() == null) {
      scopeChanged();
      return;
    }
    if (followUp && _inFlight != null && _syncOwner == accountId()) {
      _syncAgain = true;
    }
    unawaited(
      synchronize(childId).catchError((Object error) {
        // synchronize publishes transport and business failures before rethrowing.
      }),
    );
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground && _activeChild != null) _backgroundSync(_activeChild!);
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    try {
      await _inFlight;
    } catch (_) {
      /* Scope/disposal aborts in-flight results. */
    }
    await _tail;
    await _events.close();
    await _remoteDeletions.close();
  }

  Future<Map<String, dynamic>> _cache(String owner, String childId) async {
    final data = await store.read(owner, 'tasks:$childId');
    _check(owner);
    if (data == null) throw StateError('此孩子尚未缓存，请先联网打开一次任务');
    return data;
  }

  DateTime _anchoredNow(Map<String, dynamic> snapshot) {
    final received = DateTime.parse(snapshot['received_at'] as String);
    final elapsed = clock().difference(received);
    if (elapsed.inSeconds < -2) throw StateError('设备时间发生倒退，请联网校准后重试');
    return DateTime.parse(snapshot['server_at'] as String).add(elapsed);
  }

  Future<String> _prepare(String childId) async {
    final owner = _account();
    if (await store.accountDeletionJob(owner) != null) {
      throw StateError('账号已申请注销');
    }
    if (await store.isChildDeleted(childId)) throw StateError('孩子已删除，请选择其他孩子');
    if (await store.familyAccessRevoked(owner, childId: childId)) {
      throw StateError('家庭访问权限已撤销');
    }
    _activeChild = childId;
    final cached = await store.read(owner, 'tasks:$childId');
    _check(owner);
    if (cached == null) {
      await synchronize(childId);
      await _cache(owner, childId);
      return owner;
    }
    if (_state.revision == 0) await _publish(owner, _state.phase);
    final last = _lastAttempt[childId];
    if (_foreground &&
        (last == null || clock().difference(last).inSeconds >= 10)) {
      _backgroundSync(childId);
    }
    return owner;
  }

  @override
  Future<List<TaskItem>> loadTasks(String childId) async {
    final owner = await _prepare(childId);
    return _locked(() async {
      final cache = await _cache(owner, childId);
      final tasks = {
        for (final row in (cache['tasks'] as List))
          (row as Map<String, dynamic>)['id'] as String: TaskItem.fromJson(row),
      };
      for (final row in await store.commands(owner, childId: childId)) {
        if (row['state'] != 'pending') continue;
        final command = row['command'] as Map<String, dynamic>;
        final task = tasks[command['task_id']];
        if (task == null || task.isTerminal) {
          continue;
        }
        tasks[task.id] = _project(task, command);
      }
      _check(owner);
      return TaskItem.ordered(tasks.values);
    });
  }

  @override
  Future<WalletSummary> loadWallet(String childId) async {
    final owner = await _prepare(childId);
    return _locked(() async {
      final wallet =
          (await _cache(owner, childId))['wallet'] as Map<String, dynamic>;
      return WalletSummary(
        coins: wallet['coin_balance'] as int,
        frozen: wallet['frozen_balance'] as int,
        xp: wallet['xp'] as int,
      );
    });
  }

  /// Already confirmed timezone only; observing it never starts another sync.
  Future<String?> cachedFamilyTimezone(String childId) => _locked(() async {
    final owner = _account(), privacy = store.privacyGeneration;
    if (await store.accountDeletionJob(owner) != null ||
        await store.isChildDeleted(childId) ||
        await store.familyAccessRevoked(owner, childId: childId)) {
      throw StateError('家庭数据已不可访问');
    }
    final cache = await store.read(owner, 'tasks:$childId');
    _check(owner);
    if (privacy != store.privacyGeneration) throw StateError('家庭数据已变化');
    return cache?['timezone'] as String?;
  });

  Future<DateTime> today(String childId) async {
    final owner = await _prepare(childId);
    return _locked(() async {
      final cache = await _cache(owner, childId);
      final local = tz.TZDateTime.from(
        _anchoredNow(cache),
        tz.getLocation(cache['timezone'] as String),
      );
      return DateTime(local.year, local.month, local.day);
    });
  }

  static TaskItem _project(TaskItem task, Map<String, dynamic> command) {
    final at = DateTime.parse(command['occurred_at'] as String);
    final kind = (command['kind'] as String).replaceFirst('review_', '');
    if (kind == 'answer') return task;
    final accumulated =
        kind == 'pause' || kind == 'complete' || kind == 'abandon'
        ? task.elapsedSeconds(at)
        : task.accumulatedSeconds;
    return TaskItem.fromJson({
      ...task.toJson(),
      'status': switch (kind) {
        'start' || 'resume' => 'in_progress',
        'pause' => 'paused',
        'complete' => 'completed',
        'abandon' => 'abandoned',
        _ => throw StateError('Unknown command'),
      },
      'accumulated_seconds': accumulated,
      if (kind == 'abandon') 'abandoned_at': at.toIso8601String(),
      'active_started_at': kind == 'start' || kind == 'resume'
          ? at.toIso8601String()
          : null,
    });
  }

  /// Pending answers carry no result or answer key. The server grades on replay.
  Future<Map<String, dynamic>> projectReview(
    Map<String, dynamic> data,
  ) => _locked(() async {
    final owner = _account();
    var task = TaskItem.fromJson(data['task'] as Map<String, dynamic>);
    final rows = (await store.commands(
      owner,
    )).where((row) => row['task_id'] == task.id).toList();
    final items = [
      for (final item in data['items'] as List)
        {...item as Map<String, dynamic>},
    ];
    var pendingCompletion = false;
    for (final row in rows) {
      final command = row['command'] as Map<String, dynamic>;
      if (row['state'] == 'conflict' && command['kind'] == 'review_answer') {
        for (final item in items) {
          if (item['wrong_question_id'] == command['question_id']) {
            item['conflict_answer'] = command['answer'];
            item['conflict_answer_confidence'] = command['answer_confidence'];
          }
        }
      }
      if (row['state'] != 'pending' || task.isTerminal) continue;
      if (command['kind'] == 'review_answer') {
        for (final item in items) {
          if (item['wrong_question_id'] == command['question_id'] &&
              item['result'] == null) {
            item['pending_answer'] = command['answer'];
            item['pending_answer_confidence'] = command['answer_confidence'];
          }
        }
      }
      if (command['kind'] == 'review_complete') pendingCompletion = true;
      task = _project(task, command);
    }
    _check(owner);
    return {
      ...data,
      'task': {...data['task'] as Map<String, dynamic>, ...task.toJson()},
      'items': items,
      'offline_enabled': true,
      'local_completion': pendingCompletion,
      'local_pending': rows.isNotEmpty,
      'sync_conflict': rows.any((row) => row['state'] == 'conflict'),
    };
  });

  Future<void> queueReview(
    String taskId,
    String operation, {
    String? questionId,
    String? answer,
    String? commandId,
    TaskStartOrigin? startOrigin,
    ReviewConfidence? confidence,
  }) => _queue(
    taskId,
    'review_$operation',
    questionId: questionId,
    answer: answer,
    commandId: commandId,
    startOrigin: startOrigin,
    confidence: confidence,
  );

  Future<void> _queue(
    String taskId,
    String kind, {
    String? questionId,
    String? answer,
    String? commandId,
    TaskStartOrigin? startOrigin,
    ReviewConfidence? confidence,
  }) => _locked(() async {
    if (confidence != null && kind != 'review_answer') {
      throw ArgumentError('作答把握只能与复习答案一起保存');
    }
    if (startOrigin != null && kind != 'start' && kind != 'review_start') {
      throw ArgumentError('开始来源只能记录在首次开始命令中');
    }
    final owner = _account();
    final generation = store.reviewGeneration(owner);
    final review = kind.startsWith('review_')
        ? await store.read(owner, 'review-task:$taskId')
        : null;
    if (kind.startsWith('review_') && review == null) {
      throw StateError('请先联网加载复习题目');
    }
    final operation = kind.replaceFirst('review_', '');
    final childId = review == null
        ? _activeChild
        : (review['task'] as Map)['child_id'] as String;
    if (childId == null) throw StateError('请先打开任务列表');
    _activeChild = childId;
    final cache = await _cache(owner, childId);
    final rows = await store.commands(owner, childId: childId);
    if (rows.any(
      (row) => row['task_id'] == taskId && row['state'] == 'conflict',
    )) {
      throw StateError('此任务存在同步冲突，请先采用服务端状态');
    }
    final all = await store.commands(owner);
    if (all.length >= 500) throw StateError('待同步操作已达上限，请先联网同步');
    final source = (cache['tasks'] as List)
        .cast<Map<String, dynamic>>()
        .where((row) => row['id'] == taskId)
        .firstOrNull;
    if (source == null) throw StateError('任务不在当前孩子的缓存中');
    var task = TaskItem.fromJson(
      review == null ? source : review['task'] as Map<String, dynamic>,
    );
    if (review != null && task.sourceType != 'automatic_wrong_review') {
      throw StateError('不是复习任务');
    }
    if (task.sourceType == 'automatic_wrong_review' &&
        review == null &&
        kind != 'abandon') {
      throw StateError('复习任务需要完成题目作答，不支持普通离线打卡');
    }
    final chain = rows
        .where((row) => row['task_id'] == taskId && row['state'] == 'pending')
        .toList();
    for (final row in chain) {
      task = _project(task, row['command'] as Map<String, dynamic>);
    }
    if (operation == 'complete' && task.status == TaskStatus.completed) return;
    if (kind == 'abandon' && task.status == TaskStatus.abandoned) return;
    if (operation == 'answer' && task.status == TaskStatus.completed) {
      // The final local answer and its automatic completion commit together.
      // Retrying that answer must not append another completion.
      final saved = chain.where((row) {
        final command = row['command'] as Map;
        return command['kind'] == 'review_answer' &&
            command['question_id'] == questionId &&
            command['answer'] == answer &&
            (confidence == null ||
                command['answer_confidence'] == confidence.wire);
      });
      if (saved.isNotEmpty) return;
    }
    final allowed = switch (operation) {
      'start' =>
        task.status == TaskStatus.ready || task.status == TaskStatus.scheduled,
      'pause' => task.status == TaskStatus.inProgress,
      'answer' => task.status == TaskStatus.inProgress,
      'resume' => task.status == TaskStatus.paused,
      'abandon' => !task.isTerminal,
      'complete' =>
        task.status == TaskStatus.inProgress ||
            task.status == TaskStatus.paused,
      _ => false,
    };
    if (!allowed) throw StateError('任务当前状态不允许此操作');
    Map<String, dynamic>? reviewItem;
    var automaticComplete = false;
    if (review != null) {
      final items = (review['items'] as List).cast<Map<String, dynamic>>();
      final pendingAnswers = {
        for (final row in chain)
          if ((row['command'] as Map)['kind'] == 'review_answer')
            (row['command'] as Map)['question_id']: row['command'] as Map,
      };
      if (operation == 'answer') {
        reviewItem = items
            .where((item) => item['wrong_question_id'] == questionId)
            .firstOrNull;
        if (reviewItem == null ||
            answer == null ||
            answer.trim().isEmpty ||
            answer.length > 500) {
          throw StateError('请填写有效答案（最多500字）');
        }
        if (reviewItem['result'] != null) throw StateError('此题已由服务端判定');
        if (pendingAnswers.containsKey(questionId)) {
          final pending = pendingAnswers[questionId]!;
          if (pending['answer'] == answer &&
              (confidence == null ||
                  pending['answer_confidence'] == confidence.wire)) {
            return;
          }
          throw StateError('此题已保存本机，待服务端确认');
        }
        automaticComplete =
            (review['task'] as Map)['review_auto_complete'] == true &&
            items.every(
              (item) =>
                  item['result'] != null ||
                  item['wrong_question_id'] == questionId ||
                  pendingAnswers.containsKey(item['wrong_question_id']),
            );
      }
      if (operation == 'complete' &&
          (items.isEmpty ||
              items.any(
                (item) =>
                    item['result'] == null &&
                    !pendingAnswers.containsKey(item['wrong_question_id']),
              ))) {
        throw StateError('请先提交全部题目的答案');
      }
    }
    final at = _anchoredNow(cache);
    if (at.isAfter(DateTime.parse(cache['lease_expires_at'] as String))) {
      throw StateError('离线缓存授权已超过七天，请联网刷新');
    }
    if ((task.activeStartedAt != null && at.isBefore(task.activeStartedAt!)) ||
        (chain.isNotEmpty &&
            at.isBefore(
              DateTime.parse(
                (chain.last['command'] as Map)['occurred_at'] as String,
              ),
            ))) {
      throw StateError('设备时间发生变化，请联网校准');
    }
    if ((operation == 'complete' || automaticComplete) &&
        task.elapsedSeconds(at) < task.minimumSeconds) {
      throw StateError('尚未达到最低有效时长');
    }
    if (all.length + (automaticComplete ? 2 : 1) > 500) {
      throw StateError('待同步操作已达上限，请先联网同步');
    }
    final command = <String, dynamic>{
      'command_id': commandId ?? const Uuid().v4(),
      'task_id': task.id,
      'kind': kind,
      'lease_id': cache['lease_id'],
      'expected_version': task.serverVersion,
      'predecessor_id': chain.isEmpty ? null : chain.last['command_id'],
      'occurred_at': at.toUtc().toIso8601String(),
      if (startOrigin != null) 'start_origin': startOrigin.wire,
      if (reviewItem != null) ...{
        'question_id': questionId,
        'question_version': reviewItem['question_version'],
        'answer': answer,
        if (confidence != null) 'answer_confidence': confidence.wire,
      },
    };
    _check(owner);
    await store.transaction(() async {
      if (review != null && store.reviewGeneration(owner) != generation) {
        throw StateError('复习缓存已清理，请重新加载');
      }
      await store.enqueue(owner, childId, command);
      if (automaticComplete) {
        // A durable successor also lets replay finish against an older server.
        // New servers can return already_completed after grading the answer.
        await store.enqueue(owner, childId, {
          'command_id': const Uuid().v4(),
          'task_id': task.id,
          'kind': 'review_complete',
          'lease_id': cache['lease_id'],
          'expected_version': task.serverVersion,
          'predecessor_id': command['command_id'],
          'occurred_at': command['occurred_at'],
        });
      }
    });
    await _publish(
      owner,
      _state.phase == TaskSyncPhase.offline
          ? TaskSyncPhase.offline
          : TaskSyncPhase.syncing,
    );
    if (_foreground) _backgroundSync(childId, followUp: true);
  });

  @override
  Future<void> start(String taskId) => _queue(taskId, 'start');
  @override
  Future<void> startWithOrigin(String taskId, TaskStartOrigin origin) =>
      _queue(taskId, 'start', startOrigin: origin);
  @override
  Future<void> pause(String taskId) => _queue(taskId, 'pause');
  @override
  Future<void> resume(String taskId) => _queue(taskId, 'resume');
  @override
  Future<void> complete(String taskId) => _queue(taskId, 'complete');
  @override
  Future<void> abandon(String taskId) => _queue(taskId, 'abandon');

  /// Parent privileges are deliberately not replayed offline after PIN expiry.
  @override
  Future<void> manualComplete(String taskId, String reason) async {
    final owner = _account();
    await _inFlight;
    await _locked(() async {
      if ((await store.commands(
        owner,
      )).any((row) => row['task_id'] == taskId)) {
        throw StateError('请先同步或处理此任务的离线操作，再进行家长补签');
      }
      _check(owner);
    });
    await live.manualComplete(taskId, reason);
    _check(owner);
    if (_activeChild != null) await synchronize(_activeChild!);
  }

  @override
  Future<void> createOneTimeTask({
    required String childId,
    required String title,
    required DateTime dueDate,
    required int coinReward,
    required int xpReward,
  }) async {
    _account();
    await live.createOneTimeTask(
      childId: childId,
      title: title,
      dueDate: dueDate,
      coinReward: coinReward,
      xpReward: xpReward,
    );
    await synchronize(childId);
  }

  Future<void> synchronize(String childId) {
    final owner = _account();
    _activeChild = childId;
    final existing = _inFlight;
    if (existing != null) {
      if (_syncOwner == owner && _syncChild == childId) return existing;
      return existing.then(
        (_) => synchronize(childId),
        onError: (Object _, StackTrace __) => synchronize(childId),
      );
    }
    _syncOwner = owner;
    _syncChild = childId;
    final work = _synchronize(owner, childId).whenComplete(() {
      _inFlight = null;
      final again = _syncAgain;
      _syncAgain = false;
      if (again && !_disposed && _foreground && accountId() == owner) {
        _backgroundSync(_activeChild ?? childId);
      }
    });
    _inFlight = work;
    return work;
  }

  Future<void> _synchronize(String owner, String childId) async {
    _check(owner);
    var accessGeneration = store.familyAccessGeneration(owner);
    void check() {
      _check(owner);
      if (store.familyAccessGeneration(owner) != accessGeneration) {
        throw StateError('家庭访问权限已变化');
      }
    }

    if (await store.accountDeletionJob(owner) != null) {
      _activeChild = null;
      return;
    }
    if (await store.isChildDeleted(childId)) {
      if (_activeChild == childId) _activeChild = null;
      return;
    }
    final recovering =
        _state.phase == TaskSyncPhase.offline || _state.message != null;
    _lastAttempt[childId] = clock();
    await _publish(owner, TaskSyncPhase.syncing);
    final diagnosticScope = _diagnostics.capture(),
        watch = Stopwatch()..start();
    var diagnosticOutcome = DiagnosticOutcome.ok;
    Object? diagnosticError;
    try {
      await refreshFamilyAccess?.call();
      _check(owner);
      accessGeneration = store.familyAccessGeneration(owner);
      if (await store.familyAccessRevoked(owner, childId: childId)) {
        if (_activeChild == childId) _activeChild = null;
        await _publish(owner, TaskSyncPhase.synced);
        return;
      }
      final data = await remote.snapshot(childId);
      check();
      await _locked(() async {
        check();
        await store.write(owner, 'tasks:$childId', {
          ...data,
          'received_at': clock().toUtc().toIso8601String(),
        });
      });
      final rows = await store.commands(owner);
      final reviewGeneration = store.reviewGeneration(owner);
      final blocked = <String>{};
      for (final row in rows) {
        check();
        if (await store.isChildDeleted(row['child_id'] as String)) continue;
        final taskId = row['task_id'] as String;
        if (row['state'] != 'pending' || blocked.contains(taskId)) continue;
        if (!recovering &&
            (row['next_attempt'] as int) > clock().millisecondsSinceEpoch) {
          blocked.add(taskId);
          continue;
        }
        final command = row['command'] as Map<String, dynamic>;
        final isReview = (command['kind'] as String).startsWith('review_');
        // A privacy cleanup may remove a chain while an earlier RPC is in flight.
        if (!(await store.commands(
          owner,
        )).any((current) => current['command_id'] == row['command_id'])) {
          continue;
        }
        Map<String, dynamic> result;
        final reviewWatch = Stopwatch()..start();
        try {
          result = await remote.apply(command);
          if (isReview) {
            _diagnostics.record(
              DiagnosticOperation.reviews,
              outcome: result['outcome'] == 'conflict'
                  ? DiagnosticOutcome.conflict
                  : DiagnosticOutcome.ok,
              elapsed: reviewWatch.elapsed,
              scope: diagnosticScope,
            );
          }
          if (result['outcome'] == 'conflict') {
            diagnosticOutcome = DiagnosticOutcome.conflict;
          }
        } catch (error) {
          if (isReview) {
            _diagnostics.record(
              DiagnosticOperation.reviews,
              outcome: error is PostgrestException && error.code == '42501'
                  ? DiagnosticOutcome.authorization
                  : diagnosticFailure(error),
              error: error,
              elapsed: reviewWatch.elapsed,
              scope: diagnosticScope,
            );
          }
          diagnosticOutcome =
              error is PostgrestException && error.code == '42501'
              ? DiagnosticOutcome.authorization
              : DiagnosticOutcome.conflict;
          diagnosticError = error;
          check();
          if (isNetworkFailure(error)) {
            final attempts = (row['attempts'] as int) + 1;
            final delay = min(300, 2 << min(attempts - 1, 7));
            await store.retry(
              owner,
              row['command_id'] as String,
              attempts,
              clock().add(Duration(seconds: delay)),
              '网络中断，将自动重试',
            );
            rethrow;
          }
          await store.conflict(
            owner,
            taskId,
            error is PostgrestException && error.code == '42501'
                ? '家庭访问权限已失效'
                : syncExplanation(null),
          );
          if (error is PostgrestException && error.code == '42501') {
            if (await _forgetIfDeleted(owner, row['child_id'] as String)) {
              continue;
            }
            await store.remove(owner, 'tasks:${row['child_id']}');
            await store.remove(owner, 'families');
            await store.removeReviewCache(
              owner,
              childId: row['child_id'] as String,
            );
          }
          blocked.add(taskId);
          continue;
        }
        check();
        if (isReview && store.reviewGeneration(owner) != reviewGeneration) {
          continue;
        }
        final targetChild = row['child_id'] as String;
        if (result['outcome'] == 'conflict') {
          await store.conflict(
            owner,
            taskId,
            syncExplanation(result['reason']),
          );
          blocked.add(taskId);
        } else if (result['outcome'] != 'applied' &&
            result['outcome'] != 'already_completed' &&
            result['outcome'] != 'already_abandoned') {
          throw StateError('服务端返回未知同步结果');
        }
        await _locked(() async {
          check();
          if (isReview && store.reviewGeneration(owner) != reviewGeneration) {
            return;
          }
          final cached = await store.read(owner, 'tasks:$targetChild');
          if (cached != null &&
              result['task'] is Map &&
              result['wallet'] is Map) {
            final tasks = (cached['tasks'] as List)
                .cast<Map<String, dynamic>>();
            final merged = {
              ...cached,
              'tasks': [
                for (final task in tasks)
                  task['id'] == taskId ? result['task'] : task,
              ],
              'wallet': result['wallet'],
              'server_at': result['server_at'],
              'received_at': clock().toUtc().toIso8601String(),
            };
            if (result['outcome'] == 'conflict') {
              await store.write(owner, 'tasks:$targetChild', merged);
            } else {
              if (isReview && result['review'] is! Map) {
                throw StateError('服务端未返回复习判定，保留本机操作');
              }
              await store.acknowledge(
                owner,
                targetChild,
                row['command_id'] as String,
                merged,
                review: isReview
                    ? Map<String, dynamic>.from(result['review'] as Map)
                    : null,
                reviewGeneration: reviewGeneration,
              );
            }
          } else if (result['outcome'] != 'conflict') {
            // Keep unconfirmed commands if their cache is missing; do not lose evidence.
            await store.conflict(owner, taskId, '本地快照缺失，请联网采用服务端状态');
            blocked.add(taskId);
          }
        });
      }
      await _publish(owner, TaskSyncPhase.synced);
    } catch (error) {
      diagnosticOutcome = error is PostgrestException && error.code == '42501'
          ? DiagnosticOutcome.authorization
          : diagnosticFailure(error);
      diagnosticError = error;
      _check(owner);
      if (store.familyAccessGeneration(owner) != accessGeneration ||
          await store.familyAccessRevoked(owner, childId: childId)) {
        await _publish(owner, TaskSyncPhase.synced);
        return;
      }
      if (await store.isChildDeleted(childId)) {
        if (_activeChild == childId) _activeChild = null;
        await _publish(owner, TaskSyncPhase.synced);
        return;
      }
      if (isNetworkFailure(error)) {
        await _publish(
          owner,
          TaskSyncPhase.offline,
          message: '离线：操作已保存在本机，联网后自动同步',
        );
        return;
      }
      if (error is PostgrestException && error.code == '42501') {
        if (await _forgetIfDeleted(owner, childId)) return;
        await store.remove(owner, 'tasks:$childId');
        await store.remove(owner, 'families');
        await store.removeReviewCache(owner, childId: childId);
        for (final row in await store.commands(owner, childId: childId)) {
          await store.conflict(owner, row['task_id'] as String, '家庭访问权限已失效');
        }
      }
      await _publish(
        owner,
        TaskSyncPhase.conflict,
        message: error is PostgrestException && error.code == '42501'
            ? '家庭访问权限已失效'
            : syncExplanation(null),
      );
      rethrow;
    } finally {
      _diagnostics.record(
        DiagnosticOperation.tasks,
        outcome: diagnosticOutcome,
        elapsed: watch.elapsed,
        error: diagnosticError,
        scope: diagnosticScope,
      );
    }
  }

  /// Fetch successfully before discarding, so offline conflict resolution loses nothing.
  Future<void> acceptServer(String childId, String taskId) async {
    final owner = _account();
    await _inFlight;
    final generation = store.reviewGeneration(owner);
    final original = (await store.commands(
      owner,
    )).where((row) => row['task_id'] == taskId).toList();
    _check(owner);
    if (original.isEmpty) return;
    if (original.any((row) => row['child_id'] != childId)) {
      throw StateError('任务与孩子不匹配，请重新打开同步中心');
    }
    final hasReview = original.any(
      (row) =>
          row['task_id'] == taskId &&
          ((row['command'] as Map)['kind'] as String).startsWith('review_'),
    );
    final data = await remote.snapshot(childId);
    Map<String, dynamic>? review;
    if (hasReview) {
      if (remote is! ReviewTaskSyncRemote) throw StateError('服务端暂不支持复习状态刷新');
      review = await (remote as ReviewTaskSyncRemote).reviewSnapshot(taskId);
    }
    _check(owner);
    await _locked(() async {
      _check(owner);
      await store.transaction(() async {
        final current = (await store.commands(
          owner,
        )).where((row) => row['task_id'] == taskId).toList();
        if (original.map((row) => row['command_id']).join(',') !=
            current.map((row) => row['command_id']).join(',')) {
          throw StateError('读取期间本机操作已变化，请重新确认');
        }
        if (review != null) {
          await store.writeReviewCache(
            owner,
            'review-task:$taskId',
            review,
            generation,
          );
        }
        await store.write(owner, 'tasks:$childId', {
          ...data,
          'received_at': clock().toUtc().toIso8601String(),
        });
        await store.discard(owner, taskId);
      });
      await _publish(owner, TaskSyncPhase.synced);
    });
  }
}

SupabaseClient? taskSupabaseClient(TaskRepository repository) =>
    switch (repository) {
      SupabaseTaskRepository() => repository.client,
      OfflineTaskRepository() => repository.client,
      _ => null,
    };

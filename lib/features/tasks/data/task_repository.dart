import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../domain/task.dart';
import '../domain/task_item.dart';

abstract interface class TaskRepository {
  Future<List<TaskItem>> loadTasks(String childId);

  Future<void> createOneTimeTask({
    required String childId,
    required String title,
    required DateTime dueDate,
    required int coinReward,
    required int xpReward,
  });

  Future<void> start(String taskId);
  Future<void> pause(String taskId);
  Future<void> resume(String taskId);
  Future<void> complete(String taskId);
  Future<void> manualComplete(String taskId, String reason);
}

class SupabaseTaskRepository implements TaskRepository {
  SupabaseTaskRepository(this._client);

  final SupabaseClient _client;
  static const _uuid = Uuid();

  @override
  Future<List<TaskItem>> loadTasks(String childId) async {
    final now = DateTime.now();
    await _client.rpc<int>(
      'generate_scheduled_tasks',
      params: {
        'target_child_id': childId,
        'target_date': _dateOnly(now),
      },
    );
    final rows = await _client
        .from('task_instances')
        .select(
          'id, child_id, title, status, coin_reward, xp_reward, '
          'due_date, accumulated_seconds',
        )
        .eq('child_id', childId)
        .order('due_date')
        .order('created_at');
    return [for (final row in rows) _mapTask(row)];
  }

  @override
  Future<void> createOneTimeTask({
    required String childId,
    required String title,
    required DateTime dueDate,
    required int coinReward,
    required int xpReward,
  }) async {
    final template = await _client
        .from('task_templates')
        .insert({
          'child_id': childId,
          'title': title,
          'recurrence': 'once',
          'coin_reward': coinReward,
          'xp_reward': xpReward,
          'active': true,
        })
        .select('id')
        .single();
    await _client.rpc<void>(
      'create_task_from_template',
      params: {
        'target_template_id': template['id'],
        'target_date': _dateOnly(dueDate),
      },
    );
  }

  @override
  Future<void> start(String taskId) =>
      _client.rpc<void>('start_task', params: {'target_task_id': taskId});

  @override
  Future<void> pause(String taskId) =>
      _client.rpc<void>('pause_task', params: {'target_task_id': taskId});

  @override
  Future<void> resume(String taskId) =>
      _client.rpc<void>('resume_task', params: {'target_task_id': taskId});

  @override
  Future<void> complete(String taskId) => _client.rpc<void>(
        'complete_task',
        params: {
          'target_task_id': taskId,
          'completion_key': 'task:$taskId:${_uuid.v4()}',
        },
      );

  @override
  Future<void> manualComplete(String taskId, String reason) =>
      _client.rpc<void>(
        'complete_task',
        params: {
          'target_task_id': taskId,
          'completion_key': 'task:$taskId:${_uuid.v4()}',
          'parent_reason': reason,
        },
      );

  static TaskItem _mapTask(Map<String, dynamic> row) => TaskItem(
        id: row['id'] as String,
        childId: row['child_id'] as String,
        title: row['title'] as String,
        status: _mapStatus(row['status'] as String),
        coinReward: row['coin_reward'] as int,
        xpReward: row['xp_reward'] as int,
        dueDate: DateTime.parse(row['due_date'] as String),
        accumulatedSeconds: row['accumulated_seconds'] as int,
      );

  static TaskStatus _mapStatus(String value) => switch (value) {
        'scheduled' => TaskStatus.scheduled,
        'ready' => TaskStatus.ready,
        'in_progress' => TaskStatus.inProgress,
        'paused' => TaskStatus.paused,
        'completed' => TaskStatus.completed,
        'skipped' || 'expired' => TaskStatus.skipped,
        _ => throw StateError('Unknown task status: $value'),
      };

  static String _dateOnly(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class UnconfiguredTaskRepository implements TaskRepository {
  const UnconfiguredTaskRepository();

  Future<void> _fail() => Future<void>.error(
        StateError('开发环境尚未配置 Supabase。'),
      );

  @override
  Future<List<TaskItem>> loadTasks(String childId) async => const [];
  @override
  Future<void> createOneTimeTask({
    required String childId,
    required String title,
    required DateTime dueDate,
    required int coinReward,
    required int xpReward,
  }) =>
      _fail();
  @override
  Future<void> start(String taskId) => _fail();
  @override
  Future<void> pause(String taskId) => _fail();
  @override
  Future<void> resume(String taskId) => _fail();
  @override
  Future<void> complete(String taskId) => _fail();
  @override
  Future<void> manualComplete(String taskId, String reason) => _fail();
}

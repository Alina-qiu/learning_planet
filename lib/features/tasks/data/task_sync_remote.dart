import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class TaskSyncRemote {
  Future<Map<String, dynamic>> snapshot(String childId);
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command);
}

abstract interface class ReviewTaskSyncRemote {
  Future<Map<String, dynamic>> reviewSnapshot(String taskId);
}

class SupabaseTaskSyncRemote implements TaskSyncRemote, ReviewTaskSyncRemote {
  SupabaseTaskSyncRemote(this.client);
  final SupabaseClient client;

  @override
  Future<Map<String, dynamic>> reviewSnapshot(String taskId) => client
      .rpc<Map<String, dynamic>>(
        'load_review_task',
        params: {'target_task_id': taskId},
      )
      .timeout(const Duration(seconds: 10));

  @override
  Future<Map<String, dynamic>> snapshot(String childId) async =>
      Map<String, dynamic>.from(
        await client
            .rpc<Map<String, dynamic>>(
              'task_sync_snapshot',
              params: {'target_child_id': childId},
            )
            .timeout(const Duration(seconds: 10)),
      );

  @override
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command) async =>
      Map<String, dynamic>.from(
        await client
            .rpc<Map<String, dynamic>>(
              'apply_task_command',
              params: {'command': command},
            )
            .timeout(const Duration(seconds: 10)),
      );
}

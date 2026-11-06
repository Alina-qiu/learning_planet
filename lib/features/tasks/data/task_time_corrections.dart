import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../application/task_providers.dart';
import 'offline_task_repository.dart';

typedef TaskTimeScope = ({String taskId, String childId, String familyId});
typedef TimeAccess = ({String owner, int privacy, int authorization});

class TaskTimeContext {
  const TaskTimeContext({
    required this.seconds,
    required this.version,
    required this.running,
    required this.status,
  });
  final int seconds, version;
  final bool running;
  final String status;
}

class TaskTimeRequest {
  const TaskTimeRequest({
    required this.id,
    required this.expectedVersion,
    required this.seconds,
    required this.reason,
    required this.access,
  });
  final String id, reason;
  final int expectedVersion, seconds;
  final TimeAccess access;
}

abstract interface class TaskTimeRemote {
  Future<Map<String, dynamic>> load(String taskId);
  Future<Map<String, dynamic>> correct(String taskId, TaskTimeRequest request);
}

class SupabaseTaskTimeRemote implements TaskTimeRemote {
  SupabaseTaskTimeRemote(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> load(String taskId) => client
      .rpc<Map<String, dynamic>>(
        'task_time_context',
        params: {'target_task_id': taskId},
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<Map<String, dynamic>> correct(
    String taskId,
    TaskTimeRequest request,
  ) => client
      .rpc<Map<String, dynamic>>(
        'correct_task_time',
        params: {
          'target_task_id': taskId,
          'request_id': request.id,
          'expected_version': request.expectedVersion,
          'corrected_seconds': request.seconds,
          'reason': request.reason,
        },
      )
      .timeout(const Duration(seconds: 15));
}

final taskTimeCorrectionsProvider = Provider<TaskTimeCorrections?>((ref) {
  final tasks = ref.watch(taskRepositoryProvider),
      client = taskSupabaseClient(tasks);
  if (tasks is! OfflineTaskRepository || client == null) return null;
  final service = TaskTimeCorrections(
    store: tasks.store,
    remote: SupabaseTaskTimeRemote(client),
    owner: () => client.auth.currentUser?.id,
    authorized: (family) =>
        !ref.read(signingOutProvider) &&
        ref.read(activeParentFamilyProvider) == family &&
        (ref.read(parentAuthorizedUntilProvider)?.isAfter(DateTime.now()) ??
            false),
    revision: () => ref.read(parentAuthorizationRevisionProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

class TaskTimeCorrections {
  TaskTimeCorrections({
    required this.store,
    required this.remote,
    required this.owner,
    required this.authorized,
    required this.revision,
  });
  final OfflineStore store;
  final TaskTimeRemote remote;
  final String? Function() owner;
  final bool Function(String) authorized;
  final int Function() revision;
  bool _closed = false;
  void dispose() => _closed = true;
  TimeAccess capture(TaskTimeScope scope) {
    final account = owner();
    if (_closed || account == null || !authorized(scope.familyId)) {
      throw StateError('请返回首页重新验证家长PIN');
    }
    return (
      owner: account,
      privacy: store.privacyGeneration,
      authorization: revision(),
    );
  }

  Future<void> _check(TaskTimeScope scope, TimeAccess access) async {
    void guard() {
      if (_closed ||
          owner() != access.owner ||
          store.privacyGeneration != access.privacy ||
          revision() != access.authorization ||
          !authorized(scope.familyId)) {
        throw StateError('账号、家长授权或任务资料已变化，请重新打开');
      }
    }

    guard();
    if (await store.accountDeletionJob(access.owner) != null ||
        await store.isChildDeleted(scope.childId) ||
        await store.familyAccessRevoked(
          access.owner,
          familyId: scope.familyId,
          childId: scope.childId,
        )) {
      throw StateError('该任务已不可访问');
    }
    if ((await store.commands(
      access.owner,
    )).any((r) => r['task_id'] == scope.taskId)) {
      throw StateError('请先同步或处理此任务的离线操作，再纠正计时');
    }
    guard();
  }

  TaskTimeContext _parse(
    TaskTimeScope scope,
    TimeAccess access,
    Map<String, dynamic> value,
  ) {
    if (value['owner_id'] != access.owner ||
        value['task_id'] != scope.taskId ||
        value['child_id'] != scope.childId ||
        value['family_id'] != scope.familyId ||
        value['seconds'] is! int ||
        (value['seconds'] as int) < 0 ||
        (value['seconds'] as int) > 2147483647 ||
        value['version'] is! int ||
        (value['version'] as int) < 0 ||
        value['running'] is! bool ||
        !const [
          'scheduled',
          'ready',
          'in_progress',
          'paused',
          'completed',
          'skipped',
          'expired',
          'abandoned',
        ].contains(value['status'])) {
      throw const FormatException('计时记录归属或格式不正确');
    }
    return TaskTimeContext(
      seconds: value['seconds'] as int,
      version: value['version'] as int,
      running: value['running'] as bool,
      status: value['status'] as String,
    );
  }

  Future<TaskTimeContext> load(
    TaskTimeScope scope, {
    TimeAccess? access,
  }) async {
    access ??= capture(scope);
    await _check(scope, access);
    final value = await remote.load(scope.taskId);
    await _check(scope, access);
    return _parse(scope, access, value);
  }

  Future<TaskTimeContext> correct(
    TaskTimeScope scope,
    TaskTimeRequest request,
  ) async {
    if (request.seconds < 0 ||
        request.seconds > 2147483647 ||
        request.expectedVersion < 0 ||
        request.reason.trim().isEmpty ||
        request.reason.runes.length > 500) {
      throw const FormatException('请填写有效时长和纠正原因');
    }
    await _check(scope, request.access);
    final receipt = await remote.correct(scope.taskId, request);
    await _check(scope, request.access);
    if (receipt['request_id'] != request.id ||
        receipt['applied_version'] is! int ||
        (receipt['applied_version'] as int) != request.expectedVersion + 1 ||
        receipt['current'] is! Map) {
      throw const FormatException('纠正结果无法核对，请刷新任务');
    }
    final current = _parse(
      scope,
      request.access,
      Map<String, dynamic>.from(receipt['current'] as Map),
    );
    if (current.version < (receipt['applied_version'] as int)) {
      throw const FormatException('纠正结果版本不正确');
    }
    if (current.version == receipt['applied_version'] &&
        current.seconds != request.seconds) {
      throw const FormatException('纠正结果时长不正确');
    }
    return current;
  }
}

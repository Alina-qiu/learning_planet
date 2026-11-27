import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/network_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../application/task_providers.dart';
import 'offline_task_repository.dart';

typedef TaskNoteScope = ({String taskId, String childId, String familyId});
typedef _Access = ({String owner, int privacy});

class TaskNoteState {
  const TaskNoteState({
    this.current,
    this.draft,
    this.requestId,
    this.requestBody,
    this.offline = false,
  });
  final Map<String, dynamic>? current;
  final String? draft, requestId, requestBody;
  final bool offline;
  String get body => current?['body'] as String? ?? '';
  String get editing => draft ?? body;
  bool get pending => requestId != null;
  int get version => current?['version'] as int? ?? 0;
  Map<String, dynamic> json(TaskNoteScope scope) => {
    'schema': 1,
    'task_id': scope.taskId,
    'child_id': scope.childId,
    'family_id': scope.familyId,
    'current': current,
    'draft': draft,
    'request_id': requestId,
    'request_body': requestBody,
  };
}

abstract interface class TaskNoteRemote {
  Future<Map<String, dynamic>> load(String taskId);
  Future<Map<String, dynamic>> resolve(
    String taskId,
    String requestId,
    String body,
    String operation,
  );
}

class SupabaseTaskNoteRemote implements TaskNoteRemote {
  SupabaseTaskNoteRemote(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> load(String taskId) => client
      .rpc<Map<String, dynamic>>(
        'task_note',
        params: {'target_task_id': taskId},
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<Map<String, dynamic>> resolve(
    String taskId,
    String requestId,
    String body,
    String operation,
  ) => client
      .rpc<Map<String, dynamic>>(
        'resolve_task_note',
        params: {
          'target_task_id': taskId,
          'request_id': requestId,
          'note_text': body,
          'operation': operation,
        },
      )
      .timeout(const Duration(seconds: 15));
}

final taskNotesProvider = Provider<TaskNotes?>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (tasks is! OfflineTaskRepository || client == null) return null;
  final notes = TaskNotes(
    store: tasks.store,
    remote: SupabaseTaskNoteRemote(client),
    owner: () => client.auth.currentUser?.id,
  );
  ref.onDispose(notes.dispose);
  return notes;
});

/// Drafts never publish automatically. A frozen request survives process death;
/// cancelling it requires a server barrier before the draft can be edited again.
class TaskNotes {
  TaskNotes({required this.store, required this.remote, required this.owner});
  final OfflineStore store;
  final TaskNoteRemote remote;
  final String? Function() owner;
  Future<void> _queue = Future.value();
  bool _closed = false;
  void dispose() => _closed = true;
  String _key(TaskNoteScope s) => 'task-note:${s.taskId}';
  _Access _capture() {
    final account = owner();
    if (account == null || _closed) throw StateError('请重新登录');
    return (owner: account, privacy: store.privacyGeneration);
  }

  Future<void> _check(TaskNoteScope s, _Access access) async {
    void guard() {
      if (_closed ||
          owner() != access.owner ||
          store.privacyGeneration != access.privacy) {
        throw StateError('账号或本机资料已变化，请重新打开任务');
      }
    }

    guard();
    if (await store.accountDeletionJob(access.owner) != null ||
        await store.isChildDeleted(s.childId) ||
        await store.familyAccessRevoked(
          access.owner,
          familyId: s.familyId,
          childId: s.childId,
        )) {
      throw StateError('该任务已不可访问');
    }
    guard();
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _validateCurrent(TaskNoteScope s, Map<String, dynamic> current) {
    if (current['task_id'] != s.taskId ||
        current['child_id'] != s.childId ||
        current['family_id'] != s.familyId ||
        current['body'] is! String ||
        (current['body'] as String).runes.length > 500 ||
        current['version'] is! int ||
        (current['version'] as int) < 0 ||
        current['version'] != 0 &&
            (current['updated_at'] is! String ||
                DateTime.tryParse(current['updated_at'] as String) == null)) {
      throw const FormatException('说明归属或格式不正确');
    }
  }

  Future<TaskNoteState> _read(TaskNoteScope s, _Access access) async {
    await _check(s, access);
    final data = await store.read(access.owner, _key(s));
    await _check(s, access);
    if (data == null) return const TaskNoteState();
    if (data['schema'] != 1 ||
        data['task_id'] != s.taskId ||
        data['child_id'] != s.childId ||
        data['family_id'] != s.familyId ||
        (data['request_id'] == null) != (data['request_body'] == null)) {
      throw const FormatException('本机说明归属或格式不正确');
    }
    final current = (data['current'] as Map?)?.cast<String, dynamic>();
    if (current != null) _validateCurrent(s, current);
    return TaskNoteState(
      current: current,
      draft: data['draft'] as String?,
      requestId: data['request_id'] as String?,
      requestBody: data['request_body'] as String?,
    );
  }

  Future<TaskNoteState> _write(
    TaskNoteScope s,
    _Access access,
    TaskNoteState state,
  ) async {
    await store.transaction(() async {
      await _check(s, access);
      await store.write(access.owner, _key(s), state.json(s));
      await _check(s, access);
    });
    return state;
  }

  Future<TaskNoteState> load(TaskNoteScope s) {
    final access = _capture();
    return _serial(() async {
      final local = await _read(s, access);
      try {
        final current = await remote.load(s.taskId);
        await _check(s, access);
        _validateCurrent(s, current);
        return await _write(
          s,
          access,
          TaskNoteState(
            current: (current['version'] as int) >= local.version
                ? current
                : local.current,
            draft: local.draft,
            requestId: local.requestId,
            requestBody: local.requestBody,
          ),
        );
      } catch (error) {
        await _check(s, access);
        if (error is PostgrestException && error.code == '42501') {
          await store.remove(access.owner, _key(s));
        }
        if (!isNetworkFailure(error)) rethrow;
        return TaskNoteState(
          current: local.current,
          draft: local.draft,
          requestId: local.requestId,
          requestBody: local.requestBody,
          offline: true,
        );
      }
    });
  }

  Future<TaskNoteState> edit(TaskNoteScope s, String text) {
    if (text.runes.length > 500) throw ArgumentError('说明最多 500 个字符');
    final access = _capture();
    return _serial(() async {
      final local = await _read(s, access);
      if (local.pending) throw StateError('请先核对上次保存');
      return _write(
        s,
        access,
        TaskNoteState(current: local.current, draft: text),
      );
    });
  }

  Future<TaskNoteState> prepare(TaskNoteScope s) {
    final access = _capture();
    return _serial(() async {
      final local = await _read(s, access);
      if (local.pending) return local;
      final body = local.editing.trim();
      if (body.runes.length > 500) throw ArgumentError('说明最多 500 个字符');
      return _write(
        s,
        access,
        TaskNoteState(
          current: local.current,
          draft: local.draft,
          requestId: const Uuid().v4(),
          requestBody: body,
        ),
      );
    });
  }

  Future<({TaskNoteState state, String status, int? appliedVersion})> resolve(
    TaskNoteScope s,
    String requestId,
    String operation,
  ) {
    if (!const ['submit', 'inspect', 'cancel'].contains(operation)) {
      throw ArgumentError('Invalid operation');
    }
    final access = _capture();
    return _serial(() async {
      final local = await _read(s, access);
      if (!local.pending || local.requestId != requestId) {
        throw StateError('待核对请求已变化');
      }
      late final Map<String, dynamic> result;
      try {
        result = await remote.resolve(
          s.taskId,
          requestId,
          local.requestBody!,
          operation,
        );
      } on PostgrestException catch (error) {
        await _check(s, access);
        if (error.code == '42501') {
          await store.remove(access.owner, _key(s));
        }
        rethrow;
      }
      await _check(s, access);
      final current = (result['current'] as Map).cast<String, dynamic>();
      _validateCurrent(s, current);
      final status = result['status'];
      if (result['owner_id'] != access.owner ||
          result['request_id'] != requestId ||
          !const ['applied', 'abandoned', 'unknown'].contains(status) ||
          status == 'applied' &&
              (result['applied_version'] is! int ||
                  (result['applied_version'] as int) < 1 ||
                  (result['applied_version'] as int) >
                      (current['version'] as int))) {
        throw const FormatException('保存回执不匹配');
      }
      final state = await _write(
        s,
        access,
        TaskNoteState(
          current: (current['version'] as int) >= local.version
              ? current
              : local.current,
          draft: status == 'applied' ? null : local.draft,
          requestId: status == 'unknown' ? requestId : null,
          requestBody: status == 'unknown' ? local.requestBody : null,
        ),
      );
      return (
        state: state,
        status: status as String,
        appliedVersion: result['applied_version'] as int?,
      );
    });
  }
}

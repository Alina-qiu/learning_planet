import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

typedef SubmissionScope = ({String childId, String familyId});
typedef SubmissionAccess = ({
  String owner,
  int privacy,
  int revision,
  bool parent,
});

abstract interface class ChildSubmissionRemote {
  Future<Map<String, dynamic>> list(String child, Map<String, dynamic>? cursor);
  Future<Map<String, dynamic>> read(String draft);
  Future<Map<String, dynamic>> approve(
    String draft,
    String request,
    Map<String, dynamic> config,
  );
  Future<String> imageUrl(String path);
}

class SupabaseChildSubmissionRemote implements ChildSubmissionRemote {
  SupabaseChildSubmissionRemote(this.client);
  final SupabaseClient client;
  Future<Map<String, dynamic>> _rpc(String name, Map<String, dynamic> params) =>
      client
          .rpc<Map<String, dynamic>>(name, params: params)
          .timeout(const Duration(seconds: 15));
  @override
  Future<Map<String, dynamic>> list(
    String child,
    Map<String, dynamic>? cursor,
  ) => _rpc('child_question_submissions', {
    'target_child_id': child,
    if (cursor != null) ...{
      'after_created_at': cursor['created_at'],
      'after_id': cursor['id'],
    },
  });
  @override
  Future<Map<String, dynamic>> read(String draft) =>
      _rpc('child_question_submission', {'target_draft_id': draft});
  @override
  Future<Map<String, dynamic>> approve(
    String draft,
    String request,
    Map<String, dynamic> config,
  ) => _rpc('approve_child_question', {
    'target_draft_id': draft,
    'request_id': request,
    'config': config,
  });
  @override
  Future<String> imageUrl(String path) => client.storage
      .from('wrong-question-images')
      .createSignedUrl(path, 300)
      .timeout(const Duration(seconds: 15));
}

final childQuestionSubmissionsProvider = Provider<ChildQuestionSubmissions?>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider),
      client = taskSupabaseClient(tasks);
  if (tasks is! OfflineTaskRepository || client == null) return null;
  final service = ChildQuestionSubmissions(
    store: tasks.store,
    remote: SupabaseChildSubmissionRemote(client),
    owner: () =>
        ref.read(signingOutProvider) ? null : client.auth.currentUser?.id,
    parent: (family) =>
        ref.read(activeParentFamilyProvider) == family &&
        (ref.read(parentAuthorizedUntilProvider)?.isAfter(DateTime.now()) ??
            false),
    revision: () => ref.read(parentAuthorizationRevisionProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

class ChildQuestionSubmissions {
  ChildQuestionSubmissions({
    required this.store,
    required this.remote,
    required this.owner,
    required this.parent,
    required this.revision,
  });
  final OfflineStore store;
  final ChildSubmissionRemote remote;
  final String? Function() owner;
  final bool Function(String) parent;
  final int Function() revision;
  bool _closed = false;
  void dispose() => _closed = true;
  SubmissionAccess capture(SubmissionScope scope) {
    final account = owner();
    if (_closed || account == null) throw StateError('请登录后重新打开');
    return (
      owner: account,
      privacy: store.privacyGeneration,
      revision: revision(),
      parent: parent(scope.familyId),
    );
  }

  bool isCurrent(SubmissionScope scope, SubmissionAccess access) =>
      !_closed &&
      owner() == access.owner &&
      store.privacyGeneration == access.privacy &&
      revision() == access.revision &&
      parent(scope.familyId) == access.parent;
  Future<void> _check(SubmissionScope scope, SubmissionAccess access) async {
    void check() {
      if (!isCurrent(scope, access)) throw StateError('账号、家长授权或资料权限已变化，请刷新');
    }

    check();
    if (await store.accountDeletionJob(access.owner) != null ||
        await store.isChildDeleted(scope.childId) ||
        await store.familyAccessRevoked(
          access.owner,
          familyId: scope.familyId,
          childId: scope.childId,
        )) {
      throw StateError('资料已不可访问');
    }
    check();
  }

  void _scope(
    SubmissionScope scope,
    SubmissionAccess access,
    Map<String, dynamic> row,
  ) {
    if (row['owner_id'] != access.owner ||
        row['child_id'] != scope.childId ||
        row['family_id'] != scope.familyId) {
      throw StateError('返回资料与当前账号或孩子不符');
    }
  }

  void _detail(
    SubmissionScope scope,
    SubmissionAccess access,
    String draft,
    Map<String, dynamic> row,
  ) {
    _scope(scope, access, row);
    if (row['draft_id'] != draft ||
        !['pending', 'approved'].contains(row['state']) ||
        row['config'] is! Map ||
        (row['state'] == 'approved' && row['question_id'] is! String) ||
        (!access.parent && row['created_by'] != access.owner)) {
      throw StateError('错题提交回执无效');
    }
  }

  Future<Map<String, dynamic>> list(
    SubmissionScope scope,
    SubmissionAccess access, {
    Map<String, dynamic>? cursor,
  }) async {
    await _check(scope, access);
    final row = await remote.list(scope.childId, cursor);
    await _check(scope, access);
    _scope(scope, access, row);
    if (row['items'] is! List || (row['items'] as List).length > 50) {
      throw StateError('错题列表无效');
    }
    final ids = <String>{};
    for (final item in row['items'] as List) {
      if (item is! Map ||
          item['id'] is! String ||
          !ids.add(item['id'] as String) ||
          item['title'] is! String ||
          !['pending', 'approved'].contains(item['state']) ||
          item['submitted_at'] is! String ||
          DateTime.tryParse(item['submitted_at'] as String) == null) {
        throw StateError('错题列表无效');
      }
    }
    final next = row['next_cursor'];
    if (next != null &&
        (next is! Map ||
            next['id'] is! String ||
            next['created_at'] is! String ||
            DateTime.tryParse(next['created_at'] as String) == null ||
            (row['items'] as List).isEmpty ||
            next['id'] != (row['items'] as List).last['id'] ||
            next['created_at'] !=
                (row['items'] as List).last['submitted_at'])) {
      throw StateError('错题分页回执无效');
    }
    return row;
  }

  Future<Map<String, dynamic>> read(
    SubmissionScope scope,
    SubmissionAccess access,
    String draft,
  ) async {
    await _check(scope, access);
    final row = await remote.read(draft);
    await _check(scope, access);
    _detail(scope, access, draft, row);
    final urls = <String>[];
    for (final key in ['original_path', 'processed_path']) {
      final path = row[key];
      if (path == null) continue;
      final expected =
          '${scope.familyId}/$draft/${key == 'original_path' ? 'original' : 'processed'}.jpg';
      if (path != expected) throw StateError('图片不属于当前错题');
      urls.add(await remote.imageUrl(path as String));
      await _check(scope, access);
    }
    return {...row, 'image_urls': urls};
  }

  Future<Map<String, dynamic>> approve(
    SubmissionScope scope,
    SubmissionAccess access,
    String draft,
    String request,
    Map<String, dynamic> config,
  ) async {
    if (!access.parent) throw StateError('请先验证家长 PIN');
    // Freeze all nested values before the first await; retries use the same intent.
    final payload = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    await _check(scope, access);
    final row = await remote.approve(draft, request, payload);
    await _check(scope, access);
    _detail(scope, access, draft, row);
    if (row['state'] != 'approved' || row['confirmed_at'] is! String) {
      throw StateError('未收到家长确认回执，请重试原请求');
    }
    return row;
  }
}

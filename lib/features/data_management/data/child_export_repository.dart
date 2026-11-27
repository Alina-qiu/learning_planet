import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class ChildExportRepository {
  Future<Map<String, dynamic>> preview(String childId);
  Future<Map<String, dynamic>> prepare(
    String childId,
    String requestId,
    Map<String, dynamic> counts,
  );
  Future<Map<String, dynamic>> manifest(String id);
  Future<Map<String, dynamic>> page(String id, String section, int after);
  Future<void> close(String id);
}

final childExportRepositoryProvider = Provider<ChildExportRepository>((ref) {
  final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseChildExportRepository(client);
});
typedef ExportScope = ({String childId, String familyId});
final childExportPreviewProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, ExportScope>((ref, scope) {
      if (ref.watch(activeParentFamilyProvider) != scope.familyId) {
        throw StateError('请返回首页验证家长 PIN');
      }
      return ref.watch(childExportRepositoryProvider).preview(scope.childId);
    });

class SupabaseChildExportRepository implements ChildExportRepository {
  SupabaseChildExportRepository(this.client);
  final SupabaseClient client;
  Future<Map<String, dynamic>> _read(
    String name,
    Map<String, dynamic> params,
  ) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final value = await client
        .rpc<Map<String, dynamic>>(name, params: params)
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    return value;
  }

  @override
  Future<Map<String, dynamic>> preview(String childId) =>
      _read('preview_child_export', {'target_child_id': childId});
  @override
  Future<Map<String, dynamic>> prepare(
    String childId,
    String requestId,
    Map<String, dynamic> counts,
  ) => _read('prepare_child_export', {
    'target_child_id': childId,
    'request_id': requestId,
    'expected_counts': counts,
    'confirmation': '导出孩子数据',
  });
  @override
  Future<Map<String, dynamic>> manifest(String id) =>
      _read('child_export_manifest', {'target_export_id': id});
  @override
  Future<Map<String, dynamic>> page(String id, String section, int after) =>
      _read('read_child_export_page', {
        'target_export_id': id,
        'section_name': section,
        'after_ordinal': after,
      });
  @override
  Future<void> close(String id) => client
      .rpc<void>('close_child_export', params: {'target_export_id': id})
      .timeout(const Duration(seconds: 15));
}

Future<Map<String, dynamic>> collectChildExport(
  ChildExportRepository repository,
  Map<String, dynamic> manifest, {
  required void Function() checkAccess,
  required void Function(int completed, int total) onProgress,
}) async {
  final id = manifest['id'] as String;
  final sections = (manifest['sections'] as List).cast<Map<String, dynamic>>();
  final total = sections.fold<int>(
    0,
    (sum, s) => sum + (s['count'] as num).toInt(),
  );
  final records = <String, dynamic>{};
  var completed = 0;
  for (final section in sections) {
    final name = section['name'] as String,
        count = (section['count'] as num).toInt();
    final rows = <Map<String, dynamic>>[];
    if (count < 0 || records.containsKey(name)) {
      throw const FormatException('导出清单无效');
    }
    var cursor = 0;
    while (cursor < count) {
      checkAccess();
      final response = await repository.page(id, name, cursor);
      checkAccess();
      final batch = (response['rows'] as List).cast<Map<String, dynamic>>();
      final next = response['next_ordinal'] as int;
      if (response['section'] != name ||
          response['total'] != count ||
          batch.isEmpty ||
          next != cursor + batch.length ||
          next > count ||
          response['done'] != (next == count)) {
        throw const FormatException('导出分页不完整，请重新导出');
      }
      rows.addAll(batch);
      cursor = next;
      completed += batch.length;
      onProgress(completed, total);
    }
    records[name] = rows;
  }
  checkAccess();
  return {'manifest': manifest, 'records': records};
}

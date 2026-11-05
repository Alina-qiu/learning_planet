import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

abstract interface class WorksheetRepository {
  Future<void> create(
    String child,
    List<String> ids,
    Map<String, dynamic> config,
    String key,
  );
  Future<void> generate(String id);
  Future<void> delete(String id, String key);
  Future<List<Map<String, dynamic>>> history(String child);
  Future<Uint8List> download(String id);
}

final worksheetRepositoryProvider = Provider<WorksheetRepository>((ref) {
  final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseWorksheetRepository(client);
});
final worksheetHistoryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, child) => ref.watch(worksheetRepositoryProvider).history(child),
    );
final worksheetBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>(
      (ref, id) => ref.watch(worksheetRepositoryProvider).download(id),
    );

void verifyWorksheetBytes(
  Uint8List bytes,
  int expectedSize,
  String expectedHash,
) {
  if (bytes.length < 5 ||
      bytes.length > 20971520 ||
      bytes.length != expectedSize ||
      String.fromCharCodes(bytes.take(5)) != '%PDF-' ||
      sha256.convert(bytes).toString() != expectedHash) {
    throw StateError('PDF 文件完整性校验失败，请重新下载，禁止打印或分享损坏文件');
  }
}

class SupabaseWorksheetRepository implements WorksheetRepository {
  SupabaseWorksheetRepository(this.client);
  final SupabaseClient client;
  @override
  Future<void> delete(String id, String key) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final job = await client
        .rpc<String>(
          'request_worksheet_cleanup',
          params: {
            'target_worksheet_id': id,
            'request_id': key,
            'confirmation': '永久删除',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    if (job != key) throw StateError('清理回执不匹配，请查询原申请');
    final response = await client.functions
        .invoke('permanent-cleanup', body: {'job_id': job})
        .timeout(const Duration(seconds: 20));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    final data = response.data as Map?;
    if (!const {200, 202}.contains(response.status) ||
        data?['job_id'] != key ||
        !const {'running', 'completed'}.contains(data?['status'])) {
      throw StateError('清理尚未确认，请重试同一记录');
    }
  }

  @override
  Future<void> create(
    String child,
    List<String> ids,
    Map<String, dynamic> config,
    String key,
  ) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final receipt = await client
        .rpc<String>(
          'request_worksheet',
          params: {
            'target_child_id': child,
            'question_ids': List<String>.of(ids),
            'config': jsonDecode(jsonEncode(config)),
            'request_id': key,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    if (receipt != key) throw StateError('组卷回执不匹配，请查询原申请');
    await generate(key);
  }

  @override
  Future<void> generate(String id) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final result = await client.functions
        .invoke('worksheet-render', body: {'worksheet_id': id})
        .timeout(const Duration(seconds: 20));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    final data = result.data as Map?;
    if (!const {200, 202}.contains(result.status) ||
        data?['id'] != id ||
        !const {'running', 'ready'}.contains(data?['status'])) {
      throw StateError('生成尚未确认，请在历史记录重试同一份组卷');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> history(String child) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += 500) {
      final page = await client
          .from('worksheet_jobs')
          .select()
          .eq('child_id', child)
          .order('created_at', ascending: false)
          .order('id')
          .range(offset, offset + 499)
          .timeout(const Duration(seconds: 15));
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      rows.addAll(page);
      if (page.length < 500) return rows;
    }
  }

  @override
  Future<Uint8List> download(String id) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final row = await client
        .from('worksheet_jobs')
        .select('status,pdf_path,byte_size,sha256,expires_at')
        .eq('id', id)
        .single()
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    if (row['status'] != 'ready' ||
        !DateTime.parse(row['expires_at'] as String).isAfter(DateTime.now())) {
      throw StateError('PDF 尚未完成、已删除或超过30天保留期');
    }
    final bytes = await client.storage
        .from('worksheets')
        .download(row['pdf_path'] as String)
        .timeout(const Duration(seconds: 30));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    verifyWorksheetBytes(
      bytes,
      row['byte_size'] as int,
      row['sha256'] as String,
    );
    return bytes;
  }
}

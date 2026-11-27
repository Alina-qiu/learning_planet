import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../domain/pinyin_import.dart';

abstract interface class PinyinImportRepository {
  Future<Map<String, dynamic>> importWords(
    String childId,
    String requestId,
    List<Map<String, dynamic>> entries,
  );
}

final pinyinImportRepositoryProvider = Provider<PinyinImportRepository>((ref) {
  final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
  if (client == null) throw StateError('请配置 Supabase');
  return SupabasePinyinImportRepository(client);
});

class SupabasePinyinImportRepository implements PinyinImportRepository {
  SupabasePinyinImportRepository(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> importWords(
    String childId,
    String requestId,
    List<Map<String, dynamic>> entries,
  ) => client
      .rpc<Map<String, dynamic>>(
        'import_pinyin_words',
        params: {
          'target_child_id': childId,
          'request_id': requestId,
          'entries': entries,
        },
      )
      .timeout(const Duration(seconds: 30));
}

final pinyinFileReaderProvider = Provider<Future<String?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'txt'],
    );
    if (picked.isEmpty) return null;
    final file = picked.single;
    if ((file.lengthSync() ?? 0) > pinyinImportMaxBytes) {
      throw const FormatException('文件不能超过256 KiB');
    }
    final stream = file.readAsByteStream();
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > pinyinImportMaxBytes) {
        throw const FormatException('文件不能超过256 KiB');
      }
      bytes.addAll(chunk);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('请将文件保存为UTF-8格式后再导入');
    }
  },
);

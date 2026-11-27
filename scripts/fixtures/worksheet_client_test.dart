import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/worksheets/data/worksheet_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final raw = Platform.environment['LP_WORKSHEET_CONFIG'];
  if (raw == null) {
    throw StateError('Run scripts/test_worksheet_integration.mjs');
  }
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final url = config['url'] as String, key = config['anon'] as String;
  final uri = Uri.parse(url);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('Disposable loopback backend required');
  }
  final clients = <SupabaseClient>[];
  late SupabaseClient parent, other;
  late SupabaseWorksheetRepository repository;
  final child = config['child'] as String;
  final mixed = config['mixedId'] as String,
      retry = config['retryId'] as String;
  Future<SupabaseClient> client(String identity) async {
    final value = SupabaseClient(
      url,
      key,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    clients.add(value);
    await value.auth.recoverSession(jsonEncode(config[identity]));
    return value;
  }

  Future<Map<String, dynamic>> ready(String id) async {
    for (var attempt = 0; attempt < 150; attempt++) {
      final row = (await repository.history(
        child,
      )).singleWhere((row) => row['id'] == id);
      if (row['status'] == 'ready') return row;
      if (row['status'] == 'failed') {
        throw StateError('PDF failed: ${row['error_code']}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('PDF not ready');
  }

  Future<void> saveSample(String id, String filename) async {
    final bytes = await repository.download(id);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(
      await repository.download(id),
      bytes,
      reason: 'Preview and export must receive the identical verified file',
    );
    await File(
      '${config['output']}/$filename',
    ).writeAsBytes(bytes, flush: true);
  }

  setUpAll(() async {
    parent = await client('owner');
    other = await client('other');
    repository = SupabaseWorksheetRepository(parent);
  });
  tearDownAll(() async {
    for (final value in clients) {
      await value.dispose();
    }
  });

  test(
    'actual repository generates and downloads a frozen worksheet through Edge and Storage',
    () async {
      await repository.generate(mixed);
      final row = await ready(mixed);
      expect(row['progress'], 100);
      expect(row['pages'], 2);
      expect(row['attempts'], 1);
      await saveSample(mixed, 'local-service-mixed.pdf');
      await repository.generate(mixed);
      expect((await ready(mixed))['attempts'], 1);
    },
  );

  test(
    'actual repository retries failed upload with the original ID and exports a landscape pinyin worksheet',
    () async {
      expect(
        (await repository.history(
          child,
        )).singleWhere((row) => row['id'] == retry)['status'],
        'failed',
      );
      await repository.create(
        child,
        (config['retryIds'] as List).cast<String>(),
        Map<String, dynamic>.from(config['retryConfig'] as Map),
        retry,
      );
      final row = await ready(retry);
      expect(row['attempts'], 2);
      expect(row['pages'], 1);
      await saveSample(retry, 'local-service-pinyin.pdf');
      expect((await repository.history(child)).length, 2);
    },
  );

  test(
    'another real account cannot read PDF history, download bytes or invoke generation',
    () async {
      final denied = SupabaseWorksheetRepository(other);
      expect(await denied.history(child), isEmpty);
      await expectLater(
        denied.download(mixed),
        throwsA(isA<PostgrestException>()),
      );
      await expectLater(
        denied.generate(mixed),
        throwsA(isA<FunctionException>()),
      );
      final row = (await repository.history(
        child,
      )).singleWhere((row) => row['id'] == mixed);
      await expectLater(
        other.storage.from('worksheets').download(row['pdf_path'] as String),
        throwsA(isA<StorageException>()),
      );
    },
  );
}

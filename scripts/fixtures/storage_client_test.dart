// Run with scripts/test_storage.mjs: real Auth, PostgREST, Storage and S3 bytes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/email_otp.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/child_question_submissions.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class LoseUploadReply extends http.BaseClient {
  final inner = http.Client();
  int lost = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (lost == 0 &&
        request.method == 'POST' &&
        request.url.path.startsWith(
          '/storage/v1/object/wrong-question-images/',
        ) &&
        response.statusCode == 200) {
      await response.stream.drain<void>();
      lost++;
      throw http.ClientException(
        'Injected upload reply loss after server commit',
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final raw = Platform.environment['LP_STORAGE_CONFIG'];
  if (raw == null) throw StateError('Run node scripts/test_storage.mjs');
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final url = config['url'] as String, key = config['anon'] as String;
  final uri = Uri.parse(url);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('Disposable loopback backend required');
  }
  const uuid = Uuid(), bucket = 'wrong-question-images';
  final storageRejection = isA<StorageException>().having(
    (error) => error.statusCode,
    'client rejection status',
    isIn(['400', '401', '403', '404', '413', '415']),
  );
  const input = <String, dynamic>{
    'kind': 'question',
    'subject': 'math',
    'prompt': '2+2=?',
    'answers': <String>[],
    'ocr_confirmed': true,
    'requires_parent_review': true,
  };
  const recognition = <String, dynamic>{
    'text': '2+Z=?',
    'lines': [
      {'text': '2+Z=?', 'confidence': 0.5},
    ],
  };
  final original = Uint8List.fromList(
    img.encodePng(img.Image(width: 3, height: 2)),
  );
  final processed = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 3)),
  );
  final answer = <String, dynamic>{
    ...input,
    'answers': ['4'],
    'explanation': '两组两个，共四个',
  };
  final clients = <SupabaseClient>[];
  final repositories = <SupabaseAuthRepository>[];
  Future<SupabaseClient> account({http.Client? transport}) async {
    final client = SupabaseClient(
      url,
      key,
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    clients.add(client);
    final repository = SupabaseAuthRepository(
      client,
      emailOtp: EmailOtpTransport(
        () => GoTrueClient(
          url: '$url/auth/v1',
          headers: {'apikey': key},
          autoRefreshToken: false,
          flowType: AuthFlowType.implicit,
        ),
      ),
    );
    repositories.add(repository);
    final email = 'media-${uuid.v4()}@example.test';
    await repository.sendEmailOtp(email);
    final response = await http.get(
      Uri.parse('$url/__test/mail').replace(queryParameters: {'email': email}),
      headers: {'x-test-mailbox-key': config['mailboxKey'] as String},
    );
    expect(response.statusCode, 200);
    await repository.verifyEmailOtp(
      email,
      (jsonDecode(response.body) as Map)['code'] as String,
      isCurrent: () => true,
    );
    return client;
  }

  Future<({String family, String child})> family(SupabaseClient client) async {
    final families = SupabaseFamilyRepository(client);
    await families.createFamilyWithChild(
      familyName: '图片验证家庭',
      timezone: 'Asia/Shanghai',
      childNickname: '小星',
      grade: 2,
    );
    final family = (await families.loadFamilies()).single.id;
    final child =
        (await client
                .from('children')
                .select('id')
                .eq('family_id', family)
                .single())['id']
            as String;
    return (family: family, child: child);
  }

  Future<void> authorize(SupabaseClient client, String family) async {
    final repository = SupabaseFamilyRepository(client);
    await repository.setParentPin(familyId: family, pin: '2468');
    expect(
      (await repository.verifyParentPin(
        familyId: family,
        pin: '2468',
      )).verified,
      isTrue,
    );
  }

  SupabaseQuestionMediaRepository media(SupabaseClient client) =>
      SupabaseQuestionMediaRepository(client, SupabaseReviewRepository(client));
  Future<Map<String, dynamic>> begin(SupabaseClient client, String child) =>
      client.rpc<Map<String, dynamic>>(
        'begin_child_question_upload',
        params: {
          'target_child_id': child,
          'draft_id': uuid.v4(),
          'payload_hash': 'a' * 64,
        },
      );
  tearDown(() async {
    for (final repository in repositories.reversed) {
      await repository.dispose();
    }
    for (final client in clients.reversed) {
      await client.dispose();
    }
    repositories.clear();
    clients.clear();
  });

  test(
    'child uploads real original and processed bytes; parent PIN confirms exactly one question before review',
    () async {
      final client = await account(),
          scope = await family(client),
          draft = uuid.v4();
      final repository = media(client),
          submissions = SupabaseChildSubmissionRemote(client);
      await repository.save(
        scope.child,
        draft,
        original,
        processed,
        recognition,
        input,
      );
      final pending = await submissions.read(draft);
      expect(pending['state'], 'pending');
      expect(pending['question_id'], isNull);
      for (final table in [
        'wrong_questions',
        'task_instances',
        'ledger_entries',
      ]) {
        expect(
          await client.from(table).select('id').eq('child_id', scope.child),
          isEmpty,
        );
      }
      expect(
        await client.rpc<dynamic>(
          'generate_daily_wrong_review_task',
          params: {'target_child_id': scope.child},
        ),
        isNull,
      );
      for (final entry in {
        'original_path': original,
        'processed_path': processed,
      }.entries) {
        final signed = await repository.imageUrl(pending[entry.key] as String);
        final response = await http.get(Uri.parse(signed));
        expect(response.statusCode, 200);
        expect(response.bodyBytes, entry.value);
        expect(response.headers['content-type'], startsWith('image/png'));
      }
      await expectLater(
        submissions.approve(draft, uuid.v4(), answer),
        throwsA(isA<PostgrestException>()),
      );
      await authorize(client, scope.family);
      final request = uuid.v4(),
          approved = await submissions.approve(draft, request, answer);
      expect(approved['state'], 'approved');
      expect(await submissions.approve(draft, request, answer), approved);
      expect(
        (await client
                .from('wrong_questions')
                .select('id')
                .eq('child_id', scope.child))
            .length,
        1,
      );
      expect(
        await client
            .from('ledger_entries')
            .select('id')
            .eq('child_id', scope.child),
        isEmpty,
      );
      expect(
        await client.rpc<dynamic>(
          'generate_daily_wrong_review_task',
          params: {'target_child_id': scope.child},
        ),
        isA<String>(),
      );
      final provenance = await repository.provenance(
        approved['question_id'] as String,
      );
      expect(provenance!['raw_text'], recognition['text']);
    },
  );

  test(
    'private images reject anonymous and another family access, tampered signatures and unauthorized upload',
    () async {
      final client = await account(),
          scope = await family(client),
          draft = uuid.v4();
      await media(
        client,
      ).save(scope.child, draft, original, processed, null, input);
      final pending = await SupabaseChildSubmissionRemote(client).read(draft),
          path = pending['original_path'] as String;
      final outsider = await account();
      await expectLater(
        outsider.storage.from(bucket).download(path),
        throwsA(storageRejection),
      );
      await expectLater(
        outsider.storage.from(bucket).createSignedUrl(path, 300),
        throwsA(storageRejection),
      );
      await expectLater(
        outsider.storage
            .from(bucket)
            .uploadBinary(
              path,
              processed,
              fileOptions: const FileOptions(contentType: 'image/png'),
            ),
        throwsA(storageRejection),
      );
      final publicUrl = client.storage.from(bucket).getPublicUrl(path);
      expect(
        (await http.get(Uri.parse(publicUrl))).statusCode,
        isIn([400, 401, 403, 404]),
      );
      expect(
        (await http.get(
          Uri.parse('$url/storage/v1/object/authenticated/$bucket/$path'),
        )).statusCode,
        isIn([400, 401, 403, 404]),
      );
      final signed = Uri.parse(await media(client).imageUrl(path));
      final token = signed.queryParameters['token']!;
      final tampered = signed.replace(
        queryParameters: {
          ...signed.queryParameters,
          'token': '${token[0] == 'a' ? 'b' : 'a'}${token.substring(1)}',
        },
      );
      expect((await http.get(tampered)).statusCode, isIn([400, 401, 403, 404]));
      expect(await client.storage.from(bucket).download(path), original);
    },
  );

  test(
    'lost upload response retries the stable original path without duplicate objects or changed bytes',
    () async {
      final transport = LoseUploadReply(),
          client = await account(transport: transport),
          scope = await family(client),
          draft = uuid.v4();
      final repository = media(client);
      await expectLater(
        repository.save(
          scope.child,
          draft,
          original,
          processed,
          recognition,
          input,
        ),
        throwsA(anyOf(isA<StorageException>(), isA<http.ClientException>())),
      );
      expect(transport.lost, 1);
      await repository.save(
        scope.child,
        draft,
        original,
        processed,
        recognition,
        input,
      );
      await repository.save(
        scope.child,
        draft,
        original,
        processed,
        recognition,
        input,
      );
      final pending = await SupabaseChildSubmissionRemote(client).read(draft);
      expect(pending['state'], 'pending');
      final path = pending['original_path'] as String;
      final files = await client.storage
          .from(bucket)
          .list(path: path.substring(0, path.lastIndexOf('/')));
      expect(files.length, 2);
      expect(await client.storage.from(bucket).download(path), original);
      expect(
        await client.storage
            .from(bucket)
            .download(pending['processed_path'] as String),
        processed,
      );
      await expectLater(
        client.storage
            .from(bucket)
            .uploadBinary(
              path,
              processed,
              fileOptions: const FileOptions(
                contentType: 'image/png',
                upsert: true,
              ),
            ),
        throwsA(storageRejection),
      );
      expect(await client.storage.from(bucket).download(path), original);
    },
  );

  test(
    'Storage enforces bucket MIME and size limits; absent images cannot become submitted questions',
    () async {
      final client = await account(),
          scope = await family(client),
          draft = await begin(client, scope.child);
      final path = draft['original_path'] as String;
      await expectLater(
        client.storage
            .from(bucket)
            .uploadBinary(
              path,
              original,
              fileOptions: const FileOptions(contentType: 'text/plain'),
            ),
        throwsA(storageRejection),
      );
      await expectLater(
        client.storage
            .from(bucket)
            .uploadBinary(
              path,
              Uint8List(10485761),
              fileOptions: const FileOptions(contentType: 'image/png'),
            ),
        throwsA(storageRejection),
      );
      await expectLater(
        client.rpc<Map<String, dynamic>>(
          'submit_child_question',
          params: {
            'target_draft_id': draft['id'],
            'config': input,
            'recognition': null,
          },
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(
        await client.storage
            .from(bucket)
            .list(path: path.substring(0, path.lastIndexOf('/'))),
        isEmpty,
      );
      expect(
        await client
            .from('wrong_questions')
            .select('id')
            .eq('child_id', scope.child),
        isEmpty,
      );
    },
  );

  test(
    'parent image capture saves the recognized question through the actual media repository',
    () async {
      final client = await account(),
          scope = await family(client),
          draft = uuid.v4();
      await authorize(client, scope.family);
      final repository = media(client);
      await repository.save(
        scope.child,
        draft,
        original,
        processed,
        recognition,
        {...answer, 'requires_parent_review': false},
      );
      final questions = await SupabaseReviewRepository(
        client,
      ).questions(scope.child);
      expect(questions.length, 1);
      final provenance = await repository.provenance(
        questions.single['id'] as String,
      );
      expect(provenance!['raw_text'], recognition['text']);
      expect(
        (await http.get(
          Uri.parse(
            await repository.imageUrl(provenance['processed_path'] as String),
          ),
        )).bodyBytes,
        processed,
      );
    },
  );
}

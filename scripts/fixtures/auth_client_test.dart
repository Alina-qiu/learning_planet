// Real GoTrue sessions and SMTP-delivered OTPs. Run through scripts/test_auth.mjs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/email_otp.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class HoldVerification extends http.BaseClient {
  final inner = http.Client();
  final received = Completer<void>(), release = Completer<void>();
  bool hold = true;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (hold && request.url.path.endsWith('/verify')) {
      hold = false;
      final body = await response.stream.toBytes();
      received.complete();
      await release.future;
      return http.StreamedResponse(
        Stream.value(body),
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final raw = Platform.environment['LP_AUTH_CONFIG'];
  if (raw == null) throw StateError('Run node scripts/test_auth.mjs');
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final url = config['url'] as String, key = config['anon'] as String;
  final uri = Uri.parse(url);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('Local fixture required');
  }
  const uuid = Uuid();
  final clients = <SupabaseClient>[];
  final repositories = <SupabaseAuthRepository>[];
  String email() => 'parent-${uuid.v4()}@example.test';
  EmailOtpTransport transport([http.Client? network]) => EmailOtpTransport(
    () => GoTrueClient(
      url: '$url/auth/v1',
      headers: {'apikey': key},
      autoRefreshToken: false,
      flowType: AuthFlowType.implicit,
      httpClient: network,
    ),
  );
  ({SupabaseClient client, SupabaseAuthRepository repository}) account({
    http.Client? network,
    Duration wait = const Duration(seconds: 20),
  }) {
    final client = SupabaseClient(
      url,
      key,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final repository = SupabaseAuthRepository(
      client,
      emailOtp: transport(network),
      loginWait: wait,
    );
    clients.add(client);
    repositories.add(repository);
    return (client: client, repository: repository);
  }

  Future<Map<String, dynamic>> mail(String address) async {
    final response = await http.get(
      Uri.parse(
        '$url/__test/mail',
      ).replace(queryParameters: {'email': address}),
      headers: {'x-test-mailbox-key': config['mailboxKey'] as String},
    );
    expect(response.statusCode, 200);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> login(SupabaseAuthRepository repository, String address) async {
    await repository.sendEmailOtp(address);
    final code = (await mail(address))['code'] as String;
    await repository.verifyEmailOtp(address, code, isCurrent: () => true);
  }

  Map<String, dynamic> claims(Session session) =>
      jsonDecode(
            utf8.decode(
              base64Url.decode(
                base64Url.normalize(session.accessToken.split('.')[1]),
              ),
            ),
          )
          as Map<String, dynamic>;
  Future<String> family(SupabaseClient client) async {
    final families = SupabaseFamilyRepository(client);
    await families.createFamilyWithChild(
      familyName: '真实登录家庭',
      timezone: 'Asia/Shanghai',
      childNickname: '小星',
      grade: 2,
    );
    return (await families.loadFamilies()).single.id;
  }

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
    'real signup sends the project eight-digit template, throttles resend and rejects wrong/reused OTPs',
    () async {
      final user = account(), address = email();
      await user.repository.sendEmailOtp('  ${address.toUpperCase()}  ');
      expect(user.repository.currentSession, isNull);
      final message = await mail(address), code = message['code'] as String;
      expect(code, matches(r'^\d{8}$'));
      expect(message['html'], contains('登录学习星球'));
      expect(message['count'], 1);
      await expectLater(
        user.repository.sendEmailOtp(address),
        throwsA(isA<AuthException>()),
      );
      expect((await mail(address))['count'], 1);
      final wrong = '${code[0] == '0' ? '1' : '0'}${code.substring(1)}';
      await expectLater(
        user.repository.verifyEmailOtp(address, wrong, isCurrent: () => true),
        throwsA(isA<AuthException>()),
      );
      expect(user.repository.currentSession, isNull);
      await user.repository.verifyEmailOtp(
        address,
        code,
        isCurrent: () => true,
      );
      final session = user.client.auth.currentSession!;
      expect(user.repository.currentSession!.email, address);
      expect(claims(session)['session_id'], isA<String>());
      expect(claims(session)['sub'], user.repository.currentSession!.userId);
      expect((await user.client.auth.getUser()).user!.id, session.user.id);
      await expectLater(
        transport().verify(address, code),
        throwsA(isA<AuthException>()),
      );
    },
  );

  test(
    'token refresh keeps the same PIN session, another login has no PIN, and logout revokes only its own session',
    () async {
      final user = account(), peer = account(), address = email();
      await login(user.repository, address);
      final id = await family(user.client),
          families = SupabaseFamilyRepository(user.client);
      await families.setParentPin(familyId: id, pin: '2468');
      expect(
        (await families.verifyParentPin(familyId: id, pin: '2468')).verified,
        isTrue,
      );
      final before = user.client.auth.currentSession!;
      await user.client.auth.refreshSession();
      final refreshed = user.client.auth.currentSession!;
      expect(claims(refreshed)['session_id'], claims(before)['session_id']);
      expect(refreshed.refreshToken, isNot(before.refreshToken));
      await families.createChild(familyId: id, nickname: '刷新后', grade: 2);
      // A confirmed account uses the project's magic-link OTP template on subsequent sign-in.
      await login(peer.repository, address);
      expect(
        peer.repository.currentSession!.userId,
        user.repository.currentSession!.userId,
      );
      expect(
        claims(peer.client.auth.currentSession!)['session_id'],
        isNot(claims(refreshed)['session_id']),
      );
      await expectLater(
        SupabaseFamilyRepository(
          peer.client,
        ).createChild(familyId: id, nickname: '禁止', grade: 2),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      await user.repository.signOut();
      expect(user.repository.currentSession, isNull);
      final replay = SupabaseClient(
        url,
        key,
        accessToken: () async => refreshed.accessToken,
      );
      clients.add(replay);
      await expectLater(
        replay.rpc<dynamic>(
          'family_time_settings',
          params: {'target_family_id': id},
        ),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      int status = 200;
      for (var attempt = 0; attempt < 20 && status == 200; attempt++) {
        final response = await http.post(
          Uri.parse('$url/auth/v1/token?grant_type=refresh_token'),
          headers: {'apikey': key, 'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshed.refreshToken}),
        );
        status = response.statusCode;
        if (status == 200) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(status, anyOf(400, 401));
      expect((await peer.client.auth.getUser()).user!.email, address);
    },
  );

  test(
    'separate real Auth users cannot read or modify another family',
    () async {
      final first = account(), second = account();
      await login(first.repository, email());
      await login(second.repository, email());
      final familyId = await family(first.client);
      final childId = (await SupabaseFamilyRepository(
        first.client,
      ).loadFamilies()).single.children.single.id;
      expect(
        await SupabaseFamilyRepository(second.client).loadFamilies(),
        isEmpty,
      );
      await family(second.client);
      expect(
        await second.client.from('children').select().eq('id', childId),
        isEmpty,
      );
      await expectLater(
        second.client.rpc<dynamic>(
          'family_time_settings',
          params: {'target_family_id': familyId},
        ),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      expect(
        first.repository.currentSession!.userId,
        isNot(second.repository.currentSession!.userId),
      );
    },
  );

  test(
    'a genuinely issued persisted session restores the same family and refreshes through Auth',
    () async {
      final first = account();
      await login(first.repository, email());
      final id = await family(first.client),
          saved = first.client.auth.currentSession!;
      final restored = account();
      await restored.client.auth.recoverSession(jsonEncode(saved.toJson()));
      expect(
        restored.repository.currentSession!.userId,
        first.repository.currentSession!.userId,
      );
      await restored.client.auth.refreshSession();
      expect(
        claims(restored.client.auth.currentSession!)['session_id'],
        claims(saved)['session_id'],
      );
      expect(
        (await SupabaseFamilyRepository(
          restored.client,
        ).loadFamilies()).single.id,
        id,
      );
    },
  );

  test(
    'a late successful real OTP verification cannot log in after the app has timed out',
    () async {
      final hold = HoldVerification();
      final user = account(
        network: hold,
        wait: const Duration(milliseconds: 300),
      );
      final address = email();
      try {
        // Only verification has a deliberately short deadline; signup/mail delivery uses its normal one.
        await account().repository.sendEmailOtp(address);
        final code = (await mail(address))['code'] as String;
        final result = user.repository.verifyEmailOtp(
          address,
          code,
          isCurrent: () => true,
        );
        final rejected = expectLater(result, throwsA(isA<TimeoutException>()));
        await hold.received.future.timeout(const Duration(seconds: 10));
        await rejected;
        expect(user.repository.currentSession, isNull);
        hold.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(user.repository.currentSession, isNull);
        // The server consumed that OTP; retrying it through a new SDK request is rejected.
        await expectLater(
          transport().verify(address, code),
          throwsA(isA<AuthException>()),
        );
      } finally {
        if (!hold.release.isCompleted) hold.release.complete();
        hold.close();
      }
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/email_otp.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/presentation/login_screen.dart';
import 'widget_test.dart' as fixture;

Map<String, dynamic> session({
  String user = 'parent',
  String email = 'parent@example.test',
  int seconds = 3600,
}) => {
  'access_token':
      'header.${base64UrlEncode(utf8.encode(jsonEncode({'sub': user, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + seconds})))}.signature',
  'refresh_token': 'local-$user',
  'token_type': 'bearer',
  'expires_in': seconds,
  'user': {
    'id': user,
    'email': email,
    'aud': 'authenticated',
    'role': 'authenticated',
    'app_metadata': {},
    'user_metadata': {},
    'created_at': '2026-11-05T00:00:00Z',
  },
};

class Harness {
  Harness({Duration wait = const Duration(seconds: 20)}) {
    transport = MockClient((request) async {
      calls.add(request);
      return handle(request);
    });
    client = SupabaseClient(
      'https://example.test',
      'public-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    repository = SupabaseAuthRepository(
      client,
      loginWait: wait,
      emailOtp: EmailOtpTransport(
        () => GoTrueClient(
          url: 'https://example.test/auth/v1',
          headers: {'apikey': 'public-key'},
          httpClient: transport,
          autoRefreshToken: false,
          flowType: AuthFlowType.implicit,
        ),
      ),
    );
  }
  final calls = <http.Request>[];
  late final MockClient transport;
  late final SupabaseClient client;
  late final SupabaseAuthRepository repository;
  FutureOr<http.Response> Function(http.Request) handle = (request) =>
      reply(request.url.path.endsWith('/verify') ? session() : {});
  static http.Response reply(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {
      'content-type': 'application/json',
      'x-supabase-api-version': '2024-01-01',
    },
  );
  Future<void> close() async {
    await repository.dispose();
    await client.dispose();
  }
}

class LoginFake implements AuthRepository {
  final changes = StreamController<AuthSession?>.broadcast();
  AuthSession? active;
  final sent = <String>[];
  final verified = <(String, String)>[];
  Future<void> Function()? sending, verifying;
  bool Function()? currentCheck;
  bool commit = false;
  @override
  AuthSession? get currentSession => active;
  @override
  Stream<AuthSession?> watchSession() async* {
    yield active;
    yield* changes.stream;
  }

  @override
  Future<void> sendEmailOtp(String email) async {
    sent.add(email);
    await sending?.call();
  }

  @override
  Future<void> verifyEmailOtp(
    String email,
    String code, {
    required bool Function() isCurrent,
  }) async {
    verified.add((email, code));
    currentCheck = isCurrent;
    await verifying?.call();
    if (commit && isCurrent()) {
      active = AuthSession(userId: 'parent', email: email);
      changes.add(active);
    }
  }

  @override
  Future<void> signOut() async {
    active = null;
    changes.add(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real SDK sends and verifies email code, commits one fresh session without a second network call',
    () async {
      final h = Harness();
      addTearDown(h.close);
      final observed = <AuthSession?>[];
      final sub = h.repository.watchSession().listen(observed.add);
      addTearDown(sub.cancel);
      await h.repository.sendEmailOtp('  PARENT@example.test  ');
      expect(h.client.auth.currentSession, isNull);
      expect(h.calls.single.url.path, '/auth/v1/otp');
      final body = jsonDecode(h.calls.single.body) as Map;
      expect(body['email'], 'parent@example.test');
      expect(body['create_user'], true);
      expect(body['code_challenge'], isNull);
      expect(h.calls.single.headers['apikey'], 'public-key');
      await h.repository.verifyEmailOtp(
        ' PARENT@example.test ',
        ' 12345678 ',
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.map((call) => call.url.path), [
        '/auth/v1/otp',
        '/auth/v1/verify',
      ]);
      expect(jsonDecode(h.calls.last.body), containsPair('type', 'email'));
      expect(jsonDecode(h.calls.last.body), containsPair('token', '12345678'));
      expect(h.repository.currentSession?.userId, 'parent');
      expect(observed.last?.userId, 'parent');
    },
  );
  test(
    'invalid input and concurrent send or verification never add requests',
    () async {
      final h = Harness();
      addTearDown(h.close);
      await expectLater(
        h.repository.sendEmailOtp('bad'),
        throwsFormatException,
      );
      await expectLater(
        h.repository.verifyEmailOtp(
          'parent@example.test',
          '12345',
          isCurrent: () => true,
        ),
        throwsFormatException,
      );
      expect(h.calls, isEmpty);
      final pending = Completer<http.Response>(), started = Completer<void>();
      h.handle = (_) {
        started.complete();
        return pending.future;
      };
      final first = h.repository.sendEmailOtp('parent@example.test');
      await started.future;
      await expectLater(
        h.repository.sendEmailOtp('other@example.test'),
        throwsA(isA<EmailLoginChanged>()),
      );
      await expectLater(
        h.repository.verifyEmailOtp(
          'parent@example.test',
          '123456',
          isCurrent: () => true,
        ),
        throwsA(isA<EmailLoginChanged>()),
      );
      pending.complete(Harness.reply({}));
      await first;
      expect(h.calls, hasLength(1));
    },
  );
  test(
    'server rejection exposes only fixed messages and can be retried',
    () async {
      final h = Harness();
      addTearDown(h.close);
      h.handle = (_) => Harness.reply({
        'code': 'otp_expired',
        'msg': 'private code 12345678 parent@example.test',
      }, 403);
      Object? error;
      try {
        await h.repository.verifyEmailOtp(
          'parent@example.test',
          '12345678',
          isCurrent: () => true,
        );
      } catch (value) {
        error = value;
      }
      expect(error, isA<AuthException>());
      expect(emailOtpError(error!, verifying: true), '验证码无效或已过期，请检查邮件或重新发送。');
      expect(h.repository.currentSession, isNull);
      h.handle = (_) => Harness.reply(session());
      await h.repository.verifyEmailOtp(
        'parent@example.test',
        '12345678',
        isCurrent: () => true,
      );
      expect(h.repository.currentSession?.userId, 'parent');
    },
  );
  test(
    'timeout releases the form and a late verify cannot replace another login',
    () async {
      final h = Harness(wait: const Duration(milliseconds: 25));
      addTearDown(h.close);
      final pending = Completer<http.Response>();
      h.handle = (_) => pending.future;
      await expectLater(
        h.repository.verifyEmailOtp(
          'parent@example.test',
          '12345678',
          isCurrent: () => true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(h.repository.currentSession, isNull);
      await h.client.auth.recoverSession(
        jsonEncode(session(user: 'new', email: 'new@example.test')),
      );
      pending.complete(Harness.reply(session()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.repository.currentSession?.userId, 'new');
    },
  );
  test(
    'page cancellation and repository disposal discard in-flight verification',
    () async {
      for (final dispose in [false, true]) {
        final h = Harness();
        final pending = Completer<http.Response>(), started = Completer<void>();
        h.handle = (_) {
          started.complete();
          return pending.future;
        };
        var current = true;
        final result = h.repository.verifyEmailOtp(
          'parent@example.test',
          '12345678',
          isCurrent: () => current,
        );
        final assertion = expectLater(
          result,
          throwsA(isA<EmailLoginChanged>()),
        );
        await started.future;
        if (dispose) {
          await h.repository.dispose();
        } else {
          current = false;
        }
        pending.complete(Harness.reply(session()));
        await assertion;
        expect(h.repository.currentSession, isNull);
        await h.close();
      }
    },
  );
  test(
    'sign-in then sign-out while verification waits invalidates the original attempt',
    () async {
      final h = Harness();
      addTearDown(h.close);
      final pending = Completer<http.Response>(), started = Completer<void>();
      h.handle = (r) {
        if (r.url.path.endsWith('/verify')) {
          started.complete();
          return pending.future;
        }
        return Harness.reply({});
      };
      final result = h.repository.verifyEmailOtp(
        'parent@example.test',
        '12345678',
        isCurrent: () => true,
      );
      final assertion = expectLater(result, throwsA(isA<EmailLoginChanged>()));
      await started.future;
      await h.client.auth.recoverSession(jsonEncode(session(user: 'other')));
      await h.repository.signOut();
      pending.complete(Harness.reply(session()));
      await assertion;
      expect(h.repository.currentSession, isNull);
    },
  );
  test(
    'missing, near-expired and different-email sessions never reach the main client',
    () async {
      final h = Harness();
      addTearDown(h.close);
      for (final reply in [
        {},
        session(seconds: 30),
        session(email: 'other@example.test'),
        {...session(), 'refresh_token': ''},
      ]) {
        h.handle = (_) => Harness.reply(reply);
        await expectLater(
          h.repository.verifyEmailOtp(
            'parent@example.test',
            '12345678',
            isCurrent: () => true,
          ),
          throwsA(isA<AuthException>()),
        );
        expect(h.repository.currentSession, isNull);
      }
      expect(h.calls.every((r) => r.url.path.endsWith('/verify')), true);
    },
  );
  test(
    'error messages do not expose response bodies or reveal account existence',
    () {
      for (final error in [
        const AuthException('private email/token', statusCode: '429'),
        const AuthException(
          'private email/token',
          code: 'over_email_send_rate_limit',
        ),
        const AuthException('private email/token', code: 'user_not_found'),
        TimeoutException('private email/token'),
        StateError('private email/token'),
        const EmailLoginChanged(),
      ]) {
        for (final verifying in [false, true]) {
          final message = emailOtpError(error, verifying: verifying);
          expect(message, isNot(contains('private')));
          expect(message, isNot(contains('不存在')));
        }
      }
    },
  );

  Future<LoginFake> mount(WidgetTester tester, {bool app = false}) async {
    final fake = LoginFake();
    addTearDown(fake.changes.close);
    await tester.pumpWidget(
      app
          ? LearningPlanetApp(
              authRepository: fake,
              familyRepository: fixture.FakeFamilyRepository.withChild(),
              taskRepository: fixture.FakeTaskRepository(),
            )
          : ProviderScope(
              overrides: [authRepositoryProvider.overrideWithValue(fake)],
              child: const MaterialApp(home: LoginScreen()),
            ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  Future<void> enterEmail(WidgetTester tester, {bool existing = false}) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, '家长邮箱'),
      ' PARENT@example.test ',
    );
    await tester.tap(find.text(existing ? '已有验证码' : '发送验证码'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'existing code can log in through the app without requesting another email',
    (tester) async {
      final fake = await mount(tester, app: true);
      fake.commit = true;
      await enterEmail(tester, existing: true);
      await tester.enterText(
        find.widgetWithText(TextFormField, '邮箱验证码'),
        '12345678',
      );
      await tester.tap(find.text('验证并登录'));
      await tester.pumpAndSettle();
      expect(fake.sent, isEmpty);
      expect(fake.verified.single, ('parent@example.test', '12345678'));
      expect(find.text('今日任务'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'invalid email and incomplete code stay local, change email clears the code',
    (tester) async {
      final fake = await mount(tester);
      await tester.tap(find.text('发送验证码'));
      await tester.pumpAndSettle();
      expect(find.text('请输入邮箱地址'), findsOneWidget);
      expect(fake.sent, isEmpty);
      await enterEmail(tester, existing: true);
      await tester.enterText(
        find.widgetWithText(TextFormField, '邮箱验证码'),
        '123',
      );
      await tester.tap(find.text('验证并登录'));
      await tester.pumpAndSettle();
      expect(find.text('请输入完整的数字验证码'), findsOneWidget);
      expect(fake.verified, isEmpty);
      await tester.tap(find.text('更换邮箱'));
      await tester.pumpAndSettle();
      await enterEmail(tester, existing: true);
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, '邮箱验证码'))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'send is single-flight and a cooldown survives changing the email',
    (tester) async {
      final fake = await mount(tester), pending = Completer<void>();
      fake.sending = () => pending.future;
      await enterEmail(tester);
      expect(fake.sent, hasLength(1));
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '更换邮箱'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.text('更换邮箱'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.text('发送验证码'), findsOneWidget);
      fake.sending = null;
      await enterEmail(tester);
      expect(fake.sent, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'uncertain send allows entering a delivered code without exposing raw errors',
    (tester) async {
      final fake = await mount(tester);
      fake.sending = () async => throw TimeoutException('private data');
      await enterEmail(tester);
      expect(find.textContaining('尚未确认发送结果'), findsOneWidget);
      expect(find.textContaining('private data'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, '邮箱验证码'),
        '123456',
      );
      fake.verifying = () async =>
          throw const AuthException('private', code: 'otp_expired');
      await tester.tap(find.text('验证并登录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('验证码无效或已过期'), findsOneWidget);
      expect(fake.verified, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unmount invalidates pending verification and late errors cause no UI update',
    (tester) async {
      final fake = await mount(tester), pending = Completer<void>();
      fake.verifying = () => pending.future;
      await enterEmail(tester, existing: true);
      await tester.enterText(
        find.widgetWithText(TextFormField, '邮箱验证码'),
        '12345678',
      );
      await tester.tap(find.text('验证并登录'));
      await tester.pumpAndSettle();
      expect(fake.currentCheck!(), true);
      await tester.pumpWidget(const SizedBox());
      expect(fake.currentCheck!(), false);
      pending.completeError(StateError('private'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '360px double text and an open keyboard keep login controls scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fake = await mount(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, '家长邮箱'),
        'parent@example.test',
      );
      await tester.ensureVisible(find.text('已有验证码'));
      await tester.tap(find.text('已有验证码'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '邮箱验证码'),
        '12345678',
      );
      await tester.ensureVisible(find.text('验证并登录'));
      await tester.tap(find.text('验证并登录'));
      await tester.pumpAndSettle();
      expect(fake.verified, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

String normalizedLoginEmail(String email) => email.trim().toLowerCase();
bool validLoginEmail(String email) =>
    email.length <= 254 &&
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
bool validEmailOtp(String code) => RegExp(r'^\d{6,10}$').hasMatch(code);

/// Fixed user-facing messages: never surface Auth response bodies or tokens.
String emailOtpError(Object error, {required bool verifying}) {
  if (error is AuthException) {
    if (error.statusCode == '429' ||
        error.code == 'over_email_send_rate_limit' ||
        error.code == 'over_request_rate_limit') {
      return '操作太频繁，请稍后再试。';
    }
    if (error.code == 'otp_expired' || error.code == 'otp_disabled') {
      return '验证码无效或已过期，请检查邮件或重新发送。';
    }
  }
  if (error is EmailLoginChanged) return '登录状态已变化，请重新操作。';
  if (error is TimeoutException) {
    return verifying
        ? '验证超时，尚未在本机登录。请重试；若验证码已失效，请重新发送。'
        : '尚未确认发送结果，请先检查邮箱；收到验证码后可以继续登录。';
  }
  return verifying ? '未能完成登录，请检查验证码和网络后重试。' : '尚未确认发送结果，请检查邮箱和网络，稍后可重新发送。';
}

class EmailLoginChanged implements Exception {
  const EmailLoginChanged();
}

/// Each request has a disposable SDK client without session persistence, PKCE
/// storage or refresh timers. A late verify reply cannot log into the main SDK.
class EmailOtpTransport {
  EmailOtpTransport(this.createClient);
  final GoTrueClient Function() createClient;

  Future<T> _run<T>(Future<T> Function(GoTrueClient) action) async {
    final client = createClient();
    try {
      return await action(client);
    } finally {
      client.dispose();
    }
  }

  Future<void> send(String email) =>
      _run((client) => client.signInWithOtp(email: email));

  Future<Session> verify(String email, String code) => _run((client) async {
    final response = await client.verifyOTP(
      email: email,
      token: code,
      type: OtpType.email,
    );
    final session = response.session;
    if (session == null || session.refreshToken?.isNotEmpty != true) {
      throw const AuthException('No login session returned');
    }
    return session;
  });
}

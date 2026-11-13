import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/security/secure_auth_storage.dart';
import '../domain/auth_session.dart';
import 'email_otp.dart';

abstract interface class AuthRepository {
  AuthSession? get currentSession;

  Stream<AuthSession?> watchSession();

  Future<void> sendEmailOtp(String email);

  Future<void> verifyEmailOtp(
    String email,
    String code, {
    required bool Function() isCurrent,
  });

  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(
    this._client, {
    this.sessionStorage,
    this.beforeSignOut,
    this.revocationWait = const Duration(seconds: 3),
    this.emailOtp,
    this.loginWait = const Duration(seconds: 20),
  }) {
    _sessionChanges = _client.auth.onAuthStateChange.listen((state) {
      if (state.event != AuthChangeEvent.initialSession) _loginRevision++;
    }, onError: (Object _) {});
  }

  final SupabaseClient _client;
  final SecureSessionStorage? sessionStorage;
  final Future<void> Function()? beforeSignOut;
  final Duration revocationWait;
  final EmailOtpTransport? emailOtp;
  final Duration loginWait;
  late final StreamSubscription<AuthState> _sessionChanges;
  int _loginRevision = 0;
  bool _loginBusy = false, _disposed = false;
  final _localChanges = StreamController<void>.broadcast();
  Future<void>? _signingOut;

  @override
  AuthSession? get currentSession => _mapSession(_client.auth.currentSession);

  @override
  Stream<AuthSession?> watchSession() => Stream.multi((sink) {
    sink.add(currentSession);
    final sdk = _client.auth.onAuthStateChange.listen(
      (state) => sink.add(_mapSession(state.session)),
      onError: sink.addError,
    );
    // The SDK removes its in-memory session before deleting PKCE storage. If
    // that redundant delete fails, it may not emit signedOut; our preflight
    // already committed both tombstones, so still close protected routes.
    final local = _localChanges.stream.listen((_) => sink.add(currentSession));
    sink.onCancel = () {
      unawaited(sdk.cancel());
      unawaited(local.cancel());
    };
  });

  @override
  Future<void> sendEmailOtp(String email) => _login((transport, check) async {
    email = normalizedLoginEmail(email);
    if (!validLoginEmail(email)) throw const FormatException('Invalid email');
    await transport.send(email).timeout(loginWait);
    check();
  });

  @override
  Future<void> verifyEmailOtp(
    String email,
    String code, {
    required bool Function() isCurrent,
  }) => _login((transport, check) async {
    email = normalizedLoginEmail(email);
    code = code.trim();
    if (!validLoginEmail(email) || !validEmailOtp(code)) {
      throw const FormatException('Invalid email or code');
    }
    if (!isCurrent()) throw const EmailLoginChanged();
    final session = await transport.verify(email, code).timeout(loginWait);
    check();
    if (!isCurrent()) throw const EmailLoginChanged();
    // recoverSession restores a fresh session synchronously before returning its
    // Future in the pinned SDK. Reject old replies instead of refreshing them:
    // refreshing here would introduce another unguarded network commit.
    if (session.isExpired ||
        session.expiresAt == null ||
        session.expiresAt! <=
            DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60 ||
        normalizedLoginEmail(session.user.email ?? '') != email) {
      throw const AuthException('Login session is unavailable');
    }
    await _client.auth.recoverSession(jsonEncode(session.toJson()));
  });

  Future<void> _login(
    Future<void> Function(EmailOtpTransport, void Function()) action,
  ) async {
    if (_disposed ||
        _loginBusy ||
        _signingOut != null ||
        currentSession != null) {
      throw const EmailLoginChanged();
    }
    final transport = emailOtp;
    if (transport == null) throw const AuthException('Email login unavailable');
    final revision = _loginRevision;
    void check() {
      if (_disposed || revision != _loginRevision || currentSession != null) {
        throw const EmailLoginChanged();
      }
    }

    _loginBusy = true;
    try {
      await action(transport, check);
    } finally {
      _loginBusy = false;
    }
  }

  @override
  Future<void> signOut() =>
      _signingOut ??= _signOut().whenComplete(() => _signingOut = null);

  Future<void> _signOut() async {
    _loginRevision++;
    final original = _client.auth.currentSession?.accessToken;
    bool sameSession() => _client.auth.currentSession?.accessToken == original;
    void check() {
      if (!sameSession()) throw StateError('登录状态已变化，请重新操作。');
    }

    sessionStorage?.suspendPersistence();
    try {
      await beforeSignOut?.call();
      check();
      if (original != null) {
        try {
          await _client
              .rpc<void>('revoke_parent_authorization')
              .timeout(revocationWait);
        } catch (_) {
          // Offline logout must not depend on a parent-grant RPC. Never save an
          // old JWT for later retry; the server grant has its own short expiry.
        }
      }
      check();
      await sessionStorage?.clearForSignOut(isCurrent: sameSession);
      check();
      final removed = Completer<void>();
      final subscription = _client.auth.onAuthStateChange.listen((state) {
        if (state.event == AuthChangeEvent.signedOut &&
            _client.auth.currentSession == null &&
            !removed.isCompleted) {
          removed.complete();
        }
      }, onError: (Object _) {});
      try {
        // Wait for the local transition, not an unreachable auth server. Any
        // later HTTP failure remains observed by Future.any and cannot clear
        // another login's persistence.
        await Future.any<void>([
          removed.future,
          _client.auth
              .signOut(scope: SignOutScope.local)
              .timeout(revocationWait),
        ]);
      } catch (_) {
        if (_client.auth.currentSession != null) rethrow;
      } finally {
        // cancel immediately stops delivery. Stream cleanup is independent of
        // the completed local logout and must not hold the UI barrier open.
        unawaited(subscription.cancel().catchError((Object _) {}));
      }
      if (_client.auth.currentSession == null) _localChanges.add(null);
    } finally {
      final current = _client.auth.currentSession;
      await sessionStorage?.resumePersistence(
        current == null ? null : jsonEncode(current.toJson()),
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _loginRevision++;
    unawaited(_sessionChanges.cancel());
    await _localChanges.close();
  }

  static AuthSession? _mapSession(Session? session) {
    final user = session?.user;
    if (user == null) return null;
    return AuthSession(userId: user.id, email: user.email);
  }
}

class UnconfiguredAuthRepository implements AuthRepository {
  const UnconfiguredAuthRepository();

  @override
  AuthSession? get currentSession => null;

  @override
  Stream<AuthSession?> watchSession() => Stream.value(null);

  @override
  Future<void> sendEmailOtp(String email) =>
      Future<void>.error(StateError('开发环境尚未配置 Supabase。'));

  @override
  Future<void> verifyEmailOtp(
    String email,
    String code, {
    required bool Function() isCurrent,
  }) => Future<void>.error(StateError('开发环境尚未配置 Supabase。'));

  @override
  Future<void> signOut() async {}
}

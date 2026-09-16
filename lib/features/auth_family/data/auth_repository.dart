import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/auth_session.dart';

abstract interface class AuthRepository {
  AuthSession? get currentSession;

  Stream<AuthSession?> watchSession();

  Future<void> sendEmailOtp(String email);

  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  AuthSession? get currentSession => _mapSession(_client.auth.currentSession);

  @override
  Stream<AuthSession?> watchSession() async* {
    yield currentSession;
    yield* _client.auth.onAuthStateChange.map(
      (state) => _mapSession(state.session),
    );
  }

  @override
  Future<void> sendEmailOtp(String email) => _client.auth.signInWithOtp(
    email: email,
    emailRedirectTo: 'io.learningplanet.app://login-callback',
  );

  @override
  Future<void> signOut() => _client.auth.signOut();

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
  Future<void> signOut() async {}
}

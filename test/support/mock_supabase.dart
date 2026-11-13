import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Real SDK transport; Auth, PostgREST, Edge and Storage are entirely local mocks.
class MockSupabase {
  MockSupabase({GotrueAsyncStorage? pkceStorage}) {
    client = SupabaseClient(
      'https://project.supabase.co',
      'public',
      authOptions: AuthClientOptions(pkceAsyncStorage: pkceStorage),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return json(request, {
            'access_token':
                'header.${base64UrlEncode(utf8.encode(jsonEncode({'sub': _nextUser, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})))}.signature',
            'refresh_token': 'local-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': _nextUser,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'parent@example.test',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-11-04T00:00:00Z',
            },
          });
        }
        if (request.url.path.endsWith('/logout')) {
          logoutCalls.add(request);
          return logout == null ? json(request, {}) : await logout!(request);
        }
        calls.add(request);
        return handle(request);
      }),
    );
  }
  static const firstUser = '10000000-0000-0000-0000-000000000001';
  static const secondUser = '10000000-0000-0000-0000-000000000002';
  String _nextUser = firstUser;
  late final SupabaseClient client;
  final List<http.Request> calls = [];
  final List<http.Request> logoutCalls = [];
  FutureOr<http.Response> Function(http.Request)? logout;
  FutureOr<http.Response> Function(http.Request) handle = (request) =>
      json(request, null);
  Future<void> signIn([String user = firstUser]) async {
    _nextUser = user;
    await client.auth.signInWithPassword(
      email: 'parent@example.test',
      password: 'mock-only',
    );
  }

  static Map<String, dynamic> body(http.Request request) => request.body.isEmpty
      ? {}
      : jsonDecode(request.body) as Map<String, dynamic>;
  static http.Response json(
    http.Request request,
    Object? data, {
    int status = 200,
  }) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': 'application/json'},
    request: request,
  );
  static http.Response denied(http.Request request) => json(request, {
    'code': '42501',
    'message': 'permission denied',
  }, status: 403);
  Future<void> close() => client.dispose();
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_secrets.dart';

/// Session and PKCE persistence share a serial queue. A logged-out tombstone
/// wins over an old preference left behind by an interrupted cleanup.
class SecureAuthValues {
  SecureAuthValues({required this.secrets, required String backendUrl})
    : project = Uri.parse(backendUrl).host.split('.').first;
  final DeviceSecrets secrets;
  final String project;
  String get sessionKey => 'sb-$project-auth-token';
  static const pkceKey = 'supabase.auth.token-code-verifier';
  Future<void> _queue = Future.value();

  String _key(String key) => 'learning_planet.auth.v1.$project.$key';
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String?> _migrate(String key) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      var encoded = await secrets.read(_key(key));
      if (encoded == null) {
        final legacy = preferences.getString(key);
        encoded = jsonEncode({'value': legacy});
        await secrets.write(_key(key), encoded);
        if (await secrets.read(_key(key)) != encoded) {
          throw const LocalDataException('登录信息未能安全保存，请重试。');
        }
      }
      final envelope = jsonDecode(encoded) as Map<String, dynamic>;
      if (!envelope.containsKey('value') ||
          (envelope['value'] != null && envelope['value'] is! String)) {
        throw const FormatException();
      }
      if (preferences.containsKey(key) && !await preferences.remove(key)) {
        throw const LocalDataException('旧登录信息清理未完成，请重试。');
      }
      return envelope['value'] as String?;
    } on LocalDataException {
      rethrow;
    } catch (_) {
      throw const LocalDataException('无法读取本机登录信息，请解锁设备后重试。');
    }
  }

  Future<void> initialize() => _serialize(() async {
    await _migrate(sessionKey);
    await _migrate(pkceKey);
  });

  Future<String?> read(String key) => _serialize(() => _migrate(key));

  Future<void> write(
    String key,
    String? value, {
    bool Function()? shouldWrite,
  }) => _serialize(() async {
    if (shouldWrite != null && !shouldWrite()) return;
    // Commit the new value (including sign-out) before attempting legacy
    // cleanup; an old token must not win on retry or restart.
    final encoded = jsonEncode({'value': value});
    await secrets.write(_key(key), encoded);
    if (await secrets.read(_key(key)) != encoded) {
      throw const LocalDataException('登录信息未能安全保存，请重试。');
    }
    await _migrate(key);
  });
}

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.values, {this.isCurrentSession});
  final SecureAuthValues values;
  final bool Function(String session)? isCurrentSession;
  int _persistenceVersion = 0;
  bool _suspended = false;

  /// Fence queued auth events before committing logout. An in-flight write
  /// precedes the tombstone on [SecureAuthValues]' serial queue; later events
  /// cannot restore it while the SDK still holds the old session in memory.
  void suspendPersistence() {
    _suspended = true;
    _persistenceVersion++;
  }

  Future<void> resumePersistence(String? currentSession) async {
    _suspended = false;
    _persistenceVersion++;
    if (currentSession != null) await persistSession(currentSession);
  }

  Future<void> clearForSignOut({required bool Function() isCurrent}) async {
    await values.write(SecureAuthValues.pkceKey, null, shouldWrite: isCurrent);
    await values.write(values.sessionKey, null, shouldWrite: isCurrent);
  }

  @override
  Future<void> initialize() => values.initialize();
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<String?> accessToken() => values.read(values.sessionKey);
  @override
  Future<void> persistSession(String persistSessionString) {
    final version = _persistenceVersion;
    return values.write(
      values.sessionKey,
      persistSessionString,
      shouldWrite: () =>
          !_suspended &&
          version == _persistenceVersion &&
          (isCurrentSession?.call(persistSessionString) ?? true),
    );
  }

  @override
  Future<void> removePersistedSession() =>
      values.write(values.sessionKey, null);
}

class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage(this.values);
  final SecureAuthValues values;
  @override
  Future<String?> getItem({required String key}) => values.read(key);
  @override
  Future<void> setItem({required String key, required String value}) =>
      values.write(key, value);
  @override
  Future<void> removeItem({required String key}) => values.write(key, null);
}

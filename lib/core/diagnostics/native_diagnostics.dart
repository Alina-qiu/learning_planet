import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../offline/offline_store.dart';
import 'runtime_diagnostics.dart';

abstract interface class NativeDiagnosticBridge {
  Future<List<Map<String, dynamic>>> read(String? scope);
  Future<void> acknowledge(String scope, List<String> ids);
}

class MethodChannelNativeDiagnostics implements NativeDiagnosticBridge {
  const MethodChannelNativeDiagnostics();
  static const channel = MethodChannel('learning_planet/native_diagnostics');
  @override
  Future<List<Map<String, dynamic>>> read(String? scope) async {
    final result = await channel.invokeMethod<Object?>('read', {
      'scope': scope,
    });
    if (result is! List || result.length > 50) throw const FormatException();
    return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  @override
  Future<void> acknowledge(String scope, List<String> ids) =>
      channel.invokeMethod<void>('ack', {'scope': scope, 'ids': ids});
}

/// Native storage knows only an opaque scope. Its account mapping stays in the
/// encrypted database and is erased by the existing account deletion barrier.
class NativeDiagnostics {
  NativeDiagnostics({
    required this.store,
    required this.owner,
    required this.diagnostics,
    this.bridge = const MethodChannelNativeDiagnostics(),
  });
  static const scopeKey = 'native-diagnostics-scope-v1';
  final OfflineStore store;
  final String? Function() owner;
  final RuntimeDiagnostics diagnostics;
  final NativeDiagnosticBridge bridge;
  Future<void> _tail = Future.value();
  int _revision = 0;
  bool _disposed = false;

  Future<void> synchronize() {
    final revision = ++_revision,
        account = owner(),
        privacy = store.privacyGeneration;
    final diagnosticScope = diagnostics.capture();
    bool current() =>
        !_disposed &&
        revision == _revision &&
        account == owner() &&
        privacy == store.privacyGeneration;
    final work = _tail.then((_) async {
      if (!current()) return;
      String? scope;
      if (account != null) {
        scope = await store.transaction(() async {
          if (!current()) return null;
          if (await store.accountDeletionJob(account) != null) return null;
          final cached = (await store.read(account, scopeKey))?['scope'];
          if (!current()) return null;
          if (cached is String &&
              cached == cached.toLowerCase() &&
              Uuid.isValidUUID(fromString: cached)) {
            return cached;
          }
          final created = const Uuid().v4();
          await store.write(account, scopeKey, {'scope': created});
          return created;
        });
      }
      if (!current()) return;
      final events = await bridge
          .read(scope)
          .timeout(const Duration(seconds: 5));
      if (!current() || scope == null || events.isEmpty) return;
      final accepted = await diagnostics.ingestNative(events, diagnosticScope);
      if (!current() || accepted.isEmpty) return;
      await bridge
          .acknowledge(scope, accepted)
          .timeout(const Duration(seconds: 5));
    });
    _tail = work.catchError((Object _) {
      /* No native exception text in logs. */
    });
    return _tail;
  }

  Future<void> dispose() async {
    _disposed = true;
    _revision++;
    await _tail;
  }
}

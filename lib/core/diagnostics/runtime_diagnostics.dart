import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../offline/network_failure.dart';
import '../offline/offline_store.dart';

enum DiagnosticOperation {
  auth,
  database,
  storage,
  edge,
  tasks,
  reviews,
  images,
  framework,
  async,
  startup,
  androidJavaCrash,
  androidNativeCrash,
  androidAnr,
  iosCrash,
  iosHang;

  String get kind => switch (this) {
    auth || database || storage || edge => 'api',
    tasks || reviews || images => 'sync',
    framework || async || startup => 'runtime',
    androidJavaCrash ||
    androidNativeCrash ||
    androidAnr ||
    iosCrash ||
    iosHang => 'native',
  };
}

enum DiagnosticOutcome {
  ok('ok'),
  clientError('client_error'),
  serverError('server_error'),
  network('network'),
  timeout('timeout'),
  cancelled('cancelled'),
  conflict('conflict'),
  authorization('authorization'),
  unexpected('unexpected');

  const DiagnosticOutcome(this.wire);
  final String wire;
}

String diagnosticErrorCode(Object? error) => switch (error) {
  null => 'none',
  StateError() => 'state',
  FormatException() => 'format',
  TypeError() => 'type',
  RangeError() => 'range',
  UnsupportedError() => 'unsupported',
  _ => 'unknown',
};

DiagnosticOutcome diagnosticFailure(Object error) => error is TimeoutException
    ? DiagnosticOutcome.timeout
    : isNetworkFailure(error)
    ? DiagnosticOutcome.network
    : DiagnosticOutcome.unexpected;

int diagnosticLatencyBucket(Duration elapsed) {
  final ms = elapsed.inMilliseconds;
  for (final (index, upper) in [100, 500, 1500, 3000, 10000, 30000].indexed) {
    if (ms < upper) return index;
  }
  return 6;
}

class DiagnosticScope {
  const DiagnosticScope._(this.owner, this.generation, this.privacyGeneration);
  final String? owner;
  final int generation, privacyGeneration;
}

typedef DiagnosticSender =
    Future<Map<String, dynamic>> Function(List<Map<String, dynamic>> events);

/// Bounded, account-scoped, best-effort diagnostics. Never accepts message text,
/// URLs, stack traces, child IDs, request bodies, JWTs or model output.
class RuntimeDiagnostics {
  RuntimeDiagnostics({DateTime Function()? clock, void Function(String)? log})
    : clock = clock ?? DateTime.now,
      log = log ?? debugPrint;
  static const cacheKey = 'runtime-diagnostics-v1';
  static const capacity = 250;
  final DateTime Function() clock;
  final void Function(String) log;
  OfflineStore? _store;
  String? Function() _owner = () => null;
  DiagnosticSender? _send;
  Future<void> Function()? _collectNative;
  String? _lastOwner;
  int _generation = 0, _failures = 0;
  int _pendingWrites = 0;
  DateTime? _nextUpload;
  Timer? _timer;
  bool _foreground = true;
  Future<void> _tail = Future.value();
  Future<void>? _upload;

  DiagnosticScope capture() =>
      DiagnosticScope._(_owner(), _generation, _store?.privacyGeneration ?? 0);
  bool _current(DiagnosticScope scope) =>
      scope.owner != null &&
      scope.owner == _owner() &&
      scope.generation == _generation &&
      scope.privacyGeneration == _store?.privacyGeneration;

  void attach({
    required OfflineStore store,
    required String? Function() owner,
    required DiagnosticSender send,
    bool automatic = true,
    Future<void> Function()? collectNative,
  }) {
    detach();
    _store = store;
    _owner = owner;
    _send = send;
    _collectNative = collectNative;
    _lastOwner = owner();
    if (automatic) {
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(flush()),
      );
    }
  }

  void detach() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _store = null;
    _owner = () => null;
    _send = null;
    _collectNative = null;
    _lastOwner = null;
    _failures = 0;
    _nextUpload = null;
  }

  void scopeChanged() {
    if (_lastOwner == _owner()) return;
    _lastOwner = _owner();
    _generation++;
    _failures = 0;
    _nextUpload = null;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) unawaited(flush());
  }

  Future<void> get settled => _tail;
  void _log(String message) {
    try {
      log(message);
    } catch (_) {
      /* Reporting is never a crash source. */
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    // Diagnostics must not break business operations or recursively report itself.
    _tail = result.catchError((Object _) {
      _log('runtime_diagnostics: local_store_unavailable');
    });
    return _tail;
  }

  List<Map<String, dynamic>> _retained(Map<String, dynamic>? data) {
    final today = clock().toUtc();
    final first = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(days: 7));
    final lastDay = today.toIso8601String().substring(0, 10);
    final source = data?['events'];
    if (source is! List) return [];
    final rows = <String, Map<String, dynamic>>{};
    for (final row in source) {
      if (row is! Map || !_validEvent(row)) continue;
      final day = row['day'] as String;
      final date = DateTime.tryParse('${day}T00:00:00Z');
      if (date == null ||
          date.toIso8601String().substring(0, 10) != day ||
          date.isBefore(first) ||
          day.compareTo(lastDay) > 0) {
        continue;
      }
      rows.putIfAbsent(
        row['event_id'] as String,
        () => Map<String, dynamic>.from(row),
      );
    }
    return rows.values.skip(max(0, rows.length - capacity)).toList();
  }

  bool _validEvent(Map row) =>
      row.length == 7 &&
      row.keys.toSet().containsAll({
        'event_id',
        'day',
        'kind',
        'operation',
        'outcome',
        'error',
        'bucket',
      }) &&
      row['event_id'] is String &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      ).hasMatch(row['event_id'] as String) &&
      row['day'] is String &&
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(row['day'] as String) &&
      row['bucket'] is int &&
      (row['bucket'] as int) >= 0 &&
      (row['bucket'] as int) <= 6 &&
      DiagnosticOperation.values.any(
        (op) => op.name == row['operation'] && op.kind == row['kind'],
      ) &&
      DiagnosticOutcome.values.any((value) => value.wire == row['outcome']) &&
      const {
        'none',
        'state',
        'format',
        'type',
        'range',
        'unsupported',
        'unknown',
      }.contains(row['error']) &&
      (!const {'runtime', 'native'}.contains(row['kind']) ||
          (row['bucket'] == 0 && row['outcome'] == 'unexpected')) &&
      (row['kind'] != 'native' || row['error'] == 'none');

  /// Acknowledges only after the encrypted transaction commits. Stable native
  /// IDs survive a lost acknowledgement and reuse the server replay guard.
  Future<List<String>> ingestNative(
    List<Map<String, dynamic>> source,
    DiagnosticScope token,
  ) async {
    final store = _store;
    if (store == null || !_current(token) || source.length > 50) return [];
    final events = <Map<String, dynamic>>[];
    for (final row in source) {
      if (row.length != 3 ||
          !row.keys.toSet().containsAll({'event_id', 'day', 'operation'})) {
        return [];
      }
      final event = <String, dynamic>{
        ...row,
        'kind': 'native',
        'outcome': 'unexpected',
        'error': 'none',
        'bucket': 0,
      };
      if (!_validEvent(event) ||
          _retained({
            'events': [event],
          }).isEmpty) {
        return [];
      }
      events.add(event);
    }
    if (events.map((e) => e['event_id']).toSet().length != events.length) {
      return [];
    }
    var accepted = <String>[];
    await _serialize(() async {
      final ids = await store.transaction(() async {
        if (!_current(token)) return <String>[];
        final rows = _retained(await store.read(token.owner!, cacheKey));
        if (!_current(token)) return <String>[];
        final byId = {for (final row in rows) row['event_id']: row};
        for (final event in events) {
          final previous = byId[event['event_id']];
          if (previous != null && !mapEquals(previous, event)) {
            return <String>[];
          }
          byId.remove(event['event_id']);
          byId[event['event_id']] = event;
        }
        await store.write(token.owner!, cacheKey, {
          'events': byId.values.skip(max(0, byId.length - capacity)).toList(),
        });
        return events.map((e) => e['event_id'] as String).toList();
      });
      if (_current(token)) accepted = ids;
    });
    return accepted;
  }

  void record(
    DiagnosticOperation operation, {
    DiagnosticOutcome outcome = DiagnosticOutcome.ok,
    Duration elapsed = Duration.zero,
    Object? error,
    DiagnosticScope? scope,
  }) {
    final token = scope ?? capture(), store = _store;
    final code = diagnosticErrorCode(error);
    if (operation.kind == 'native') return; // Only the validated native import.
    if (operation.kind == 'runtime') {
      outcome = DiagnosticOutcome.unexpected;
      // Also leaves a redacted system log when startup fails before sign-in.
      _log('runtime_diagnostics: ${operation.name}/unexpected/$code');
    }
    if (store == null || !_current(token) || _pendingWrites >= capacity) return;
    _pendingWrites++;
    final event = <String, dynamic>{
      'event_id': const Uuid().v4(),
      'day': clock().toUtc().toIso8601String().substring(0, 10),
      'kind': operation.kind,
      'operation': operation.name,
      'outcome': outcome.wire,
      'error': code,
      'bucket': operation.kind == 'runtime'
          ? 0
          : diagnosticLatencyBucket(elapsed),
    };
    unawaited(
      _serialize(
        () => store.transaction(() async {
          if (!_current(token)) return;
          final rows = _retained(await store.read(token.owner!, cacheKey));
          if (!_current(token)) return;
          rows.add(event);
          await store.write(token.owner!, cacheKey, {
            'events': rows.skip(max(0, rows.length - capacity)).toList(),
          });
        }),
      ).whenComplete(() => _pendingWrites--),
    );
  }

  Future<void> flush() {
    if (_upload case final running?) return running;
    final token = capture(), store = _store, send = _send;
    if (!_foreground ||
        store == null ||
        send == null ||
        !_current(token) ||
        (_nextUpload?.isAfter(clock()) ?? false)) {
      return Future.value();
    }
    final work = _flush(token, store, send).whenComplete(() => _upload = null);
    _upload = work;
    return work;
  }

  Future<void> _flush(
    DiagnosticScope token,
    OfflineStore store,
    DiagnosticSender send,
  ) async {
    try {
      try {
        await _collectNative?.call();
      } catch (_) {
        /* Best effort only. */
      }
      if (!_current(token)) return;
      List<Map<String, dynamic>> batch = [];
      await _serialize(
        () => store.transaction(() async {
          if (!_current(token)) return;
          final rows = _retained(await store.read(token.owner!, cacheKey));
          if (!_current(token)) return;
          await store.write(token.owner!, cacheKey, {'events': rows});
          batch = List<Map<String, dynamic>>.unmodifiable(
            rows.take(50).map((row) => Map<String, dynamic>.unmodifiable(row)),
          );
        }),
      );
      if (batch.isEmpty || !_current(token) || !_foreground) return;
      final receipt = await send(batch).timeout(const Duration(seconds: 10));
      if (!_current(token)) return;
      final ids = batch.map((e) => e['event_id'] as String).toSet();
      final acknowledged = receipt['event_ids'];
      if (acknowledged is! List ||
          acknowledged.length != ids.length ||
          acknowledged.toSet().length != ids.length ||
          !acknowledged.every(ids.contains)) {
        throw StateError('诊断回执不匹配');
      }
      await _serialize(
        () => store.transaction(() async {
          if (!_current(token)) return;
          final rows = _retained(await store.read(token.owner!, cacheKey));
          if (!_current(token)) return;
          await store.write(token.owner!, cacheKey, {
            'events': rows.where((e) => !ids.contains(e['event_id'])).toList(),
          });
        }),
      );
      _failures = 0;
      _nextUpload = null;
    } catch (_) {
      if (!_current(token)) return;
      _failures++;
      _nextUpload = clock().add(
        Duration(seconds: min(300, 30 * (1 << min(_failures - 1, 4)))),
      );
    }
  }

  Future<void> dispose() async {
    detach();
    await _tail;
    await _upload;
  }
}

final runtimeDiagnostics = RuntimeDiagnostics();

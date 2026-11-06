import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/offline_store.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../domain/configuration_session.dart';

typedef ConfigurationSender =
    Future<Map<String, dynamic>> Function(List<Map<String, dynamic>> events);

final configurationTimeRecorderProvider = Provider<ConfigurationTimeRecorder?>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  if (tasks is! OfflineTaskRepository || tasks.client == null) return null;
  final client = tasks.client!;
  final recorder = ConfigurationTimeRecorder(
    store: tasks.store,
    owner: () => client.auth.currentUser?.id,
    send: (events) => client.rpc<Map<String, dynamic>>(
      'record_parent_configuration',
      params: {'events': events},
    ),
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

class ConfigurationRecordingScope {
  const ConfigurationRecordingScope._(
    this.owner,
    this.privacy,
    this.child,
    this.family,
    this.kind,
  );
  final String? owner;
  final int privacy;
  final String child, family;
  final ConfigurationKind kind;
}

class ConfigurationTimeRecorder {
  ConfigurationTimeRecorder({
    required this.store,
    required this.owner,
    required this.send,
    DateTime Function()? clock,
    Duration Function()? elapsed,
  }) : clock = clock ?? DateTime.now,
       _elapsedOverride = elapsed;
  static const cacheKey = 'configuration-time-v1', capacity = 1000;
  final OfflineStore store;
  final String? Function() owner;
  final ConfigurationSender send;
  final DateTime Function() clock;
  final Duration Function()? _elapsedOverride;
  final Stopwatch _watch = Stopwatch()..start();
  Future<void> _tail = Future.value();
  Future<void>? _flight;
  String? _clockOwner;
  DateTime? _serverAt, _retryAt;
  Duration _serverTick = Duration.zero;
  int _failures = 0;
  bool _disposed = false, _foreground = true;
  Duration get _elapsed => _elapsedOverride?.call() ?? _watch.elapsed;
  DateTime get now {
    if (_clockOwner != owner()) {
      _clockOwner = owner();
      _serverAt = null;
      _retryAt = null;
      _failures = 0;
    }
    return _serverAt?.add(_elapsed - _serverTick) ?? clock().toUtc();
  }

  void dispose() => _disposed = true;
  void setForeground(bool value) {
    _foreground = value;
    if (value) unawaited(flush());
  }

  ConfigurationRecordingScope capture(
    String child,
    String family,
    ConfigurationKind kind,
  ) => ConfigurationRecordingScope._(
    owner(),
    store.privacyGeneration,
    child,
    family,
    kind,
  );
  bool _current(String? actor, int privacy) =>
      !_disposed &&
      actor != null &&
      actor == owner() &&
      privacy == store.privacyGeneration;
  Future<void> _serialize(Future<void> Function() operation) {
    _tail = _tail.then((_) => operation()).catchError((Object _) {});
    return _tail;
  }

  List<Map<String, dynamic>> _retained(Map<String, dynamic>? cached) {
    final current = now;
    final source = cached?['events'];
    if (source is! List) return [];
    final events = <String, Map<String, dynamic>>{};
    for (final item in source) {
      if (item is! Map ||
          item.length != 6 ||
          !const [
            'event_id',
            'child_id',
            'family_id',
            'kind',
            'started_at',
            'ended_at',
          ].every((key) => item[key] is String) ||
          !const ['task', 'rules'].contains(item['kind'])) {
        continue;
      }
      final first = DateTime.tryParse(item['started_at'] as String),
          last = DateTime.tryParse(item['ended_at'] as String);
      // A response's server time can precede intervals queued during its RTT.
      // Preserve those pending rows; the server validates future timestamps.
      if (first == null ||
          last == null ||
          !last.isAfter(first) ||
          last.difference(first) > const Duration(seconds: 30) ||
          first.isBefore(current.subtract(const Duration(days: 7))) ||
          last.isAfter(current.add(const Duration(seconds: 30)))) {
        continue;
      }
      events.putIfAbsent(
        item['event_id'] as String,
        () => Map<String, dynamic>.from(item),
      );
    }
    return events.values
        .skip(events.length > capacity ? events.length - capacity : 0)
        .toList();
  }

  Future<void> record(
    ConfigurationRecordingScope scope,
    DateTime start,
    DateTime end,
  ) async {
    if (!_current(scope.owner, scope.privacy) ||
        !end.isAfter(start) ||
        end.difference(start) > const Duration(seconds: 30)) {
      return;
    }
    await _serialize(
      () => store.transaction(() async {
        if (!_current(scope.owner, scope.privacy) ||
            await store.isChildDeleted(scope.child)) {
          return;
        }
        final events = _retained(await store.read(scope.owner!, cacheKey));
        events.add({
          'event_id': const Uuid().v4(),
          'child_id': scope.child,
          'family_id': scope.family,
          'kind': scope.kind.name,
          'started_at': start.toUtc().toIso8601String(),
          'ended_at': end.toUtc().toIso8601String(),
        });
        if (!_current(scope.owner, scope.privacy)) return;
        await store.write(scope.owner!, cacheKey, {
          'events': events
              .skip(events.length > capacity ? events.length - capacity : 0)
              .toList(),
        });
      }),
    );
    await flush();
  }

  Future<void> flush() {
    if (_flight != null) return _flight!;
    final result = _upload().catchError((Object _) {});
    _flight = result.whenComplete(() => _flight = null);
    return _flight!;
  }

  Future<void> _upload() async {
    final actor = owner(), privacy = store.privacyGeneration;
    final current = now;
    if (!_foreground ||
        !_current(actor, privacy) ||
        (_retryAt?.isAfter(current) ?? false)) {
      return;
    }
    var batch = <Map<String, dynamic>>[];
    await _serialize(
      () => store.transaction(() async {
        if (!_current(actor, privacy)) return;
        final events = _retained(await store.read(actor!, cacheKey));
        if (!_current(actor, privacy)) return;
        if (events.isEmpty) {
          await store.remove(actor, cacheKey);
          return;
        }
        await store.write(actor, cacheKey, {'events': events});
        batch = events
            .take(50)
            .map((e) => Map<String, dynamic>.unmodifiable(e))
            .toList();
      }),
    );
    if (batch.isEmpty || !_foreground || !_current(actor, privacy)) return;
    try {
      final sentAt = _elapsed;
      final response = await send(
        List.unmodifiable(batch),
      ).timeout(const Duration(seconds: 10));
      if (!_current(actor, privacy)) return;
      final ids = batch.map((e) => e['event_id']).toList(),
          ack = response['event_ids'];
      final server = DateTime.tryParse(
        response['server_time'] as String? ?? '',
      );
      final accepted = response['accepted'];
      if (ack is! List ||
          ack.length != ids.length ||
          !List.generate(ids.length, (i) => ids[i] == ack[i]).every((v) => v) ||
          server == null ||
          accepted is! int ||
          accepted < 0 ||
          accepted > ids.length) {
        throw const FormatException('配置计时回执不匹配');
      }
      // A suspended app can receive an old response before its timeout callback.
      // Such a receipt may acknowledge its batch but cannot move the clock back.
      if (_elapsed - sentAt <= const Duration(seconds: 10)) {
        _serverAt = server.toUtc();
        _serverTick = _elapsed;
      }
      await _serialize(
        () => store.transaction(() async {
          if (!_current(actor, privacy)) return;
          final remaining = _retained(
            await store.read(actor!, cacheKey),
          ).where((e) => !ids.contains(e['event_id'])).toList();
          if (!_current(actor, privacy)) return;
          if (remaining.isEmpty) {
            await store.remove(actor, cacheKey);
          } else {
            await store.write(actor, cacheKey, {'events': remaining});
          }
        }),
      );
      _retryAt = null;
      _failures = 0;
    } catch (_) {
      if (!_current(actor, privacy)) return;
      _failures++;
      _retryAt = now.add(
        Duration(seconds: _failures < 5 ? _failures * 30 : 300),
      );
    }
  }
}

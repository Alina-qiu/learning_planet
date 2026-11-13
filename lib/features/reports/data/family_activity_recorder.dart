import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../../core/offline/offline_store.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

typedef FamilyActivitySender =
    Future<Map<String, dynamic>> Function(String family, List<String> moments);

final familyActivityRecorderProvider = Provider<FamilyActivityRecorder?>((ref) {
  final repository = ref.watch(taskRepositoryProvider);
  if (repository is! OfflineTaskRepository || repository.client == null) {
    return null;
  }
  final client = repository.client!;
  final recorder = FamilyActivityRecorder(
    store: repository.store,
    owner: () => client.auth.currentUser?.id,
    send: (family, moments) => client.rpc<Map<String, dynamic>>(
      'record_family_activity',
      params: {'target_family_id': family, 'moments': moments},
    ),
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

/// A foreground observation, not a task completion or a background sync event.
/// The encrypted outbox retains at most one sample per family day for seven days.
class FamilyActivityRecorder {
  FamilyActivityRecorder({
    required this.store,
    required this.owner,
    required this.send,
    DateTime Function()? clock,
    Duration Function()? elapsed,
  }) : clock = clock ?? DateTime.now,
       _elapsedOverride = elapsed {
    tz_data.initializeTimeZones();
  }
  final OfflineStore store;
  final String? Function() owner;
  final FamilyActivitySender send;
  final DateTime Function() clock;
  final Duration Function()? _elapsedOverride;
  final Stopwatch _watch = Stopwatch()..start();
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  Future<void> _tail = Future.value();
  String? _clockOwner;
  DateTime? _serverAt;
  Duration _serverTick = Duration.zero;
  bool _disposed = false;
  void dispose() => _disposed = true;
  Duration get _elapsed => _elapsedOverride?.call() ?? _watch.elapsed;
  DateTime get _now => _serverAt == null
      ? clock().toUtc()
      : _serverAt!.add(_elapsed - _serverTick);
  static String key(String family) => 'family-activity:$family';

  Future<void> observe(
    String family,
    String timezone, {
    required bool Function() isCurrent,
  }) {
    final account = owner(), generation = store.privacyGeneration;
    bool current() =>
        !_disposed &&
        account != null &&
        owner() == account &&
        generation == store.privacyGeneration &&
        isCurrent();
    final action = _tail.then((_) async {
      if (!current()) return;
      if (_clockOwner != account) {
        _clockOwner = account;
        _serverAt = null;
        _retryAt.clear();
        _failures.clear();
      }
      final cacheKey = key(family), retryKey = '$account/$family';
      final cache = await store.read(account!, cacheKey) ?? {};
      if (!current() || cache['complete'] == true) return;
      final now = _now;
      final zone = tz.getLocation(
        cache['cohort_timezone'] as String? ?? timezone,
      );
      final day = tz.TZDateTime.from(
        now,
        zone,
      ).toIso8601String().substring(0, 10);
      final samples = (cache['samples'] as List? ?? [])
          .whereType<String>()
          .where((s) {
            final at = DateTime.tryParse(s);
            return at != null &&
                !at.isBefore(now.subtract(const Duration(days: 7))) &&
                !at.isAfter(now);
          })
          .toSet()
          .take(15)
          .toList();
      final seen = (cache['seen'] as List? ?? []).whereType<String>().toList();
      if (!seen.contains(day) || cache['requested_timezone'] != timezone) {
        samples.add(now.toIso8601String());
        seen.add(day);
      }
      if (samples.isEmpty) return;
      final payload = <String, dynamic>{
        'samples': samples,
        'seen': seen.skip(seen.length > 9 ? seen.length - 9 : 0).toList(),
        'cohort_timezone': cache['cohort_timezone'],
        'requested_timezone': timezone,
      };
      // Deletion and the final write share Drift's transaction boundary.
      await store.transaction(() async {
        if (current()) await store.write(account, cacheKey, payload);
      });
      if (!current() || (_retryAt[retryKey]?.isAfter(now) ?? false)) return;
      try {
        final response = await send(
          family,
          List.unmodifiable(samples),
        ).timeout(const Duration(seconds: 10));
        if (!current()) return;
        final server = DateTime.tryParse(
          response['server_time'] as String? ?? '',
        );
        final ack = response['acknowledged'];
        final accepted = response['accepted'];
        if (response['family_id'] != family ||
            server == null ||
            ack is! List ||
            ack.length != samples.length ||
            !List.generate(
              samples.length,
              (i) => ack[i] == samples[i],
            ).every((v) => v) ||
            accepted is! int ||
            accepted < 0 ||
            accepted > samples.length ||
            response['complete'] is! bool) {
          throw const FormatException('家庭活跃回执不匹配');
        }
        final cohortZone = response['cohort_timezone'] as String?;
        if (cohortZone != null) tz.getLocation(cohortZone);
        // RTT bounded by timeout. Monotonic elapsed time avoids system-clock jumps
        // during this process; offline starts after a restart use device UTC.
        _serverAt = server.toUtc();
        _serverTick = _elapsed;
        await store.transaction(() async {
          if (!current()) return;
          await store.write(account, cacheKey, {
            ...payload,
            'samples': <String>[],
            'seen': accepted != samples.length
                ? <String>[]
                : cohortZone != null && cohortZone != cache['cohort_timezone']
                ? samples
                      .map(
                        (s) => tz.TZDateTime.from(
                          DateTime.parse(s),
                          tz.getLocation(cohortZone),
                        ).toIso8601String().substring(0, 10),
                      )
                      .toSet()
                      .toList()
                : payload['seen'],
            'cohort_timezone': cohortZone,
            'complete': response['complete'],
          });
        });
        _failures.remove(retryKey);
        _retryAt.remove(retryKey);
      } catch (error) {
        if (!current()) return;
        final failures = (_failures[retryKey] ?? 0) + 1;
        _failures[retryKey] = failures;
        _retryAt[retryKey] = _now.add(
          Duration(seconds: failures < 5 ? failures * 30 : 300),
        );
        if (error is PostgrestException && error.code == '42501') {
          await store.transaction(() async {
            if (current()) await store.remove(account, cacheKey);
          });
        }
      }
    });
    // Best-effort telemetry must never prevent learning or create unhandled errors.
    _tail = action.catchError((Object _) {});
    return _tail;
  }
}

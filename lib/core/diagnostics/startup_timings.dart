import 'package:flutter/foundation.dart';

// Local performance measurements only. Never enabled by a server or at runtime,
// and never active in release builds, even if the build definition is supplied.
const startupMeasurementEnabled =
    bool.fromEnvironment('MEASURE_STARTUP') && !kReleaseMode;

enum StartupPhase {
  binding,
  notifications,
  timezone,
  notificationPlugin,
  taskAlarmClear,
  notificationClear,
  database,
  credentials,
  supabase,
  push,
  initialization,
}

Stopwatch? _sinceMain;

void startStartupMeasurement() {
  if (startupMeasurementEnabled) _sinceMain = Stopwatch()..start();
}

void _emit(String phase, Duration elapsed, bool success) {
  try {
    debugPrint(
      'LP_STARTUP source=dart stage=$phase '
      'elapsed_us=${elapsed.inMicroseconds} outcome=${success ? 'ok' : 'error'}',
    );
  } catch (_) {
    // Optional timing output must never prevent startup or hide its real error.
  }
}

void recordStartupFirstFrame() {
  if (!startupMeasurementEnabled || _sinceMain == null) return;
  _sinceMain!.stop();
  _emit('first_frame', _sinceMain!.elapsed, true);
  _sinceMain = null;
}

T measureStartupSync<T>(StartupPhase phase, T Function() action) {
  if (!startupMeasurementEnabled) return action();
  final watch = Stopwatch()..start();
  var success = false;
  try {
    final result = action();
    success = true;
    return result;
  } finally {
    watch.stop();
    _emit(phase.name, watch.elapsed, success);
  }
}

Future<T> measureStartup<T>(
  StartupPhase phase,
  Future<T> Function() action,
) async {
  if (!startupMeasurementEnabled) return action();
  final watch = Stopwatch()..start();
  var success = false;
  try {
    final result = await action();
    success = true;
    return result;
  } finally {
    watch.stop();
    _emit(phase.name, watch.elapsed, success);
  }
}

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// A process-local timeline for authorization deadlines. Its origin is sampled
/// once. Subsequent phone clock changes cannot alter an existing deadline.
class ParentAuthorizationClock {
  ParentAuthorizationClock(
    this._elapsed, {
    DateTime Function() wall = DateTime.now,
  }) : _origin = wall().toUtc(),
       _started = _elapsed();

  final Duration Function() _elapsed;
  final DateTime _origin;
  final Duration _started;
  DateTime now() => _origin.add(_elapsed() - _started);

  static final device = ParentAuthorizationClock(_deviceElapsed());

  /// Charge the whole round trip against the grant. This prevents a delayed
  /// response from creating additional authorized time on the client.
  static DateTime deadline(DateTime requestStart, Map<String, dynamic> row) {
    final server = DateTime.tryParse(row['server_now'] as String? ?? '');
    if (server == null) throw StateError('未收到服务器授权时间，请更新服务后重试');
    final expires = DateTime.parse(row['authorized_until'] as String);
    return requestStart.add(expires.difference(server));
  }

  static Duration Function() _deviceElapsed() {
    if (Platform.isIOS || Platform.isMacOS) {
      final read = DynamicLibrary.process()
          .lookupFunction<Uint64 Function(Int32), int Function(int)>(
            'clock_gettime_nsec_np',
          );
      return () {
        final nanos = read(4); // Darwin CLOCK_MONOTONIC_RAW includes sleep.
        if (nanos == 0) throw StateError('设备计时不可用');
        return Duration(microseconds: nanos ~/ 1000);
      };
    }
    if (Platform.isAndroid || Platform.isLinux) {
      final read = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Int32, Pointer<Long>),
            int Function(int, Pointer<Long>)
          >('clock_gettime');
      return () {
        final timespec = calloc<Long>(2);
        try {
          if (read(7, timespec) != 0) throw StateError('设备计时不可用');
          // CLOCK_BOOTTIME advances across suspend. Android time_t is a C long.
          return Duration(
            seconds: timespec[0],
            microseconds: timespec[1] ~/ 1000,
          );
        } finally {
          calloc.free(timespec);
        }
      };
    }
    if (Platform.isWindows) {
      final read = DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<Uint64 Function(), int Function()>('GetTickCount64');
      return () => Duration(milliseconds: read());
    }
    throw UnsupportedError('设备计时不可用');
  }
}

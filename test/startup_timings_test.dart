import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/diagnostics/startup_timings.dart';

void main() {
  test(
    'startup timing preserves values and emits only bounded stage metadata when enabled',
    () async {
      final messages = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previous);
      startStartupMeasurement();
      expect(measureStartupSync(StartupPhase.binding, () => 7), 7);
      expect(
        await measureStartup(StartupPhase.notifications, () async => 11),
        11,
      );
      recordStartupFirstFrame();
      recordStartupFirstFrame();
      if (startupMeasurementEnabled) {
        expect(messages, hasLength(3));
        expect(
          messages.every(
            (line) => RegExp(
              r'^LP_STARTUP source=dart stage=(binding|notifications|first_frame) elapsed_us=\d+ outcome=ok$',
            ).hasMatch(line),
          ),
          isTrue,
        );
      } else {
        expect(messages, isEmpty);
      }
    },
  );

  test(
    'startup timing neither leaks exception messages nor masks failures with logger errors',
    () async {
      final messages = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previous);
      final failure = StateError('PRIVATE TOKEN / CHILD TEXT');
      await expectLater(
        measureStartup(StartupPhase.credentials, () async => throw failure),
        throwsA(same(failure)),
      );
      expect(
        () => measureStartupSync(StartupPhase.binding, () => throw failure),
        throwsA(same(failure)),
      );
      expect(messages.join(), isNot(contains('PRIVATE')));
      expect(messages, startupMeasurementEnabled ? hasLength(2) : isEmpty);
      debugPrint = (message, {wrapWidth}) =>
          throw StateError('logger unavailable');
      expect(await measureStartup(StartupPhase.push, () async => 13), 13);
      await expectLater(
        measureStartup(StartupPhase.push, () async => throw failure),
        throwsA(same(failure)),
      );
    },
  );
}

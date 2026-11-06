import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:learning_planet/core/diagnostics/native_diagnostics.dart';

// The host script only runs this on its dedicated Android 10 emulator. Between
// stages it asks Android to crash this synthetic installation, never a user app.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Java crash survives process death without private payload', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    const run = String.fromEnvironment('TEST_CRASH_RUN');
    expect(run, isNotEmpty);
    const bridge = MethodChannelNativeDiagnostics();
    const firstScope = '11111111-1111-4111-8111-111111111111';
    const otherScope = '22222222-2222-4222-8222-222222222222';
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString('integration_crash_run') != run) {
      await bridge.read(null);
      await preferences.setString('integration_crash_run', run);
      await preferences.setInt('integration_crash_phase', 0);
    }
    final phase = preferences.getInt('integration_crash_phase') ?? 0;
    final report = <String, dynamic>{
      'run': run,
      'phase': phase,
      'backend': 'none',
      'platform': 'dedicated Android 10 API29 AOSP emulator',
      'mode': kProfileMode ? 'profile' : 'debug',
      'qualifies_for_device_acceptance': false,
    };
    binding.reportData = report;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('原生崩溃采集本机验证'))),
      ),
    );
    await tester.pumpAndSettle();

    if (phase == 0) {
      expect(await bridge.read(firstScope), isEmpty);
      await preferences.setInt('integration_crash_phase', 1);
      report['scope_bound_before_external_crash'] = true;
    } else if (phase == 1) {
      final events = await bridge.read(firstScope);
      expect(events, hasLength(1));
      final event = events.single;
      expect(event.keys.toSet(), {'event_id', 'day', 'operation'});
      expect(event['operation'], 'androidJavaCrash');
      expect(Uuid.isValidUUID(fromString: event['event_id'] as String), isTrue);
      expect(
        DateTime.parse(
          '${event['day']}T00:00:00Z',
        ).isAfter(DateTime.now().toUtc()),
        isFalse,
      );
      expect(await bridge.read(firstScope), events);
      await bridge.acknowledge(firstScope, [event['event_id'] as String]);
      expect(await bridge.read(firstScope), isEmpty);
      await preferences.setInt('integration_crash_phase', 2);
      report['actual_crash_recovered_with_fixed_fields'] = true;
      report['lost_ack_keeps_event_id'] = true;
      report['acknowledged_event_not_repeated'] = true;
    } else if (phase == 2) {
      // A second actual crash belonged to the earlier opaque scope. A different
      // account must never import it, even though its marker is still on disk.
      expect(await bridge.read(otherScope), isEmpty);
      expect(await bridge.read(firstScope), isEmpty);
      expect(await bridge.read(null), isEmpty);
      await preferences.remove('integration_crash_phase');
      await preferences.remove('integration_crash_run');
      report['other_scope_cannot_import_previous_crash'] = true;
      report['returning_scope_cannot_replay_discarded_crash'] = true;
      report['signed_out_scope_cleared'] = true;
    } else {
      fail('Unknown synthetic crash phase');
    }
    report['completed'] = true;
  });
}

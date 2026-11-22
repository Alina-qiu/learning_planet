import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:learning_planet/core/config/app_config.dart';
import 'package:learning_planet/features/home/presentation/home_screen.dart';
import 'package:learning_planet/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _until(
  WidgetTester tester,
  String stage,
  bool Function() ready, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed >= timeout) {
      fail('Timed out waiting for $stage');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Only coordinates the two devices and reads the fixture's local OTP mailbox.
/// All session, task and wallet operations go through the running app.
Uri _controlUri(String device, String path) =>
    Uri.http('127.0.0.1:54324', path, {'device': device});

// allTestsPassed resolves after the binding has recorded assertion/teardown
// failures. A populated reportData alone cannot establish that the test passed.
Future<void> _sendAndroidOutcome(
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final passed = await binding.allTestsPassed.future;
  final report = binding.reportData;
  final success = passed && report?['stage'] == 'confirmed';
  final token = success
      ? Supabase.instance.client.auth.currentSession?.accessToken
      : null;
  final client = http.Client();
  try {
    for (var attempt = 0; success && token != null && attempt < 3; attempt++) {
      try {
        final response = await client
            .post(
              _controlUri('android', '/report'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode(report),
            )
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) return;
        if (response.statusCode < 500) break;
      } on TimeoutException {
        // An accepted report can lose its acknowledgement.
      } on http.ClientException {
        // The server accepts identical reports after transport recovery.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    // An accepted report is immutable even if all its acknowledgements were lost.
    try {
      await client
          .post(
            _controlUri('android', '/progress'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'stage': 'failed'}),
          )
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // The coordinator enforces an independent deadline.
    } on http.ClientException {
      // The coordinator also checks backend health while waiting.
    }
  } finally {
    client.close();
  }
}

class _Control {
  _Control(this.device, this.tester);
  final String device;
  final WidgetTester tester;
  final client = http.Client();

  Uri uri(String path) => _controlUri(device, path);

  Future<void> stage(Map<String, dynamic> report, String name) async {
    report['stage'] = name;
    if (device != 'android') return;
    final response = await client
        .post(
          uri('/progress'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'stage': name}),
        )
        .timeout(const Duration(seconds: 10));
    expect(response.statusCode, 200, reason: 'Reporting Android stage');
  }

  Future<Map<String, dynamic>> wait(
    String path, {
    String? phase,
    bool waitForOfflineRequest = false,
  }) async {
    final watch = Stopwatch()..start();
    final timeout = phase == null
        ? const Duration(minutes: 3)
        : const Duration(minutes: 15);
    while (watch.elapsed < timeout) {
      final response = await client
          .get(uri(path))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if ((phase == null || data['phase'] == phase) &&
            (!waitForOfflineRequest ||
                data['readerAttemptedWhileOffline'] == true)) {
          return data;
        }
      } else if (response.statusCode != 202) {
        fail('Fixture $path returned HTTP ${response.statusCode}');
      }
      await tester.pump(const Duration(seconds: 1));
    }
    fail('Timed out waiting for ${phase ?? path}');
  }

  Future<void> mark(String phase, String taskId) async {
    final response = await client
        .post(
          uri('/phase'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'phase': phase, 'task_id': taskId}),
        )
        .timeout(const Duration(seconds: 10));
    expect(response.statusCode, inInclusiveRange(200, 299), reason: phase);
  }
}

Future<void> _login(WidgetTester tester, _Control control, String email) async {
  await _until(
    tester,
    'email sign-in screen',
    () => find.text('登录学习星球').evaluate().isNotEmpty,
  );
  await tester.enterText(find.byType(EditableText), email);
  final send = find.text('发送验证码');
  await tester.ensureVisible(send);
  await tester.tap(send);
  final otp = await control.wait('/otp');
  final verify = find.widgetWithText(FilledButton, '验证并登录');
  await _until(
    tester,
    'enabled OTP form',
    () =>
        verify.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(verify).onPressed != null,
  );
  final code = otp['code'] as String;
  if (!RegExp(r'^\d{8}$').hasMatch(code)) fail('Invalid fixture OTP format');
  await tester.enterText(find.byType(EditableText), code);
  await tester.ensureVisible(verify);
  await tester.tap(verify);
  await _until(
    tester,
    'home after OTP verification',
    () => find.byType(HomeScreen).evaluate().isNotEmpty,
  );
}

Future<void> _selectChild(
  WidgetTester tester,
  String child,
  String family,
) async {
  final screen = find.byType(HomeScreen);
  final home = tester.widget<HomeScreen>(screen);
  expect(
    home.children.singleWhere((profile) => profile.id == child).familyId,
    family,
  );
  if (home.selectedChildId == child) return;
  await tester.tap(find.byTooltip('切换孩子'));
  final item = find.byWidgetPredicate(
    (widget) => widget is PopupMenuItem<String> && widget.value == child,
  );
  await _until(tester, 'child menu', () => item.evaluate().isNotEmpty);
  await tester.tap(item);
  await _until(
    tester,
    'selected child',
    () =>
        screen.evaluate().isNotEmpty &&
        tester.widget<HomeScreen>(screen).selectedChildId == child,
  );
}

/// Scroll within the sliver's extent. Overscrolling the top would manually
/// refresh data and invalidate the automatic reconnection assertion.
Future<void> _show(
  WidgetTester tester,
  Finder scroll,
  Finder target,
  String stage, {
  bool bottom = false,
}) async {
  await _until(tester, stage, () {
    if (target.evaluate().isNotEmpty) return true;
    if (scroll.evaluate().isEmpty) return false;
    final position = tester.state<ScrollableState>(scroll.first).position;
    final offset = bottom ? position.maxScrollExtent : position.minScrollExtent;
    if (offset.isFinite && position.pixels != offset) position.jumpTo(offset);
    return false;
  });
  await tester.ensureVisible(target);
  await tester.pump();
}

Future<void> _tapTaskAction(
  WidgetTester tester,
  Finder label,
  String stage,
) async {
  final button = find.ancestor(of: label, matching: find.byType(FilledButton));
  await _until(
    tester,
    stage,
    () =>
        button.hitTestable().evaluate().isNotEmpty &&
        tester.widget<FilledButton>(button).onPressed != null,
  );
  await tester.tap(button);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) unawaited(_sendAndroidOutcome(binding));
  testWidgets(
    'AC-01 Android completes, iOS reconnects to the same task and wallet',
    (tester) async {
      if (!Platform.isAndroid && !Platform.isIOS) {
        fail('Android or iOS device required');
      }
      final reader = Platform.isIOS;
      final device = reader ? 'ios' : 'android';
      final config = AppConfig.fromEnvironment();
      expect(config.localBackend, isTrue);
      expect(
        config.supabaseUrl,
        reader ? 'http://127.0.0.1:54325' : 'http://127.0.0.1:54326',
      );
      final control = _Control(device, tester);
      addTearDown(control.client.close);
      final report = <String, dynamic>{
        'device': device,
        'test': 'AC-01',
        'stage': 'fixture',
      };
      binding.reportData = report;
      await control.stage(report, 'fixture');
      final phase = (await control.wait(
        '/phase',
        phase: reader ? null : 'reader-ready',
      ))['phase'];
      final restoring = reader && phase == 'writer-complete';
      if (reader) {
        expect(phase, isIn(['initial', 'writer-complete']));
        report['reader_pass'] = restoring ? 'restore' : 'initial';
      }
      final scenario = await control.wait('/scenario');
      final task = scenario['task_id'] as String,
          child = scenario['child_id'] as String;
      final family = scenario['family_id'] as String;
      final coins = scenario['coins'] as int, xp = scenario['xp'] as int;
      expect(coins, greaterThan(0));
      expect(xp, greaterThan(0));
      report.addAll({'task_id': task, 'child_id': child, 'family_id': family});

      // main installs production error reporters. Keep framework failures visible
      // to the integration harness after the production entry point has run.
      final frameworkError = FlutterError.onError;
      final platformError = PlatformDispatcher.instance.onError;
      try {
        await app.main();
      } finally {
        FlutterError.onError = frameworkError;
        PlatformDispatcher.instance.onError = platformError;
      }
      if (restoring) {
        // The same simulator reopens the installed app with the data endpoint
        // still offline. Only its own persisted account and cache can open it.
        report['stage'] = 'restore_offline_session';
        await _until(
          tester,
          'home from the offline iPhone session',
          () => find.byType(HomeScreen).evaluate().isNotEmpty,
          timeout: const Duration(minutes: 4),
        );
      } else {
        await control.stage(report, 'email_login');
        await _login(tester, control, scenario['email'] as String);
      }
      await control.stage(report, 'load_family_task_and_wallet');
      await _selectChild(tester, child, family);
      final homeList = find.byKey(PageStorageKey('home:$child'));
      final scroll = find.descendant(
        of: homeList,
        matching: find.byType(Scrollable),
      );
      final card = find.byKey(ValueKey('home-task:$child:$task'));
      Finder onCard(String text) =>
          find.descendant(of: card, matching: find.text(text));
      final start = onCard('开始'), done = onCard('已完成');
      final initialWallet = find.text('金币 0 · 冻结 0 · XP 0');
      final paidWallet = find.text('金币 $coins · 冻结 0 · XP $xp');
      await _show(tester, scroll, initialWallet, 'initial wallet');
      await _show(tester, scroll, start, 'ready task', bottom: true);
      expect(onCard(scenario['title'] as String), findsOneWidget);
      report['ready_with_zero_wallet'] = true;
      if (reader && !restoring) {
        await control.mark('reader-ready', task);
        report['stage'] = 'cached_before_shutdown';
        return;
      }
      if (restoring) {
        report['offline_state_after_android_completion'] = true;
        report['stage'] = 'reconnect';
        await control.wait(
          '/phase',
          phase: 'writer-complete',
          waitForOfflineRequest: true,
        );
        await control.mark('reader-reconnect', task);
      } else {
        await control.stage(report, 'complete_task');
        await _tapTaskAction(tester, start, 'enabled start action');
        final finish = onCard('完成');
        await _show(tester, scroll, finish, 'in-progress task', bottom: true);
        await _tapTaskAction(tester, finish, 'enabled completion action');
      }
      await control.stage(report, 'confirm_task_and_wallet');
      await _show(tester, scroll, done, 'completed task', bottom: true);
      await _show(tester, scroll, paidWallet, 'confirmed wallet');
      report.addAll({'completed': true, 'coins': coins, 'xp': xp});
      await control.mark(reader ? 'reader-confirmed' : 'writer-complete', task);
      await control.stage(report, 'confirmed');
    },
  );
}

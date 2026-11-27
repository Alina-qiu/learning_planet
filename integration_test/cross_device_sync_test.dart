import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:learning_planet/core/config/app_config.dart';
import 'package:learning_planet/features/home/presentation/home_screen.dart';
import 'package:learning_planet/features/tasks/presentation/task_presentation.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_hub_screen.dart';
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

/// Progress is diagnostic. A lost acknowledgement can follow a successful
/// server write. Explicit HTTP rejections still indicate a fixture error.
Future<void> reportAndroidProgress(
  http.Client client,
  Uri endpoint,
  String stage, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final http.Response response;
  try {
    response = await client
        .post(
          endpoint,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'stage': stage}),
        )
        .timeout(timeout);
  } on TimeoutException {
    debugPrintSynchronously('AC01_PROGRESS_UNACKNOWLEDGED reason=timeout');
    return;
  } on http.ClientException {
    debugPrintSynchronously('AC01_PROGRESS_UNACKNOWLEDGED reason=transport');
    return;
  }
  expect(response.statusCode, 200, reason: 'Reporting Android stage');
}

/// Poll only the fixture mailbox. A dropped read must not send another email
/// or verify a code. Keep transport recovery inside the original deadline.
Future<String> readFixtureOtp(
  http.Client client,
  String device,
  Future<void> Function(Duration) pump, {
  Duration budget = const Duration(minutes: 3),
}) async {
  final watch = Stopwatch()..start();
  final endpoint = _controlUri(device, '/otp');
  var last = 'pending';
  while (watch.elapsed < budget) {
    final remaining = budget - watch.elapsed;
    if (remaining <= Duration.zero) break;
    const perRead = Duration(seconds: 10);
    http.Response? reply;
    try {
      reply = await client
          .get(endpoint)
          .timeout(remaining < perRead ? remaining : perRead);
    } on TimeoutException {
      last = 'timeout';
    } on http.ClientException {
      last = 'transport';
    } on SocketException {
      last = 'transport';
    }
    if (reply != null) {
      if (reply.statusCode == 200) {
        Object? data;
        try {
          data = jsonDecode(utf8.decode(reply.bodyBytes));
        } on FormatException {
          fail('Invalid fixture mailbox response');
        }
        if (data is Map && data['code'] is String) {
          final code = data['code'] as String;
          if (RegExp(r'^\d{8}$').hasMatch(code)) return code;
        }
        fail('Invalid fixture mailbox response');
      }
      if (reply.statusCode != 202) {
        fail('Fixture mailbox returned HTTP ${reply.statusCode}');
      }
      last = 'pending';
    }
    final delay = budget - watch.elapsed;
    if (delay <= Duration.zero) break;
    await pump(
      delay < const Duration(seconds: 1) ? delay : const Duration(seconds: 1),
    );
  }
  fail('Fixture mailbox deadline reached ($last)');
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
    await reportAndroidProgress(client, uri('/progress'), name);
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
    final target = uri(path);
    // This poll runs after the restored reader verifies its cached UI. The
    // gateway independently counts denied data requests before reconnection.
    final poll = waitForOfflineRequest
        ? target.replace(
            queryParameters: {
              ...target.queryParameters,
              'checkpoint': 'offline-home',
            },
          )
        : target;
    while (watch.elapsed < timeout) {
      final response = await client
          .get(poll)
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

Future<void> _login(
  WidgetTester tester,
  _Control control,
  String email,
  Map<String, dynamic> report,
) async {
  await _until(
    tester,
    'email sign-in screen',
    () => find.text('登录学习星球').evaluate().isNotEmpty,
  );
  await control.stage(report, 'login_form_visible');
  await tester.enterText(find.byType(EditableText), email);
  final send = find.text('发送验证码');
  await tester.ensureVisible(send);
  await tester.tap(send);
  await control.stage(report, 'otp_send_tapped');
  final code = await readFixtureOtp(
    control.client,
    control.device,
    tester.pump,
  );
  await control.stage(report, 'otp_received');
  final verify = find.widgetWithText(FilledButton, '验证并登录');
  await _until(
    tester,
    'enabled OTP form',
    () =>
        verify.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(verify).onPressed != null,
  );
  await control.stage(report, 'otp_form_ready');
  await tester.enterText(find.byType(EditableText), code);
  await tester.ensureVisible(verify);
  await tester.tap(verify);
  await control.stage(report, 'otp_verify_tapped');
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
  late HomeScreen home;
  await _until(tester, 'home with the fixture child', () {
    if (screen.evaluate().length != 1) return false;
    home = tester.widget<HomeScreen>(screen);
    return home.children.any((profile) => profile.id == child);
  });
  expect(
    home.children.singleWhere((profile) => profile.id == child).familyId,
    family,
  );
  if (home.selectedChildId == child) return;
  await tester.tap(find.byTooltip('切换孩子'));
  final item = find.byWidgetPredicate(
    (widget) => widget is PopupMenuItem<String> && widget.value == child,
  );
  await _until(tester, 'child menu', () {
    final entry = item.evaluate().singleOrNull;
    return entry != null &&
        ModalRoute.of(entry)?.animation?.isCompleted == true &&
        item.hitTestable().evaluate().isNotEmpty;
  });
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
Future<void> showFixtureTarget(
  WidgetTester tester,
  Finder scroll,
  Finder target,
  String stage, {
  bool bottom = false,
  bool Function()? matches,
}) async {
  await _until(tester, stage, () {
    if (target.evaluate().length == 1 && (matches?.call() ?? true)) return true;
    if (scroll.evaluate().isEmpty) return false;
    final position = tester.state<ScrollableState>(scroll.first).position;
    if (!position.hasPixels || !position.hasContentDimensions) return false;
    final offset = bottom ? position.maxScrollExtent : position.minScrollExtent;
    if (offset.isFinite && position.pixels != offset) position.jumpTo(offset);
    return false;
  });
  await tester.ensureVisible(target);
  await tester.pump();
}

/// Read each child's home and notebook through the production routes. Returning
/// to the primary child also exercises a second switch on the same session.
Future<List<Map<String, Object>>> observeFixtureChildViews(
  WidgetTester tester,
  String family,
  List<Map<String, dynamic>> profiles, {
  required bool offline,
}) async {
  expect(profiles, hasLength(2));
  final views = <Map<String, Object>>[];
  String wallet(Map<String, dynamic> profile) =>
      '金币 ${profile['coin_balance']} · 冻结 0 · XP ${profile['xp']}';
  for (final index in const [0, 1, 0]) {
    final profile = profiles[index], other = profiles[1 - index];
    final child = profile['child_id'] as String;
    final task = profile['task_id'] as String;
    await _selectChild(tester, child, family);
    final scroll = find.descendant(
      of: find.byKey(PageStorageKey('home:$child')),
      matching: find.byType(Scrollable),
    );
    final nickname = find.text(profile['nickname'] as String);
    await showFixtureTarget(tester, scroll, nickname, 'child nickname');
    final displayedName = tester.widget<Text>(nickname).data!;
    expect(find.text(other['nickname'] as String), findsNothing);
    final balance = find.text(wallet(profile));
    await showFixtureTarget(tester, scroll, balance, 'child wallet');
    expect(find.text(wallet(other)), findsNothing);

    final card = find.byKey(ValueKey('home-task:$child:$task'));
    final start = find.descendant(of: card, matching: find.text('开始'));
    await showFixtureTarget(
      tester,
      scroll,
      start,
      'child ready task',
      bottom: true,
    );
    final heading = tester.widget<TaskHeading>(
      find.descendant(of: card, matching: find.byType(TaskHeading)),
    );
    expect(heading.task.childId, child);
    expect(heading.task.id, task);
    expect(
      find.descendant(
        of: card,
        matching: find.text(profile['title'] as String),
      ),
      findsOneWidget,
    );
    expect(find.text(other['title'] as String), findsNothing);
    final action = tester.widget<FilledButton>(
      find.ancestor(of: start, matching: find.byType(FilledButton)),
    );
    expect(action.onPressed, isNotNull);

    final notebook = find.text('错题本与拼音复习');
    await showFixtureTarget(
      tester,
      scroll,
      notebook,
      'child notebook',
      bottom: true,
    );
    await tester.tap(notebook);
    final hub = find.byType(ReviewHubScreen);
    final question = find.descendant(
      of: hub,
      matching: find.text(profile['question'] as String),
    );
    final catalogScroll = find.descendant(
      of: find.descendant(of: hub, matching: find.byType(ListView)),
      matching: find.byType(Scrollable),
    );
    await showFixtureTarget(
      tester,
      catalogScroll,
      question,
      'child question',
      bottom: true,
    );
    final displayedQuestion = tester.widget<Text>(question).data!;
    expect(tester.widget<ReviewHubScreen>(hub).childId, child);
    expect(find.text(other['question'] as String), findsNothing);
    final offlineMessage = find.textContaining('离线查看：仅包含该筛选最近同步的首批记录');
    if (offline) {
      await showFixtureTarget(
        tester,
        catalogScroll,
        offlineMessage,
        'offline notebook',
      );
    } else {
      expect(offlineMessage, findsNothing);
    }
    views.add({
      'child_id': heading.task.childId,
      'nickname': displayedName,
      'task_id': heading.task.id,
      'title': heading.task.title,
      'question': displayedQuestion,
      'coin_balance': profile['coin_balance'] as int,
      'xp': profile['xp'] as int,
      'task_action': 'start',
    });
    await tester.pageBack();
    await _until(
      tester,
      'home after notebook',
      () =>
          hub.evaluate().isEmpty &&
          find.byTooltip('切换孩子').hitTestable().evaluate().isNotEmpty,
    );
  }
  return views;
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

String fixtureFailureMark(FlutterErrorDetails details) {
  final kind = switch (details.exception) {
    TestFailure() => 'assertion',
    StateError() => 'state',
    TypeError() => 'type',
    FlutterError() => 'framework',
    _ => 'other',
  };
  final line = RegExp(
    r'\bcross_device_sync_test\.dart:([1-9]\d{0,3}):\d+',
  ).firstMatch(details.stack?.toString() ?? '')?.group(1);
  final wait = switch (details.exception) {
    TestFailure(message: 'Timed out waiting for enabled start action') =>
      'start_button',
    TestFailure(message: 'Timed out waiting for in-progress task') =>
      'in_progress',
    TestFailure(message: 'Timed out waiting for enabled completion action') =>
      'complete_button',
    _ => null,
  };
  final marker = 'AC01_UI_FAILURE kind=$kind line=${line ?? 'unknown'}';
  return wait == null ? marker : '$marker wait=$wait';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    // The restricted stream includes only the category, fixture line and,
    // for a recognized task timeout, the fixed name of the failed wait.
    final original = reportTestException;
    var recorded = false;
    reportTestException = (details, description) {
      if (!recorded) {
        recorded = true;
        debugPrintSynchronously(fixtureFailureMark(details));
      }
      original(details, description);
    };
    unawaited(_sendAndroidOutcome(binding));
  }
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
        await _login(tester, control, scenario['email'] as String, report);
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
      await showFixtureTarget(tester, scroll, initialWallet, 'initial wallet');
      final title = onCard(scenario['title'] as String);
      await showFixtureTarget(
        tester,
        scroll,
        start,
        'ready task',
        bottom: true,
        matches: () =>
            card.evaluate().length == 1 && title.evaluate().length == 1,
      );
      report['ready_with_zero_wallet'] = true;
      if (reader && !restoring) {
        final profiles = (scenario['child_profiles'] as List)
            .cast<Map<String, dynamic>>();
        expect(profiles.first['child_id'], child);
        report['stage'] = 'online_child_views';
        report['online_child_views'] = await observeFixtureChildViews(
          tester,
          family,
          profiles,
          offline: false,
        );
        await control.mark('reader-ready', task);
        // The acknowledgement closes this device's data gateway. The
        // coordinator waits for this initial driver to finish before shutdown.
        report['stage'] = 'offline_child_views';
        report['offline_child_views'] = await observeFixtureChildViews(
          tester,
          family,
          profiles,
          offline: true,
        );
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
        await showFixtureTarget(
          tester,
          scroll,
          finish,
          'in-progress task',
          bottom: true,
        );
        await _tapTaskAction(tester, finish, 'enabled completion action');
      }
      await control.stage(report, 'confirm_task_and_wallet');
      await showFixtureTarget(
        tester,
        scroll,
        done,
        'completed task',
        bottom: true,
      );
      await showFixtureTarget(tester, scroll, paidWallet, 'confirmed wallet');
      report.addAll({'completed': true, 'coins': coins, 'xp': xp});
      await control.mark(reader ? 'reader-confirmed' : 'writer-complete', task);
      await control.stage(report, 'confirmed');
    },
  );
}

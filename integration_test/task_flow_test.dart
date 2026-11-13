import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/security/device_secrets.dart';
import 'package:learning_planet/core/security/encrypted_database.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/tasks/presentation/task_presentation.dart';

import '../test/support/task_workload.dart';

// Real KeyStore/Keychain calls, in a namespace separate from all app secrets.
class _FixtureSecrets implements DeviceSecrets {
  _FixtureSecrets(this.namespace);
  final String namespace;
  final DeviceSecrets native = const NativeDeviceSecrets();
  @override
  Future<String?> read(String key) => native.read('$namespace.$key');
  @override
  Future<void> write(String key, String value) =>
      native.write('$namespace.$key', value);
  @override
  Future<void> delete(String key) => native.delete('$namespace.$key');
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition, {
  required String stage,
}) async {
  // Debug/JIT on shared simulator hosts can spend tens of seconds in a single
  // pump. This is a functional watchdog, not the PRD's performance threshold.
  const timeout = kDebugMode ? Duration(seconds: 90) : Duration(seconds: 20);
  final deadline = Stopwatch()..start();
  var pumps = 0;
  var longestPumpMs = 0;
  while (!condition() && deadline.elapsed < timeout) {
    final pumpWatch = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    pumps++;
    if (pumpWatch.elapsedMilliseconds > longestPumpMs) {
      longestPumpMs = pumpWatch.elapsedMilliseconds;
    }
  }
  final ready = condition();
  final binding = tester.binding as IntegrationTestWidgetsFlutterBinding;
  final waits =
      binding.reportData?.putIfAbsent('state_waits', () => <String, dynamic>{})
          as Map<String, dynamic>?;
  waits?[stage] = {
    'ready': ready,
    'timeout_ms': timeout.inMilliseconds,
    'waited_ms': deadline.elapsedMilliseconds,
    'pumps': pumps,
    'longest_pump_ms': longestPumpMs,
  };
  if (!ready) {
    binding.reportData?['failure'] = {
      'stage': stage,
      'waited_ms': deadline.elapsedMilliseconds,
      'rendered_text': tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
          .take(60)
          .toList(),
    };
    debugDumpApp();
    try {
      if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
      await binding
          .takeScreenshot('failure-$stage')
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      binding.reportData?['failure_screenshot_error'] = error.toString();
    }
  }
  expect(
    ready,
    isTrue,
    reason: 'The expected application state did not appear.',
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('encrypted local completion survives reopen with network held', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final directory = await Directory(
      '${support.path}/integration-fixtures',
    ).create(recursive: true);
    final run = await directory.createTemp('task-flow-');
    final secrets = _FixtureSecrets(
      'integration.${run.uri.pathSegments.where((part) => part.isNotEmpty).last}',
    );
    final remote = HeldTaskRemote();
    final data = taskWorkload(1000, DateTime.now());
    OfflineStore? store;
    OfflineTaskRepository? repository;
    final report = <String, dynamic>{
      'dataset_tasks': data.length,
      'backend': 'synthetic-held-remote',
      'mode': kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug',
      'platform': Platform.operatingSystem,
      'device': const String.fromEnvironment(
        'TEST_DEVICE_LABEL',
        defaultValue: 'unspecified',
      ),
      'qualifies_for_prd_acceptance': false,
      'scope':
          'Seeded app screens and native encrypted storage; excludes production cold start, auth and backend.',
    };
    binding.reportData = report;
    try {
      store = OfflineStore(await EncryptedDatabase.open(run, secrets));
      await store.write(
        workloadOwner,
        'tasks:$workloadChild',
        taskWorkloadSnapshot(data, DateTime.now()),
      );
      repository = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: WorkloadTasks(data),
        accountId: () => workloadOwner,
        autoSync: false,
      );
      final watch = Stopwatch()..start();
      await tester.pumpWidget(
        LearningPlanetApp(
          authRepository: WorkloadAuth(),
          familyRepository: WorkloadFamily(),
          taskRepository: repository,
        ),
      );
      await _until(
        tester,
        () => find.text('金币 100 · 冻结 0 · XP 120').evaluate().isNotEmpty,
        stage: 'home-wallet',
      );
      report['seeded_home_ready_ms'] = watch.elapsedMicroseconds / 1000;
      await tester.pumpAndSettle();
      expect(find.byType(TaskHeading).evaluate().length, lessThan(30));

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      watch.reset();
      await tester.tap(find.text('任务管理'));
      await _until(
        tester,
        () =>
            find.byType(TaskManagementScreen).evaluate().isNotEmpty &&
            find.byTooltip('完成').hitTestable().evaluate().isNotEmpty,
        stage: 'task-list',
      );
      report['task_list_first_usable_frame_ms'] =
          watch.elapsedMicroseconds / 1000;
      await tester.pumpAndSettle();
      expect(find.byType(TaskHeading).evaluate().length, lessThan(30));
      expect(remote.calls, greaterThan(0));
      expect(remote.waiting.isCompleted, isFalse);

      watch.reset();
      await tester.tap(find.byTooltip('完成'));
      await _until(
        tester,
        () => find.text('完成记录已保存本机，奖励待同步确认').evaluate().isNotEmpty,
        stage: 'local-completion',
      );
      report['local_completion_feedback_ms'] = watch.elapsedMicroseconds / 1000;
      final commands = await store.commands(workloadOwner);
      expect(commands, hasLength(1));
      final commandId = commands.single['command_id'];
      expect(
        (await repository.loadTasks(
          workloadChild,
        )).singleWhere((task) => task.id == workloadTaskId(0)).status,
        TaskStatus.completed,
      );
      expect((await repository.loadWallet(workloadChild)).coins, 100);
      expect(remote.waiting.isCompleted, isFalse);
      report['committed_before_network_reply'] = true;

      await tester.pumpAndSettle();
      final taskList = find.byKey(PageStorageKey('tasks:$workloadChild'));
      expect(taskList, findsOneWidget);
      final scrolling = tester.state<ScrollableState>(
        find.descendant(of: taskList, matching: find.byType(Scrollable)),
      );
      final initialOffset = scrolling.position.pixels;
      await binding.watchPerformance(() async {
        for (var i = 0; i < 10; i++) {
          await tester.drag(taskList, const Offset(0, -350));
          await tester.pumpAndSettle();
        }
      }, reportKey: 'task_scroll');
      expect(scrolling.position.pixels, greaterThan(initialOffset));
      expect(find.byType(TaskHeading).evaluate().length, lessThan(30));
      report['task_list_scrolled'] = true;

      // Screenshot conversion is excluded from timing measurements.
      if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('task-list-1000');
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await binding.takeScreenshot('task-list-text-200');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      remote.waiting.complete();
      await repository.dispose();
      repository = null;
      await store.close();
      store = null;
      final bytes = await File(
        '${run.path}/${EncryptedDatabase.fileName}',
      ).readAsBytes();
      final raw = latin1.decode(bytes);
      expect(raw.startsWith('SQLite format 3'), isFalse);
      expect(
        raw,
        isNot(contains(latin1.decode(utf8.encode(data.first.title)))),
      );
      store = OfflineStore(await EncryptedDatabase.open(run, secrets));
      expect(
        (await store.commands(workloadOwner)).single['command_id'],
        commandId,
      );
      repository = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: WorkloadTasks(data),
        accountId: () => workloadOwner,
        autoSync: false,
      );
      expect(
        (await repository.loadTasks(
          workloadChild,
        )).singleWhere((task) => task.id == workloadTaskId(0)).status,
        TaskStatus.completed,
      );
      expect((await repository.loadWallet(workloadChild)).coins, 100);
      report['encrypted_reopen_preserves_command_and_projection'] = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!remote.waiting.isCompleted) remote.waiting.complete();
      await repository?.dispose();
      await store?.close();
      await secrets.delete(EncryptedDatabase.keyName);
      // Only this run's createTemp directory, never the normal application DB.
      await run.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

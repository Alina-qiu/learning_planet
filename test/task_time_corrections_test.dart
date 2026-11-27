import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/features/tasks/data/task_time_corrections.dart';
import 'package:learning_planet/features/tasks/presentation/task_time_correction_screen.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'task_preferences_test.dart' show AbandonTasks, task;
import 'support/mock_supabase.dart';

const timeScope = (taskId: 'task', childId: 'child', familyId: 'family');
Map<String, dynamic> timeValue({int seconds = 120, int version = 3}) => {
  'owner_id': 'owner',
  'task_id': 'task',
  'child_id': 'child',
  'family_id': 'family',
  'seconds': seconds,
  'version': version,
  'running': false,
  'status': 'completed',
};

class TimeRemote implements TaskTimeRemote {
  Map<String, dynamic> value = timeValue();
  final requests = <TaskTimeRequest>[];
  Future<Map<String, dynamic>> Function()? loading;
  Future<Map<String, dynamic>> Function(TaskTimeRequest)? saving;
  @override
  Future<Map<String, dynamic>> load(String id) async =>
      loading == null ? value : loading!();
  @override
  Future<Map<String, dynamic>> correct(String id, TaskTimeRequest r) async {
    requests.add(r);
    return saving == null
        ? {
            'request_id': r.id,
            'applied_version': r.expectedVersion + 1,
            'current': timeValue(
              seconds: r.seconds,
              version: r.expectedVersion + 1,
            ),
          }
        : saving!(r);
  }
}

class TimeHarness {
  final store = OfflineStore(NativeDatabase.memory()), remote = TimeRemote();
  String? owner = 'owner';
  bool allowed = true;
  int revision = 0;
  late final service = TaskTimeCorrections(
    store: store,
    remote: remote,
    owner: () => owner,
    authorized: (_) => allowed,
    revision: () => revision,
  );
  TaskTimeRequest request({
    int seconds = 60,
    int version = 3,
    String reason = '误点暂停，按实际时长纠正',
  }) => TaskTimeRequest(
    id: 'request',
    expectedVersion: version,
    seconds: seconds,
    reason: reason,
    access: service.capture(timeScope),
  );
  Future<void> close() async {
    service.dispose();
    await store.close();
  }
}

// UI fixtures use no real database I/O; repository races exercise SQLite above.
class PreviewTimeCorrections extends TaskTimeCorrections {
  PreviewTimeCorrections(this.h)
    : super(
        store: h.store,
        remote: h.remote,
        owner: () => h.owner,
        authorized: (_) => h.allowed,
        revision: () => h.revision,
      );
  final TimeHarness h;
  TaskTimeContext current = const TaskTimeContext(
    seconds: 120,
    version: 3,
    running: false,
    status: 'completed',
  );
  Object? failure;
  Completer<TaskTimeContext>? pending;
  final requests = <TaskTimeRequest>[];
  @override
  Future<TaskTimeContext> load(
    TaskTimeScope scope, {
    TimeAccess? access,
  }) async => current;
  @override
  Future<TaskTimeContext> correct(
    TaskTimeScope scope,
    TaskTimeRequest request,
  ) async {
    requests.add(request);
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    return current = TaskTimeContext(
      seconds: request.seconds,
      version: request.expectedVersion + 1,
      running: false,
      status: 'completed',
    );
  }
}

void main() {
  test(
    'time repository binds fields and original request, rejecting malformed or cross-scope receipts',
    () async {
      final h = TimeHarness();
      addTearDown(h.close);
      expect((await h.service.load(timeScope)).seconds, 120);
      final original = h.request();
      expect((await h.service.correct(timeScope, original)).seconds, 60);
      for (final patch in [
        {'owner_id': 'other'},
        {'task_id': 'other'},
        {'child_id': 'other'},
        {'family_id': 'other'},
        {'seconds': -1},
        {'version': -1},
        {'status': 'unknown'},
        {'running': null},
      ]) {
        h.remote.value = {...timeValue(), ...patch};
        await expectLater(h.service.load(timeScope), throwsFormatException);
      }
      for (final patch in [
        {'request_id': 'other'},
        {'applied_version': 3},
        {'applied_version': 5},
        {'current': timeValue(seconds: 60, version: 3)},
        {'current': timeValue(seconds: 61, version: 4)},
      ]) {
        h.remote.saving = (r) async => {
          'request_id': r.id,
          'applied_version': 4,
          'current': timeValue(seconds: 60, version: 4),
          ...patch,
        };
        await expectLater(
          h.service.correct(timeScope, original),
          throwsFormatException,
        );
      }
      h.remote.saving = (r) async => {
        'request_id': r.id,
        'applied_version': 4,
        'current': timeValue(seconds: 180, version: 5),
      };
      expect((await h.service.correct(timeScope, original)).seconds, 180);
    },
  );
  test(
    'invalid corrections and pending local task commands never reach the server',
    () async {
      final h = TimeHarness();
      addTearDown(h.close);
      for (final request in [
        h.request(seconds: -1),
        h.request(seconds: 2147483648),
        h.request(version: -1),
        h.request(reason: ' '),
        h.request(reason: '🪐' * 501),
      ]) {
        await expectLater(
          h.service.correct(timeScope, request),
          throwsFormatException,
        );
      }
      await h.store.enqueue('owner', 'child', {
        'command_id': 'command',
        'task_id': 'task',
        'kind': 'pause',
      });
      await expectLater(h.service.load(timeScope), throwsStateError);
      await expectLater(
        h.service.correct(timeScope, h.request()),
        throwsStateError,
      );
      expect(h.remote.requests, isEmpty);
    },
  );
  for (final change in [
    'owner',
    'pin',
    'revision',
    'child',
    'account',
    'membership',
    'dispose',
  ]) {
    test(
      'late timing read and write results are discarded after $change changes',
      () async {
        for (final write in [false, true]) {
          final h = TimeHarness();
          addTearDown(h.close);
          final entered = Completer<void>(),
              waiting = Completer<Map<String, dynamic>>();
          h.remote.loading = () {
            entered.complete();
            return waiting.future;
          };
          h.remote.saving = (r) {
            entered.complete();
            return waiting.future;
          };
          final request = h.request(),
              future = write
                  ? h.service.correct(timeScope, request)
                  : h.service.load(timeScope);
          final rejected = expectLater(future, throwsStateError);
          await entered.future;
          switch (change) {
            case 'owner':
              h.owner = 'other';
            case 'pin':
              h.allowed = false;
            case 'revision':
              h.revision++;
            case 'child':
              await h.store.removeChildData('child');
            case 'account':
              await h.store.removeAccountData('owner', 'job');
            case 'membership':
              await h.store.applyFamilyAccess('owner', [
                FamilyAccessState(
                  familyId: 'family',
                  version: 2,
                  active: false,
                  lastRevokedVersion: 2,
                  childIds: {'child'},
                ),
              ]);
            case 'dispose':
              h.service.dispose();
          }
          waiting.complete(
            write
                ? {
                    'request_id': request.id,
                    'applied_version': 4,
                    'current': timeValue(seconds: 60, version: 4),
                  }
                : timeValue(),
          );
          await rejected;
        }
      },
    );
  }
  test(
    'Supabase adapter sends only server version, corrected seconds, reason and stable request ID',
    () async {
      final api = MockSupabase();
      addTearDown(api.close);
      final h = TimeHarness();
      addTearDown(h.close);
      api.handle = (r) => MockSupabase.json(r, timeValue());
      final remote = SupabaseTaskTimeRemote(api.client);
      await remote.load('task');
      await remote.correct('task', h.request());
      expect(api.calls[0].url.path, endsWith('/task_time_context'));
      expect(MockSupabase.body(api.calls[0]), {'target_task_id': 'task'});
      expect(MockSupabase.body(api.calls[1]), {
        'target_task_id': 'task',
        'request_id': 'request',
        'expected_version': 3,
        'corrected_seconds': 60,
        'reason': '误点暂停，按实际时长纠正',
      });
    },
  );
  Future<ProviderContainer> mount(
    WidgetTester tester,
    PreviewTimeCorrections service, {
    double scale = 1,
    Widget? home,
    bool parent = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [
        taskTimeCorrectionsProvider.overrideWithValue(service),
        activeParentFamilyProvider.overrideWithValue(parent ? 'family' : null),
        authorizationClockProvider.overrideWith(
          (ref) => Stream.value(DateTime.utc(2026, 11, 5)),
        ),
        familiesProvider.overrideWith((ref) async => []),
        taskRepositoryProvider.overrideWithValue(
          AbandonTasks()..current = task(status: TaskStatus.completed),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home:
              home ??
              const TaskTimeCorrectionScreen(scope: timeScope, title: '阅读第三章'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> edit(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), '3');
    await tester.enterText(find.byType(TextFormField).at(1), '5');
    await tester.enterText(find.byType(TextFormField).at(2), '忘记暂停，确认实际阅读时长');
  }

  Future<void> save(WidgetTester tester, {bool retry = false}) async {
    final button = find.text(retry ? '重试原纠正请求' : '确认纠正计时');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'parent can correct completed task through the real task-management entry',
    (tester) async {
      final h = TimeHarness();
      addTearDown(h.close);
      final service = PreviewTimeCorrections(h);
      await mount(
        tester,
        service,
        home: const TaskManagementScreen(
          childId: 'child',
          childNickname: '星宝',
          familyId: 'family',
          isParentMode: false,
        ),
      );
      await tester.tap(find.byTooltip('家长纠正计时'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskTimeCorrectionScreen), findsOneWidget);
      await edit(tester);
      await save(tester);
      expect(service.requests.single.seconds, 185);
      expect(service.requests.single.expectedVersion, 3);
      expect(find.textContaining('纠正已受理'), findsOneWidget);
      expect(service.current.status, 'completed');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('child mode has no timing-correction entry', (tester) async {
    final h = TimeHarness();
    addTearDown(h.close);
    await mount(
      tester,
      PreviewTimeCorrections(h),
      parent: false,
      home: const TaskManagementScreen(
        childId: 'child',
        childNickname: '星宝',
        familyId: 'family',
        isParentMode: true,
      ),
    );
    expect(find.byTooltip('家长纠正计时'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'time fields require a changed time, valid seconds and a reason at double text size',
    (tester) async {
      final h = TimeHarness();
      addTearDown(h.close);
      final service = PreviewTimeCorrections(h);
      await mount(tester, service, scale: 2);
      await save(tester);
      expect(service.requests, isEmpty);
      await tester.enterText(find.byType(TextFormField).at(2), '实际计时');
      await save(tester);
      expect(find.textContaining('时长未变化'), findsOneWidget);
      await edit(tester);
      await tester.enterText(find.byType(TextFormField).at(1), '60');
      await save(tester);
      expect(service.requests, isEmpty);
      await tester.enterText(find.byType(TextFormField).at(1), '5');
      await save(tester);
      expect(service.requests.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'uncertain save freezes values and retries the original request',
    (tester) async {
      final h = TimeHarness();
      addTearDown(h.close);
      final service = PreviewTimeCorrections(h)
        ..failure = const SocketException('lost reply');
      await mount(tester, service);
      await edit(tester);
      await save(tester);
      expect(find.textContaining('保存结果尚未确认'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).readOnly,
        true,
      );
      service.failure = null;
      await save(tester, retry: true);
      expect(identical(service.requests[0], service.requests[1]), true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'version conflict requires a fresh read; active task cannot be corrected',
    (tester) async {
      final h = TimeHarness();
      addTearDown(h.close);
      final service = PreviewTimeCorrections(
        h,
      )..failure = const PostgrestException(message: 'conflict', code: '40001');
      await mount(tester, service);
      await edit(tester);
      await save(tester);
      expect(find.textContaining('任务已被更新'), findsOneWidget);
      service.current = const TaskTimeContext(
        seconds: 180,
        version: 4,
        running: true,
        status: 'in_progress',
      );
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(find.textContaining('任务仍在计时'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认纠正计时'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'PIN loss hides timing fields and a late save cannot restore them',
    (tester) async {
      final h = TimeHarness();
      addTearDown(h.close);
      final delayed = Completer<TaskTimeContext>(),
          service = PreviewTimeCorrections(h)..pending = delayed;
      final container = await mount(tester, service);
      await edit(tester);
      await tester.ensureVisible(find.text('确认纠正计时'));
      await tester.tap(find.text('确认纠正计时'));
      await tester.pump();
      h.allowed = false;
      container.read(parentAuthorizationRevisionProvider.notifier).state++;
      await tester.pump();
      expect(find.byType(TextFormField), findsNothing);
      delayed.complete(
        const TaskTimeContext(
          seconds: 185,
          version: 4,
          running: false,
          status: 'completed',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      expect(find.textContaining('纠正已受理'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

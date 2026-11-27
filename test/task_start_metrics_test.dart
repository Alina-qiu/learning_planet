import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/reports/data/report_repository.dart';
import 'package:learning_planet/features/reports/domain/learning_report.dart';
import 'package:learning_planet/features/reports/domain/task_start_metrics.dart';
import 'package:learning_planet/features/reports/presentation/learning_report_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/application/task_start_provider.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task_start_origin.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'offline_review_test.dart' show ReviewRemote, LiveReview;
import 'widget_test.dart' show FakeTaskRepository;
import 'learning_report_test.dart' show sample;
import 'support/mock_supabase.dart';

Map<String, dynamic> stats({bool unknown = false, bool empty = false}) => {
  'version': 'start-v1',
  'eligible': empty ? 0 : 6,
  'autonomous': empty ? 0 : 2,
  'parent_assisted': empty ? 0 : 1,
  'outside_window': empty ? 0 : 1,
  'unknown': unknown ? 1 : 0,
  'not_started': empty
      ? 0
      : unknown
      ? 1
      : 2,
  'future_windows': 2,
  'invalid_windows': 0,
  'rate': unknown || empty ? null : 0.3333,
};

class StartReports implements ReportRepository {
  bool unknown = false;
  @override
  Future<LearningReport> load(ReportScope scope) async => LearningReport({
    ...sample().data,
    'start_metrics': stats(unknown: unknown),
  });
}

class Starts extends FakeTaskRepository implements AttributedTaskStarter {
  final origins = <TaskStartOrigin>[];
  int legacy = 0;
  @override
  Future<void> start(String taskId) async {
    legacy++;
  }

  @override
  Future<void> startWithOrigin(String taskId, TaskStartOrigin origin) async {
    origins.add(origin);
  }
}

class ReviewStarts extends LiveReview implements AttributedTaskStarter {
  ReviewStarts(super.remote);
  final origins = <TaskStartOrigin>[];
  @override
  Future<void> startWithOrigin(String taskId, TaskStartOrigin origin) async {
    origins.add(origin);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'mode attribution is family scoped and remains assisted after parent PIN expires',
    () {
      expect(
        TaskStartOrigin.forMode(
          familyId: null,
          parentMode: false,
          parentFamilyId: null,
        ),
        TaskStartOrigin.unknown,
      );
      expect(
        TaskStartOrigin.forMode(
          familyId: '',
          parentMode: false,
          parentFamilyId: null,
        ),
        TaskStartOrigin.unknown,
      );
      expect(
        TaskStartOrigin.forMode(
          familyId: 'f',
          parentMode: false,
          parentFamilyId: null,
        ),
        TaskStartOrigin.childMode,
      );
      expect(
        TaskStartOrigin.forMode(
          familyId: 'f',
          parentMode: true,
          parentFamilyId: 'other',
        ),
        TaskStartOrigin.unknown,
      );
      final container = ProviderContainer(
        overrides: [
          parentModeProvider.overrideWith((ref) => true),
          parentFamilyIdProvider.overrideWith((ref) => 'f'),
          parentAuthorizedUntilProvider.overrideWith((ref) => DateTime(2000)),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(activeParentFamilyProvider), isNull);
      expect(
        container.read(taskStartOriginProvider('f')),
        TaskStartOrigin.parentAssisted,
      );
      container.read(parentModeProvider.notifier).state = false;
      expect(
        container.read(taskStartOriginProvider('f')),
        TaskStartOrigin.childMode,
      );
    },
  );
  test(
    'start metrics distinguish unknown records, no executable tasks and measured zero',
    () {
      expect(TaskStartMetrics.fromJson(stats()).rate, .3333);
      expect(TaskStartMetrics.fromJson(stats(unknown: true)).rate, isNull);
      expect(TaskStartMetrics.fromJson(stats(empty: true)).rate, isNull);
      final zero = stats()
        ..['autonomous'] = 0
        ..['not_started'] = 4
        ..['rate'] = 0;
      expect(TaskStartMetrics.fromJson(zero).rate, 0);
      for (final row in [
        stats()..['eligible'] = 7,
        stats()..['rate'] = 1,
        stats()..['rate'] = null,
        stats(unknown: true)..['rate'] = .3333,
        stats()..['version'] = 'future',
        stats()..['eligible'] = -1,
        stats()..['eligible'] = .5,
        stats()..['rate'] = double.nan,
        stats()..['invalid_windows'] = 1,
      ]) {
        expect(() => TaskStartMetrics.fromJson(row), throwsFormatException);
      }
      expect(LearningReport(sample().data).startMetrics, isNull);
    },
  );
  test(
    'ordinary and review online adapters send explicit origin while legacy entry points remain unlabelled',
    () async {
      final backend = MockSupabase();
      addTearDown(backend.close);
      await backend.signIn();
      backend.handle = (request) => MockSupabase.json(request, {});
      final tasks = SupabaseTaskRepository(backend.client),
          reviews = SupabaseReviewRepository(backend.client);
      await startTaskWithOrigin(tasks, 'task', TaskStartOrigin.childMode);
      await startReviewWithOrigin(
        reviews,
        'review',
        TaskStartOrigin.parentAssisted,
      );
      expect(
        backend.calls.map((r) => r.url.path),
        everyElement('/rest/v1/rpc/start_task_with_origin'),
      );
      expect(MockSupabase.body(backend.calls[0]), {
        'target_task_id': 'task',
        'requested_origin': 'child_mode',
      });
      expect(MockSupabase.body(backend.calls[1]), {
        'target_task_id': 'review',
        'requested_origin': 'parent_assisted',
      });
      await tasks.start('old');
      await reviews.transition('old-review', 'start');
      expect(backend.calls.last.url.path, '/rest/v1/rpc/start_task');
      expect(MockSupabase.body(backend.calls.last), {
        'target_task_id': 'old-review',
      });
      await startTaskWithOrigin(
        FakeTaskRepository(),
        'legacy',
        TaskStartOrigin.childMode,
      );
    },
  );
  test(
    'ordinary start source and original UUID survive disk restart and a lost acknowledgement',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-start-origin-',
      );
      final file = File('${directory.path}/queue.sqlite');
      var now = DateTime.utc(2026, 11, 4, 8);
      String? owner = 'parent';
      final remote = FakeTaskRemote(() => now)..seed('child');
      var store = OfflineStore(NativeDatabase(file));
      OfflineTaskRepository make() => OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => owner,
        clock: () => now,
        autoSync: false,
      )..setForeground(false);
      var tasks = make();
      try {
        await tasks.loadTasks('child');
        remote.online = false;
        await tasks.startWithOrigin(
          'task-child',
          TaskStartOrigin.parentAssisted,
        );
        final original = Map<String, dynamic>.from(
          (await store.commands('parent')).single['command'] as Map,
        );
        expect(original['start_origin'], 'parent_assisted');
        await tasks.dispose();
        await store.close();
        store = OfflineStore(NativeDatabase(file));
        tasks = make();
        await tasks.loadTasks('child');
        expect((await store.commands('parent')).single['command'], original);
        owner = 'other';
        expect(await store.commands('other'), isEmpty);
        owner = 'parent';
        now = now.add(const Duration(minutes: 1));
        remote.online = true;
        remote.failAfterCommit = true;
        await tasks.synchronize('child');
        expect((await store.commands('parent')).single['command'], original);
        await tasks.synchronize('child');
        expect(await store.commands('parent'), isEmpty);
        expect(remote.requests.map((r) => r['command_id']).toSet(), {
          original['command_id'],
        });
        expect(
          remote.requests.every((r) => r['start_origin'] == 'parent_assisted'),
          isTrue,
        );
        await tasks.pause('task-child');
        expect(
          (await store.commands('parent')).single['command'],
          isNot(contains('start_origin')),
        );
      } finally {
        await tasks.dispose();
        await store.close();
        final root = Directory.systemTemp.absolute.path;
        if (!directory.absolute.path.startsWith(
          '$root${Platform.pathSeparator}learning-planet-start-origin-',
        )) {
          throw StateError('Unexpected test directory');
        }
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'cached review start carries source in its durable command and rejects metadata on non-start transitions',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      final now = DateTime.utc(2026, 11, 4, 8);
      final remote = ReviewRemote(() => now);
      final tasks = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => 'parent',
        clock: () => now,
        autoSync: false,
      )..setForeground(false);
      final reviews = CachedReviewRepository(
        LiveReview(remote),
        store,
        () => 'parent',
        tasks: tasks,
      );
      try {
        await tasks.loadTasks('child');
        await reviews.task('task-child');
        remote.online = false;
        await startReviewWithOrigin(
          reviews,
          'task-child',
          TaskStartOrigin.childMode,
        );
        final command = (await store.commands('parent')).single['command'];
        expect(command['kind'], 'review_start');
        expect(command['start_origin'], 'child_mode');
        await expectLater(
          tasks.queueReview(
            'task-child',
            'pause',
            startOrigin: TaskStartOrigin.parentAssisted,
          ),
          throwsArgumentError,
        );
        await reviews.transition('task-child', 'pause');
        expect(
          (await store.commands('parent')).last['command'],
          isNot(contains('start_origin')),
        );
        remote.online = true;
        remote.failAfterCommit = true;
        await tasks.synchronize('child');
        await tasks.synchronize('child');
        expect(
          remote.requests
              .where((r) => r['kind'] == 'review_start')
              .every((r) => r['start_origin'] == 'child_mode'),
          isTrue,
        );
        expect(await store.commands('parent'), isEmpty);
        final live = ReviewStarts(remote);
        await startReviewWithOrigin(
          CachedReviewRepository(live, store, () => 'parent'),
          'r',
          TaskStartOrigin.parentAssisted,
        );
        expect(live.origins, [TaskStartOrigin.parentAssisted]);
      } finally {
        await tasks.dispose();
        await store.close();
      }
    },
  );
  test('legacy ordinary commands do not invent a child source', () async {
    final store = OfflineStore(NativeDatabase.memory());
    final now = DateTime.utc(2026, 11, 4, 8);
    final remote = FakeTaskRemote(() => now)..seed('child');
    final tasks = OfflineTaskRepository(
      store: store,
      remote: remote,
      live: const UnconfiguredTaskRepository(),
      accountId: () => 'parent',
      clock: () => now,
      autoSync: false,
    )..setForeground(false);
    try {
      await tasks.loadTasks('child');
      await tasks.start('task-child');
      expect(
        (await store.commands('parent')).single['command'],
        isNot(contains('start_origin')),
      );
    } finally {
      await tasks.dispose();
      await store.close();
    }
  });
  Future<ProviderContainer> mount(
    WidgetTester tester,
    Widget page,
    Starts tasks, {
    ReviewRepository? reviews,
    StartReports? reports,
    bool parent = true,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(tasks),
          familiesProvider.overrideWith((ref) async => []),
          parentModeProvider.overrideWith((ref) => parent),
          parentFamilyIdProvider.overrideWith((ref) => 'family'),
          parentAuthorizedUntilProvider.overrideWith(
            (ref) => DateTime.now().add(const Duration(hours: 1)),
          ),
          if (reviews != null)
            reviewRepositoryProvider.overrideWithValue(reviews),
          if (reports != null)
            reportRepositoryProvider.overrideWithValue(reports),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  testWidgets(
    'task screen labels parent assistance and samples current mode at the action',
    (tester) async {
      final tasks = Starts();
      final container = await mount(
        tester,
        const TaskManagementScreen(
          childId: 'child',
          childNickname: '小星',
          isParentMode: true,
          familyId: 'family',
        ),
        tasks,
      );
      await tester.tap(find.text('家长代开始'));
      await tester.pumpAndSettle();
      expect(tasks.origins, [TaskStartOrigin.parentAssisted]);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();
      expect(tasks.origins.last, TaskStartOrigin.childMode);
      expect(tasks.legacy, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'review screen uses family mode and does not turn an expired parent PIN into a child start',
    (tester) async {
      final reviews = ReviewStarts(
        ReviewRemote(() => DateTime.utc(2026, 11, 4)),
      );
      final container = await mount(
        tester,
        const ReviewSessionScreen(
          taskId: 'task-child',
          childId: 'child',
          familyId: 'family',
        ),
        Starts(),
        reviews: reviews,
      );
      container.read(parentAuthorizedUntilProvider.notifier).state = DateTime(
        2000,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('家长代开始复习'));
      await tester.pumpAndSettle();
      expect(reviews.origins, [TaskStartOrigin.parentAssisted]);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始复习'));
      await tester.pumpAndSettle();
      expect(reviews.origins.last, TaskStartOrigin.childMode);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'report exposes numerator and denominator and suppresses a rate when historical source is unknown',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final reports = StartReports();
      final container = await mount(
        tester,
        const LearningReportScreen(
          childId: 'child',
          familyId: 'family',
          childNickname: '小星',
        ),
        Starts(),
        reports: reports,
        scale: 2,
      );
      await tester.scrollUntilVisible(
        find.text('自主开始率：33%'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('2 / 6 项可执行任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
      reports.unknown = true;
      container.invalidate(
        learningReportProvider((
          childId: 'child',
          familyId: 'family',
          period: 'day',
          endDate: null,
        )),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('记录不完整，暂不计算'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('来源未知'), findsOneWidget);
      expect(find.text('自主开始率：33%'), findsNothing);
      container.read(parentModeProvider.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.textContaining('来源未知'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

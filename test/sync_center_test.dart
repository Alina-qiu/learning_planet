import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/app/theme.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/sync_diagnostics.dart';
import 'package:learning_planet/features/tasks/presentation/sync_center_screen.dart';
import 'package:learning_planet/features/tasks/presentation/task_sync_banner.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'offline_tasks_test.dart' show FakeTaskRemote;
import 'offline_images_test.dart' show ImageRemote;
import 'ocr_management_test.dart' show fixture;

class FaultRemote extends FakeTaskRemote {
  FaultRemote(super.now);
  String? failure, reason;
  @override
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command) async {
    if (failure != null) throw PostgrestException(message: failure!);
    if (reason != null) return {'outcome': 'conflict', 'reason': reason};
    return super.apply(command);
  }
}

class PausedStore extends OfflineStore {
  PausedStore() : super(NativeDatabase.memory());
  Completer<void>? entered, barrier;
  @override
  Future<List<Map<String, dynamic>>> commands(
    String owner, {
    String? childId,
  }) async {
    final rows = await super.commands(owner, childId: childId);
    if (entered != null && !entered!.isCompleted) entered!.complete();
    await barrier?.future;
    return rows;
  }
}

void main() {
  late OfflineStore store;
  late OfflineTaskRepository tasks;
  late OfflineQuestionMediaRepository images;
  late FaultRemote remote;
  late ImageRemote mediaRemote;
  String? owner, parent;
  bool resourcesClosed = false;
  final now = DateTime.utc(2026, 11, 4, 3);
  void make() {
    tasks = OfflineTaskRepository(
      store: store,
      remote: remote,
      live: const UnconfiguredTaskRepository(),
      accountId: () => owner,
      clock: () => now,
      autoSync: false,
    )..setForeground(false);
    images = OfflineQuestionMediaRepository(
      store: store,
      live: mediaRemote,
      accountId: () => owner,
      parentFamily: () => parent,
      autoSync: false,
    );
  }

  setUp(() async {
    resourcesClosed = false;
    owner = 'owner-private';
    parent = 'family';
    store = OfflineStore(NativeDatabase.memory());
    remote = FaultRemote(() => now)
      ..seed('child')
      ..seed('second');
    remote.tasks['task-child']!['title'] = '私密任务名称';
    mediaRemote = ImageRemote();
    make();
    await tasks.loadTasks('child');
    await tasks.loadTasks('second');
    await tasks.loadTasks('child');
    remote.online = false;
  });
  Future<void> close() async {
    if (resourcesClosed) return;
    await images.dispose();
    await tasks.dispose();
    await store.close();
    resourcesClosed = true;
  }

  tearDown(close);

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Drain real Drift IO and fake-zone provider continuations while the widget
    // test is still active; the generic tearDown runs outside FakeAsync.
    final closing = close();
    for (var i = 0; i < 100 && !resourcesClosed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(resourcesClosed, isTrue, reason: 'Repository disposal must finish');
    await closing;
  }

  Future<void> answer() => store.enqueue(owner!, 'child', {
    'command_id': 'answer-id',
    'task_id': 'task-child',
    'kind': 'review_answer',
    'occurred_at': now.toIso8601String(),
    'answer': 'private answer 42',
    'question_id': 'private-question-id',
  });
  Future<void> draft(String id, String child, {bool editing = false}) =>
      store.writeImageDraft(
        owner!,
        child,
        'family',
        id,
        {
          'consent': true,
          'config': {
            'ocr_confirmed': true,
            'prompt': 'secret question',
            'answers': ['42'],
          },
        },
        fixture(),
        fixture(),
        queue: !editing,
      );

  test(
    'durable diagnostics separate child queues, answers, cached server state and redact copies',
    () async {
      await tasks.start('task-child');
      await tasks.pause('task-child');
      await answer();
      await tasks.loadTasks('second');
      await tasks.start('task-second');
      final rows = await store.commands(owner!, childId: 'child');
      await store.retry(
        owner!,
        rows.first['command_id'] as String,
        3,
        now.add(const Duration(minutes: 1)),
        'secret server token',
      );
      await store.conflict(
        owner!,
        'task-child',
        'raw SQL secret answer and identity',
      );
      final before = await tasks.diagnostics('child');
      expect(before.conflicts, 1);
      expect(before.pending, 0);
      expect(before.answers, 1);
      expect(before.otherChildOperations, 1);
      expect(before.groups.single.operations.map((o) => o.label), [
        '开始',
        '暂停',
        '提交复习答案',
      ]);
      expect(before.groups.single.operations.first.attempts, 3);
      expect(before.groups.single.confirmed!.status.name, 'ready');
      expect(
        before.groups.single.operations.first.explanation,
        syncExplanation(null),
      );
      final summary = before.summary(
        phase: 'conflict',
        imageCounts: {'blocked': 2, 'secret key': 4},
      );
      for (final secret in [
        'private',
        'owner',
        'task-child',
        'secret',
        '私密任务名称',
        '42',
      ]) {
        expect(summary, isNot(contains(secret)));
      }
      expect(summary, contains('图片 blocked：2'));
      await tasks.dispose();
      await images.dispose();
      make();
      final resumed = await tasks.diagnostics('child');
      expect(resumed.conflicts, 1);
      expect(resumed.answers, 1);
      expect(remote.requests, isEmpty);
      owner = 'different-owner';
      tasks.scopeChanged();
      expect((await tasks.diagnostics('child')).groups, isEmpty);
      expect(await store.commands('owner-private'), hasLength(4));
    },
  );

  test(
    'raw server exceptions and arbitrary conflict reasons never enter new durable errors',
    () async {
      await tasks.start('task-child');
      remote.online = true;
      remote.failure = 'Database error: private answer 42 and token';
      await tasks.synchronize('child');
      expect(
        (await store.commands(owner!)).single['error'],
        syncExplanation(null),
      );
      await tasks.acceptServer('child', 'task-child');
      remote.failure = null;
      await tasks.start('task-child');
      remote.reason = 'raw private question SQL';
      await tasks.synchronize('child');
      expect(
        (await store.commands(owner!)).single['error'],
        syncExplanation(null),
      );
      expect(syncExplanation('尚未达到最低有效时长'), '尚未达到最低有效时长');
      expect(
        syncExplanation('尚未达到最低有效时长 private answer'),
        syncExplanation(null),
      );
    },
  );

  test(
    'accept server rejects mismatched child and preserves every pending command',
    () async {
      await tasks.start('task-child');
      await tasks.loadTasks('second');
      await tasks.start('task-second');
      remote.online = true;
      await expectLater(
        tasks.acceptServer('second', 'task-child'),
        throwsStateError,
      );
      expect(await store.commands(owner!), hasLength(2));
      expect(
        (await store.read(owner!, 'tasks:second'))!['tasks'][0]['child_id'],
        'second',
      );
      await tasks.acceptServer('child', 'task-child');
      expect((await store.commands(owner!)).single['child_id'], 'second');
      expect((await tasks.loadWallet('child')).coins, 100);
    },
  );

  test(
    'diagnostic read rejects a late account switch and deleted child',
    () async {
      await tasks.dispose();
      await images.dispose();
      await store.close();
      final paused = PausedStore();
      store = paused;
      make();
      paused.entered = Completer<void>();
      paused.barrier = Completer<void>();
      final read = tasks.diagnostics('child');
      final rejection = expectLater(read, throwsStateError);
      await paused.entered!.future;
      owner = 'other';
      paused.barrier!.complete();
      await rejection;
      paused.barrier = null;
      await store.removeChildData('child');
      await expectLater(tasks.diagnostics('child'), throwsStateError);
    },
  );

  test(
    'manual image retry waits for active upload and retries only the selected child',
    () async {
      await draft('first', 'child');
      await draft('blocked-child', 'child');
      await draft('blocked-other', 'second');
      await draft('editing', 'child', editing: true);
      await store.updateImageDraftState(owner!, 'blocked-child', 'blocked');
      await store.updateImageDraftState(owner!, 'blocked-other', 'blocked');
      mediaRemote.online = true;
      mediaRemote.entered = Completer<void>();
      mediaRemote.barrier = Completer<void>();
      final automatic = images.synchronize();
      await mediaRemote.entered!.future;
      final manual = images.synchronize(retryBlocked: true, childId: 'child');
      mediaRemote.barrier!.complete();
      await automatic;
      await manual;
      expect(mediaRemote.committed, {'first', 'blocked-child'});
      expect(
        (await store.imageDrafts(owner!)).map((r) => r['draft_id']).toSet(),
        {'blocked-other', 'editing'},
      );
    },
  );

  test(
    'queued manual upload retry cannot transfer to a newly logged in account',
    () async {
      await draft('first', 'child');
      mediaRemote.online = true;
      mediaRemote.entered = Completer<void>();
      mediaRemote.barrier = Completer<void>();
      final automatic = images.synchronize();
      await mediaRemote.entered!.future;
      final manual = images.synchronize(retryBlocked: true, childId: 'child');
      owner = 'new-owner';
      mediaRemote.barrier!.complete();
      await automatic;
      await manual;
      expect(mediaRemote.saves, 1);
      expect(mediaRemote.committed, isEmpty);
      expect(await store.imageDrafts('owner-private'), hasLength(1));
    },
  );

  final families = [
    const Family(
      id: 'family',
      name: '家',
      timezone: 'Asia/Shanghai',
      children: [
        ChildProfile(id: 'child', familyId: 'family', nickname: '小星', grade: 3),
      ],
    ),
  ];
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool authorized = false,
    bool banner = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(tasks),
          familiesProvider.overrideWith((ref) async => families),
          questionMediaRepositoryProvider.overrideWithValue(images),
          authorizationClockProvider.overrideWith(
            (ref) => Stream.value(DateTime.now()),
          ),
          parentModeProvider.overrideWith((ref) => authorized),
          parentFamilyIdProvider.overrideWith(
            (ref) => authorized ? 'family' : null,
          ),
          parentAuthorizedUntilProvider.overrideWith(
            (ref) => authorized
                ? DateTime.now().add(const Duration(minutes: 1))
                : null,
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: banner
              ? const Scaffold(body: TaskSyncBanner(childId: 'child'))
              : const SyncCenterScreen(childId: 'child'),
        ),
      ),
    );
    await settleIo(tester);
    return ProviderScope.containerOf(
      tester.element(find.byType(banner ? TaskSyncBanner : SyncCenterScreen)),
    );
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      220,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('refresh keeps a pending review group expanded', (tester) async {
    await tester.runAsync(() async {
      await tasks.start('task-child');
      await answer();
    });
    final container = await mount(tester);
    try {
      await reveal(tester, find.text('私密任务名称'));
      await tester.tap(find.text('私密任务名称'));
      await tester.pumpAndSettle();
      expect(find.text('查看复习记录'), findsOneWidget);
      container.invalidate(syncDiagnosticsProvider('child'));
      await settleIo(tester);
      expect(find.text('查看复习记录'), findsOneWidget);
      expect(find.text('云端最近确认：未开始'), findsOneWidget);
      owner = 'another-owner';
      tasks.scopeChanged();
      await settleIo(tester);
      expect(find.text('查看复习记录'), findsNothing);
      expect(find.text('登录账号已变化，请返回首页重新打开'), findsOneWidget);
    } finally {
      await finish(tester);
    }
  });

  testWidgets(
    'banner opens center; cancelled and failed adoption preserve durable records',
    (tester) async {
      await tester.runAsync(() async {
        await tasks.start('task-child');
        await store.conflict(owner!, 'task-child', '尚未达到最低有效时长');
      });
      await mount(tester, banner: true);
      await tester.tap(find.text('同步中心'));
      await settleIo(tester);
      await reveal(tester, find.text('私密任务名称'));
      await tester.tap(find.text('私密任务名称'));
      await tester.pumpAndSettle();
      expect(find.text('云端最近确认：未开始'), findsOneWidget);
      await reveal(tester, find.text('采用服务端状态'));
      await tester.tap(find.text('采用服务端状态'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 项未确认本机操作'), findsOneWidget);
      await tester.tap(find.text('保留本机记录'));
      await settleIo(tester);
      await tester.runAsync(
        () async => expect(await store.commands(owner!), hasLength(1)),
      );
      expect(find.text('采用服务端状态'), findsOneWidget);
      await reveal(tester, find.text('采用服务端状态'));
      await tester.tap(find.text('采用服务端状态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('联网核对并采用'));
      await settleIo(tester);
      await tester.runAsync(
        () async => expect(await store.commands(owner!), hasLength(1)),
      );
      expect(find.textContaining('未能完成核对'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'image queue is masked on PIN expiry and cannot leak into diagnostic clipboard',
    (tester) async {
      await tester.runAsync(() async {
        await draft('blocked', 'child');
        await store.updateImageDraftState(owner!, 'blocked', 'blocked');
        await answer();
      });
      final container = await mount(tester, authorized: true);
      await reveal(tester, find.text('上传未被接受：1 张'));
      expect(find.text('上传未被接受：1 张'), findsOneWidget);
      container.read(parentAuthorizedUntilProvider.notifier).state =
          DateTime.now().subtract(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('上传未被接受：1 张'), findsNothing);
      expect(find.text('private answer 42'), findsNothing);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await reveal(tester, find.text('复制诊断摘要'));
      await tester.tap(find.text('复制诊断摘要'));
      await settleIo(tester);
      expect(copied, contains('未确认复习答案：1'));
      for (final secret in [
        '图片',
        'private',
        '小星',
        'family',
        'owner',
        '私密任务名称',
      ]) {
        expect(copied, isNot(contains(secret)));
      }
      owner = 'new-owner';
      tasks.scopeChanged();
      await settleIo(tester);
      expect(find.text('登录账号已变化，请返回首页重新打开'), findsOneWidget);
      expect(find.text('小星 · 此设备'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'center fits narrow viewport with enlarged text and distinguishes drafts from uploads',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await draft('editing', 'child', editing: true);
      });
      await mount(tester, authorized: true, scale: 2);
      await reveal(tester, find.text('待校对（尚未同意上传）：1 张'));
      expect(tester.takeException(), isNull);
      final retry = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '重试当前孩子的上传'),
      );
      expect(retry.onPressed, isNull);
      await tester.runAsync(() async => expect(mediaRemote.saves, 0));
      await finish(tester);
    },
  );
}

import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/family_access_state.dart';
import 'package:learning_planet/features/tasks/data/task_notes.dart';
import 'package:learning_planet/features/tasks/presentation/task_note_screen.dart';
import 'package:learning_planet/features/tasks/presentation/task_management_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'support/mock_supabase.dart';
import 'task_preferences_test.dart' show AbandonTasks, task;

const noteScope = (taskId: 'task', childId: 'child', familyId: 'family');
Map<String, dynamic> noteValue([int version = 1, String body = '一起读了第三章']) => {
  'task_id': 'task',
  'child_id': 'child',
  'family_id': 'family',
  'body': body,
  'version': version,
  'updated_at': '2026-11-05T00:00:00Z',
};

class NoteRemote implements TaskNoteRemote {
  Map<String, dynamic> value = noteValue();
  Object? loadError;
  bool loseReply = false, badReceipt = false;
  Completer<void>? waiting;
  Completer<void> entered = Completer<void>();
  final calls = <(String, String, String)>[];
  final receipts = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> load(String taskId) async {
    if (!entered.isCompleted) entered.complete();
    await waiting?.future;
    if (loadError != null) throw loadError!;
    return value;
  }

  @override
  Future<Map<String, dynamic>> resolve(
    String taskId,
    String id,
    String body,
    String op,
  ) async {
    calls.add((id, body, op));
    if (!entered.isCompleted) entered.complete();
    await waiting?.future;
    if (!receipts.containsKey(id) && op != 'inspect') {
      if (op == 'submit') {
        value = noteValue((value['version'] as int) + 1, body);
      }
      receipts[id] = {
        'status': op == 'submit' ? 'applied' : 'abandoned',
        'applied_version': op == 'submit' ? value['version'] : null,
      };
    }
    if (loseReply) {
      loseReply = false;
      throw const SocketException('lost response');
    }
    return {
      'owner_id': badReceipt ? 'other' : 'owner',
      'request_id': id,
      ...?receipts[id],
      if (!receipts.containsKey(id)) 'status': 'unknown',
      'current': value,
    };
  }
}

class NotesHarness {
  NotesHarness([OfflineStore? db])
    : store = db ?? OfflineStore(NativeDatabase.memory()) {
    notes = TaskNotes(store: store, remote: remote, owner: () => owner);
  }
  final OfflineStore store;
  final remote = NoteRemote();
  late final TaskNotes notes;
  String? owner = 'owner';
}

Future<void> noteUi(WidgetTester tester, Future<void> Function() action) =>
    tester.runAsync(() async {
      await action();
      var quiet = 0;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 30));
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.text('正在保存本机草稿…').evaluate().isEmpty) {
          if (++quiet == 3) return;
        } else {
          quiet = 0;
        }
      }
      throw StateError('Note UI did not settle');
    });
void main() {
  test(
    'late save receipt cannot restore a deleted child and a denied save removes local notes',
    () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      await h.notes.edit(noteScope, '待保存');
      final request = await h.notes.prepare(noteScope);
      h.remote.waiting = Completer<void>();
      final saving = h.notes.resolve(noteScope, request.requestId!, 'submit');
      final rejected = expectLater(saving, throwsStateError);
      await h.remote.entered.future;
      await h.store.removeChildData('child');
      h.remote.waiting!.complete();
      await rejected;
      expect(await h.store.read('owner', 'task-note:task'), isNull);

      final api = MockSupabase(), store = OfflineStore(NativeDatabase.memory());
      addTearDown(api.client.dispose);
      addTearDown(store.close);
      api.handle = MockSupabase.denied;
      final notes = TaskNotes(
        store: store,
        remote: SupabaseTaskNoteRemote(api.client),
        owner: () => 'owner',
      );
      await notes.edit(noteScope, '权限撤销前的草稿');
      final original = await notes.prepare(noteScope);
      await expectLater(
        notes.resolve(noteScope, original.requestId!, 'submit'),
        throwsA(isA<PostgrestException>()),
      );
      expect(await store.read('owner', 'task-note:task'), isNull);
    },
  );

  testWidgets(
    'completed child task opens its own note editor and still permits a local draft',
    (tester) async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      final tasks = AbandonTasks()
        ..current = task(status: TaskStatus.completed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(tasks),
            taskNotesProvider.overrideWithValue(h.notes),
            activeParentFamilyProvider.overrideWithValue(null),
            familiesProvider.overrideWith((ref) async => []),
          ],
          child: const MaterialApp(
            home: TaskManagementScreen(
              childId: 'child',
              childNickname: '星宝',
              familyId: 'family',
              isParentMode: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await noteUi(tester, () async => tester.tap(find.byTooltip('补充说明')));
      await tester.pumpAndSettle();
      expect(find.byType(TaskNoteScreen), findsOneWidget);
      await noteUi(
        tester,
        () async => tester.enterText(find.byType(TextField), '完成后想补充的内容'),
      );
      expect(
        (await tester.runAsync(() => h.notes.load(noteScope)))!.draft,
        '完成后想补充的内容',
      );
      expect(tasks.current.status, TaskStatus.completed);
      expect(tasks.abandoned, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'offline draft persists and oversized input can be corrected without a remote write',
    (tester) async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      h.remote.loadError = const SocketException('offline');
      await noteUi(
        tester,
        () async => tester.pumpWidget(
          ProviderScope(
            overrides: [taskNotesProvider.overrideWithValue(h.notes)],
            child: const MaterialApp(
              home: TaskNoteScreen(scope: noteScope, title: '阅读'),
            ),
          ),
        ),
      );
      expect(find.textContaining('当前离线'), findsOneWidget);
      await noteUi(
        tester,
        () async => tester.enterText(find.byType(TextField), '🪐' * 501),
      );
      expect(find.textContaining('超出部分尚未保存'), findsOneWidget);
      await noteUi(
        tester,
        () async => tester.enterText(find.byType(TextField), '断网草稿'),
      );
      expect(
        (await tester.runAsync(() => h.notes.load(noteScope)))!.draft,
        '断网草稿',
      );
      expect(find.textContaining('当前离线'), findsOneWidget);
      expect(h.remote.calls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'file database restores cached shared note, draft and frozen request without publishing',
    () async {
      final dir = await Directory.systemTemp.createTemp('task-note-');
      final file = File('${dir.path}/notes.sqlite');
      final first = NotesHarness(OfflineStore(NativeDatabase(file)));
      await first.notes.load(noteScope);
      await first.notes.edit(noteScope, '  第四章有问题  ');
      final request = await first.notes.prepare(noteScope);
      await first.store.close();
      final next = NotesHarness(OfflineStore(NativeDatabase(file)));
      next.remote.loadError = const SocketException('offline');
      final restored = await next.notes.load(noteScope);
      expect(restored.offline, isTrue);
      expect(restored.body, '一起读了第三章');
      expect(restored.draft, '  第四章有问题  ');
      expect(restored.requestBody, '第四章有问题');
      expect(restored.requestId, request.requestId);
      expect(next.remote.calls, isEmpty);
      expect(next.notes.edit(noteScope, '覆盖'), throwsStateError);
      final result = await next.notes.resolve(
        noteScope,
        request.requestId!,
        'cancel',
      );
      expect(result.state.pending, isFalse);
      expect(result.state.draft, restored.draft);
      await next.notes.edit(noteScope, '可以重新修改');
      await next.store.close();
      await dir.delete(recursive: true);
    },
  );
  test(
    'lost response replays one original intent and shows newer shared text instead of overwriting',
    () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      await h.notes.load(noteScope);
      await h.notes.edit(noteScope, '原说明');
      final pending = await h.notes.prepare(noteScope);
      h.remote.loseReply = true;
      await expectLater(
        h.notes.resolve(noteScope, pending.requestId!, 'submit'),
        throwsA(isA<SocketException>()),
      );
      h.remote.value = noteValue(3, '家人更新的说明');
      final replay = await h.notes.resolve(
        noteScope,
        pending.requestId!,
        'submit',
      );
      expect(replay.appliedVersion, 2);
      expect(replay.state.body, '家人更新的说明');
      expect(replay.state.draft, isNull);
      expect(replay.state.pending, isFalse);
      expect(h.remote.receipts.length, 1);
      expect(h.remote.calls.first, h.remote.calls.last);
    },
  );
  test(
    'inspect never publishes and a cancellation keeps the editable local draft',
    () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      h.remote.loadError = const SocketException('offline');
      expect((await h.notes.load(noteScope)).current, isNull);
      await h.notes.edit(noteScope, '离线新草稿');
      final request = await h.notes.prepare(noteScope);
      expect((await h.notes.prepare(noteScope)).requestId, request.requestId);
      final unknown = await h.notes.resolve(
        noteScope,
        request.requestId!,
        'inspect',
      );
      expect(unknown.status, 'unknown');
      expect(unknown.state.pending, isTrue);
      final cancel = await h.notes.resolve(
        noteScope,
        request.requestId!,
        'cancel',
      );
      expect(cancel.status, 'abandoned');
      expect(cancel.state.draft, '离线新草稿');
      expect(h.remote.value['version'], 1);
    },
  );
  for (final kind in ['owner', 'child', 'account', 'membership', 'disposed']) {
    test('late note response cannot restore data after $kind change', () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      h.remote.waiting = Completer<void>();
      final loading = h.notes.load(noteScope);
      final rejected = expectLater(loading, throwsStateError);
      await h.remote.entered.future;
      switch (kind) {
        case 'owner':
          h.owner = 'other';
        case 'disposed':
          h.notes.dispose();
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
      }
      h.remote.waiting!.complete();
      await rejected;
      expect(await h.store.read('owner', 'task-note:task'), isNull);
    });
  }
  test(
    'child and membership cleanup remove persisted drafts and pending note requests',
    () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      await h.notes.edit(noteScope, '私有草稿');
      await h.notes.prepare(noteScope);
      await h.store.removeChildData('child');
      expect(await h.store.read('owner', 'task-note:task'), isNull);
      await expectLater(h.notes.load(noteScope), throwsStateError);
      final other = (
        taskId: 'other-task',
        childId: 'other-child',
        familyId: 'other-family',
      );
      await h.notes.edit(other, '其他家庭草稿');
      await h.store.applyFamilyAccess('owner', [
        FamilyAccessState(
          familyId: 'other-family',
          version: 2,
          active: false,
          lastRevokedVersion: 2,
          childIds: {'other-child'},
        ),
      ]);
      expect(await h.store.read('owner', 'task-note:other-task'), isNull);
    },
  );
  test(
    'permission failures purge cached content; malformed data and foreign receipts cannot replace drafts',
    () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      await h.notes.load(noteScope);
      await h.notes.edit(noteScope, '保留我');
      h.remote.value = {...noteValue(), 'child_id': 'foreign'};
      await expectLater(h.notes.load(noteScope), throwsFormatException);
      h.remote.value = noteValue();
      final request = await h.notes.prepare(noteScope);
      h.remote.badReceipt = true;
      await expectLater(
        h.notes.resolve(noteScope, request.requestId!, 'submit'),
        throwsFormatException,
      );
      expect((await h.notes.load(noteScope)).requestId, request.requestId);
      h.remote.loadError = const PostgrestException(
        message: 'private',
        code: '42501',
      );
      await expectLater(
        h.notes.load(noteScope),
        throwsA(isA<PostgrestException>()),
      );
      expect(await h.store.read('owner', 'task-note:task'), isNull);
    },
  );
  test(
    'Unicode limit counts code points and a stale server read cannot regress cached versions',
    () async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      h.remote.value = noteValue(5, '新内容');
      await h.notes.load(noteScope);
      h.remote.value = noteValue(2, '旧内容');
      expect((await h.notes.load(noteScope)).body, '新内容');
      await h.notes.edit(noteScope, '🪐' * 500);
      expect(() => h.notes.edit(noteScope, '🪐' * 501), throwsArgumentError);
      final request = await h.notes.prepare(noteScope);
      expect(request.requestBody!.runes.length, 500);
      expect(
        () => h.notes.resolve(noteScope, request.requestId!, 'invalid'),
        throwsArgumentError,
      );
      await expectLater(
        h.notes.resolve(noteScope, 'different', 'inspect'),
        throwsStateError,
      );
      h.owner = null;
      expect(() => h.notes.load(noteScope), throwsStateError);
    },
  );
  test(
    'Supabase bridge sends exact scope, frozen text, UUID and operation',
    () async {
      final api = MockSupabase();
      addTearDown(api.client.dispose);
      api.handle = (request) => MockSupabase.json(request, noteValue());
      final remote = SupabaseTaskNoteRemote(api.client);
      await remote.load('task');
      await remote.resolve('task', 'id', '原说明', 'inspect');
      expect(api.calls.first.url.path, endsWith('/rpc/task_note'));
      expect(MockSupabase.body(api.calls.last), {
        'target_task_id': 'task',
        'request_id': 'id',
        'note_text': '原说明',
        'operation': 'inspect',
      });
    },
  );
  testWidgets(
    'draft autosaves; pending requests lock edits and are resolved explicitly at large text size',
    (tester) async {
      final h = NotesHarness();
      addTearDown(h.store.close);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await noteUi(
        tester,
        () async => tester.pumpWidget(
          ProviderScope(
            overrides: [taskNotesProvider.overrideWithValue(h.notes)],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const TaskNoteScreen(scope: noteScope, title: '阅读任务'),
            ),
          ),
        ),
      );
      await noteUi(
        tester,
        () async => tester.enterText(find.byType(TextField), '我想讨论这一段'),
      );
      expect(
        (await tester.runAsync(() => h.notes.load(noteScope)))!.draft,
        '我想讨论这一段',
      );
      h.remote.loseReply = true;
      tester.testTextInput.hide();
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('共享说明'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await noteUi(tester, () async => tester.tap(find.text('共享说明')));
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      await tester.scrollUntilVisible(
        find.text('核对保存结果'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await noteUi(tester, () async => tester.tap(find.text('核对保存结果')));
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(h.remote.receipts.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_confidence.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'offline_review_test.dart' show LiveReview;
import 'review_auto_completion_test.dart' show AutoReviewRemote;
import 'review_module_test.dart' show FakeReviewRepository;
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

class _Offline {
  _Offline(this.store) {
    repositories();
  }
  OfflineStore store;
  final now = DateTime.utc(2026, 9, 16, 3);
  late final remote = AutoReviewRemote(() => now);
  late OfflineTaskRepository tasks;
  late CachedReviewRepository reviews;
  void repositories() {
    tasks = OfflineTaskRepository(
      store: store,
      remote: remote,
      live: const UnconfiguredTaskRepository(),
      accountId: () => 'parent',
      clock: () => now,
      autoSync: false,
    )..setForeground(false);
    reviews = CachedReviewRepository(
      LiveReview(remote),
      store,
      () => 'parent',
      tasks: tasks,
    );
  }

  Future<void> cache() async {
    remote.online = true;
    await tasks.loadTasks('child');
    await reviews.task('task-child');
    remote.online = false;
    await reviews.transition('task-child', 'start');
  }

  Future<Map<String, dynamic>> answer(ReviewConfidence? confidence) =>
      reviews.answer(
        'task-child',
        'question',
        '4',
        'confidence-command',
        confidence: confidence,
      );
  Future<void> close() async {
    await tasks.dispose();
    await store.close();
  }
}

Future<void> _screen(
  WidgetTester tester,
  ReviewRepository repository, {
  ValueNotifier<String>? task,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reviewRepositoryProvider.overrideWithValue(repository),
        taskRepositoryProvider.overrideWithValue(
          const UnconfiguredTaskRepository(),
        ),
        feedbackPreferencesStoreProvider.overrideWithValue(
          MemoryFeedbackPreferences(),
        ),
      ],
      child: MaterialApp(
        home: task == null
            ? const ReviewSessionScreen(taskId: 'task', childId: 'child')
            : ValueListenableBuilder<String>(
                valueListenable: task,
                builder: (_, id, _) =>
                    ReviewSessionScreen(taskId: id, childId: 'child'),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'unknown legacy or OCR-like values never become a child self-assessment',
    () {
      for (final value in [null, 0, 4, -1, .99, 1.0, '1', true]) {
        expect(ReviewConfidence.fromWire(value), isNull);
      }
      expect(ReviewConfidence.fromWire(1), ReviewConfidence.unsure);
      expect(ReviewConfidence.fromWire(2), ReviewConfidence.somewhat);
      expect(ReviewConfidence.fromWire(3), ReviewConfidence.confident);
    },
  );

  test(
    'real Supabase RPC serialization selects the five-argument contract and keeps legacy calls compatible',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://project.example.test',
        'public-test-key',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/submit_review_answer');
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            '{"task":{},"items":[]}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      try {
        final repository = SupabaseReviewRepository(client);
        await repository.answer(
          'task',
          'question',
          '4',
          'key',
          confidence: ReviewConfidence.unsure,
        );
        await repository.answer('task', 'question', '4', 'old-key');
        expect(requests.first, {
          'target_task_id': 'task',
          'target_question_id': 'question',
          'answer': '4',
          'command_id': 'key',
          'answer_confidence': 1,
        });
        expect(requests.last.containsKey('answer_confidence'), false);
      } finally {
        await client.dispose();
      }
    },
  );

  testWidgets(
    'a child chooses confidence before submission and sees the recorded value after grading',
    (tester) async {
      final repository = FakeReviewRepository()..status = 'in_progress';
      await _screen(tester, repository);
      await tester.enterText(find.byType(TextField), 'yin2 hang2');
      await _tap(tester, '提交答案');
      expect(repository.submitted, isNull);
      expect(find.textContaining('请选择这次作答的把握程度'), findsOneWidget);
      await _tap(tester, '不太确定');
      await _tap(tester, '提交答案');
      expect(repository.submittedConfidence, ReviewConfidence.unsure);
      expect(repository.result, true);
      expect(find.text('作答把握：不太确定'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old graded answers show unknown instead of inventing a confidence level',
    (tester) async {
      final repository = FakeReviewRepository()
        ..status = 'completed'
        ..result = true
        ..submitted = 'yin2 hang2';
      await _screen(tester, repository);
      expect(find.text('作答把握：未记录'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'another task with the same question requires a fresh answer and confidence',
    (tester) async {
      final repository = FakeReviewRepository()..status = 'in_progress';
      final id = ValueNotifier('first-task');
      await _screen(tester, repository, task: id);
      await tester.enterText(find.byType(TextField), 'yin2 hang2');
      await _tap(tester, '很有把握');
      id.value = 'next-task';
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .every((chip) => !chip.selected),
        true,
      );
      await tester.pumpWidget(const SizedBox());
      id.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'offline self-assessment and final-answer completion survive an actual SQLite file reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'planet-review-confidence-',
      );
      final path = File('${directory.path}/review.sqlite');
      final f = _Offline(OfflineStore(NativeDatabase(path)));
      try {
        await f.cache();
        final pending = await f.answer(ReviewConfidence.confident);
        expect(
          (pending['items'] as List).single['pending_answer_confidence'],
          3,
        );
        expect((pending['items'] as List).single['result'], isNull);
        expect(pending['local_completion'], true);
        final ids = (await f.store.commands(
          'parent',
        )).map((row) => row['command_id']).toList();
        expect((await f.tasks.loadWallet('child')).coins, 100);
        await f.close();
        f.store = OfflineStore(NativeDatabase(path));
        f.repositories();
        final restored = await f.reviews.task('task-child');
        expect(
          (restored['items'] as List).single['pending_answer_confidence'],
          3,
        );
        expect(
          (await f.store.commands('parent')).map((row) => row['command_id']),
          ids,
        );
        f.remote.online = true;
        await f.tasks.synchronize('child');
        expect(await f.store.commands('parent'), isEmpty);
        expect(
          (await f.reviews.task('task-child'))['items'][0]['answer_confidence'],
          3,
        );
        expect(f.remote.awards, 1);
      } finally {
        await f.close();
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await directory.resolveSymbolicLinks();
        if (!target.startsWith(
          '$root${Platform.pathSeparator}planet-review-confidence-',
        )) {
          throw StateError('Unexpected fixture path');
        }
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'a pending answer cannot have its confidence changed or receive another completion',
    () async {
      final f = _Offline(OfflineStore(NativeDatabase.memory()));
      try {
        await f.cache();
        await f.answer(ReviewConfidence.unsure);
        final before = await f.store.commands('parent');
        await f.answer(ReviewConfidence.unsure);
        await f.answer(null); // Legacy retry reads the original pending value.
        await expectLater(
          f.answer(ReviewConfidence.confident),
          throwsStateError,
        );
        expect(await f.store.commands('parent'), before);
        expect(
          (await f.reviews.task(
            'task-child',
          ))['items'][0]['pending_answer_confidence'],
          1,
        );
        await expectLater(
          f.tasks.queueReview(
            'task-child',
            'pause',
            confidence: ReviewConfidence.unsure,
          ),
          throwsArgumentError,
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'lost settlement replies retry the same confidence and UUID without an extra award',
    () async {
      final f = _Offline(OfflineStore(NativeDatabase.memory()));
      try {
        await f.cache();
        await f.answer(ReviewConfidence.somewhat);
        f.remote.online = true;
        f.remote.loseFinalReply = true;
        await f.tasks.synchronize('child');
        expect(f.remote.awards, 1);
        expect((await f.tasks.loadWallet('child')).coins, 100);
        await f.tasks.synchronize('child');
        final answers = f.remote.requests
            .where((row) => row['kind'] == 'review_answer')
            .toList();
        expect(answers.map((row) => row['answer_confidence']), [2, 2]);
        expect(answers.map((row) => row['command_id']).toSet(), {
          'confidence-command',
        });
        expect(await f.store.commands('parent'), isEmpty);
        expect(f.remote.awards, 1);
      } finally {
        await f.close();
      }
    },
  );
}

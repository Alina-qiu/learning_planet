import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/growth/data/feedback_preferences.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task_sync_state.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';
import 'package:learning_planet/features/wrong_questions/presentation/review_session_screen.dart';
import 'review_module_test.dart' show FakeReviewRepository;
import 'task_feedback_test.dart' show MemoryFeedbackPreferences;

class DeferredReview extends FakeReviewRepository {
  Completer<void>? wait;
  int reads = 0;
  @override
  Future<Map<String, dynamic>> task(String taskId) async {
    reads++;
    await wait?.future;
    return super.task(taskId);
  }
}

void main() {
  testWidgets('background sync preserves the focused answer and confidence', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sync = StreamController<TaskSyncState>.broadcast();
    final repository = DeferredReview()..status = 'in_progress';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewRepositoryProvider.overrideWithValue(repository),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          taskSyncStateProvider.overrideWith((ref) => sync.stream),
          feedbackPreferencesStoreProvider.overrideWithValue(
            MemoryFeedbackPreferences(),
          ),
        ],
        child: const MaterialApp(
          home: ReviewSessionScreen(taskId: 'task', childId: 'child'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('有点把握'));
    await tester.enterText(find.byType(TextField), 'yin2');
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    final reads = repository.reads;
    repository.wait = Completer<void>();
    sync.add(const TaskSyncState(phase: TaskSyncPhase.syncing, revision: 1));
    await tester.pump();
    await tester.pump();
    expect(repository.reads, greaterThan(reads));
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode,
      same(editable.focusNode),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(editable.controller.text, 'yin2');
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '有点把握'))
          .selected,
      isTrue,
    );
    repository.wait!.complete();
    await tester.pumpAndSettle();
    expect(editable.focusNode.hasFocus, isTrue);
    expect(editable.controller.text, 'yin2');
    await tester.pumpWidget(const SizedBox());
    await sync.close();
  });

  test(
    'changing the repository still invalidates the previous task data',
    () async {
      final first = DeferredReview()..status = 'in_progress';
      final second = DeferredReview()..wait = Completer<void>();
      final source = StateProvider<ReviewRepository>((ref) => first);
      final container = ProviderContainer(
        overrides: [
          reviewRepositoryProvider.overrideWith((ref) => ref.watch(source)),
          taskSyncStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      final subscription = container.listen(
        reviewTaskProvider('task'),
        (_, _) {},
      );
      try {
        await container.read(reviewTaskProvider('task').future);
        container.read(source.notifier).state = second;
        final loading = container.read(reviewTaskProvider('task'));
        expect(loading.isReloading, isTrue);
        expect(
          loading.when(
            data: (_) => 'old task',
            loading: () => 'loading',
            error: (_, _) => 'error',
          ),
          'loading',
        );
        second.wait!.complete();
        expect(
          (await container.read(
            reviewTaskProvider('task').future,
          ))['task']['status'],
          'ready',
        );
      } finally {
        subscription.close();
        container.dispose();
      }
    },
  );
}

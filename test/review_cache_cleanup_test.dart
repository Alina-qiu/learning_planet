import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/offline/offline_store.dart';

void main() {
  test(
    'selected question cleanup preserves other review chains and original-only cleanup preserves all answers',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      for (final task in ['affected', 'unrelated', 'sibling']) {
        final child = task == 'sibling' ? 'sibling' : 'child';
        await store.write('parent', 'review-task:$task', {
          'task': {'id': task, 'child_id': child},
          'items': [
            {
              'wrong_question_id': task == 'unrelated'
                  ? 'other-question'
                  : 'selected',
            },
          ],
        });
        await store.enqueue('parent', child, {
          'task_id': task,
          'kind': 'review_start',
          'command_id': 'start-$task',
        });
        await store.enqueue('parent', child, {
          'task_id': task,
          'kind': 'review_answer',
          'command_id': 'answer-$task',
          'question_id': task == 'unrelated' ? 'other-question' : 'selected',
          'answer': 'private',
        });
      }
      await store.removeReviewCache(
        'parent',
        childId: 'child',
        questionIds: {'selected'},
        discardCommands: false,
      );
      expect((await store.commands('parent')).length, 6);
      expect(await store.read('parent', 'review-task:affected'), isNotNull);
      await store.removeReviewCache(
        'parent',
        childId: 'child',
        questionIds: {'selected'},
      );
      expect(
        (await store.commands('parent')).map((row) => row['task_id']).toSet(),
        {'unrelated', 'sibling'},
      );
      expect(await store.read('parent', 'review-task:affected'), isNull);
      expect(await store.read('parent', 'review-task:unrelated'), isNotNull);
      expect(await store.read('parent', 'review-task:sibling'), isNotNull);
    },
  );
  test(
    'cleanup rejects late review writes without touching other accounts',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final generation = store.reviewGeneration('parent');
      await store.write('parent', 'review-task:old', {'prompt': 'private'});
      await store.write('parent', 'wallet', {'coins': 10});
      await store.write('other', 'review-task:old', {'prompt': 'other'});
      await store.removeReviewCache('parent');
      await expectLater(
        store.writeReviewCache('parent', 'review-task:old', {
          'prompt': 'late',
        }, generation),
        throwsStateError,
      );
      expect(await store.read('parent', 'review-task:old'), isNull);
      expect(await store.read('parent', 'wallet'), {'coins': 10});
      expect(await store.read('other', 'review-task:old'), {'prompt': 'other'});
      await store.writeReviewCache('parent', 'review-task:new', {
        'prompt': 'new',
      }, store.reviewGeneration('parent'));
      expect(await store.read('parent', 'review-task:new'), {'prompt': 'new'});
    },
  );
}

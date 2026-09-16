import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/wrong_questions/domain/review_scheduler.dart';

void main() {
  const scheduler = ReviewScheduler(maxQuestionsPerDay: 2);

  test('没有到期错题时不生成空任务', () {
    final task = scheduler.buildDailyTask(
      familyDate: DateTime(2026, 9, 13),
      candidates: [
        ReviewCandidate(
          id: 'future',
          reviewDueAt: DateTime(2026, 9, 14),
          wrongCount: 1,
        ),
      ],
    );
    expect(task, isNull);
  });

  test('按到期时间排序并限制每日题量', () {
    final task = scheduler.buildDailyTask(
      familyDate: DateTime(2026, 9, 13),
      candidates: [
        ReviewCandidate(
          id: 'b',
          reviewDueAt: DateTime(2026, 9, 13, 8),
          wrongCount: 1,
        ),
        ReviewCandidate(
          id: 'a',
          reviewDueAt: DateTime(2026, 9, 12),
          wrongCount: 1,
        ),
        ReviewCandidate(
          id: 'c',
          reviewDueAt: DateTime(2026, 9, 11),
          wrongCount: 2,
        ),
      ],
    );
    expect(task?.questionIds, ['c', 'a']);
  });
}

class ReviewCandidate {
  const ReviewCandidate({
    required this.id,
    required this.reviewDueAt,
    required this.wrongCount,
  });

  final String id;
  final DateTime reviewDueAt;
  final int wrongCount;
}

class DailyReviewTaskDraft {
  const DailyReviewTaskDraft({required this.date, required this.questionIds});

  final DateTime date;
  final List<String> questionIds;
}

class ReviewScheduler {
  const ReviewScheduler({this.maxQuestionsPerDay = 10});

  final int maxQuestionsPerDay;

  DailyReviewTaskDraft? buildDailyTask({
    required DateTime familyDate,
    required Iterable<ReviewCandidate> candidates,
  }) {
    final dayStart = DateTime(
      familyDate.year,
      familyDate.month,
      familyDate.day,
    );
    final dayEnd = dayStart.add(const Duration(days: 1));
    final due =
        candidates.where((item) => item.reviewDueAt.isBefore(dayEnd)).toList()
          ..sort((a, b) {
            final dueOrder = a.reviewDueAt.compareTo(b.reviewDueAt);
            return dueOrder != 0
                ? dueOrder
                : b.wrongCount != a.wrongCount
                ? b.wrongCount.compareTo(a.wrongCount)
                : a.id.compareTo(b.id);
          });

    if (due.isEmpty) return null;
    return DailyReviewTaskDraft(
      date: dayStart,
      questionIds: due
          .take(
            maxQuestionsPerDay < 1
                ? 1
                : maxQuestionsPerDay > 10
                ? 10
                : maxQuestionsPerDay,
          )
          .map((item) => item.id)
          .toList(),
    );
  }
}

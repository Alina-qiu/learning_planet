class ReviewProgress {
  const ReviewProgress({
    required this.step,
    required this.mastered,
    required this.nextDate,
  });
  final int step;
  final bool mastered;
  final DateTime? nextDate;
  static const intervals = [1, 3, 7, 30];
  static ReviewProgress after({
    required int step,
    required bool correct,
    required DateTime familyDate,
  }) {
    if (step < 0 || step > 4) throw RangeError.range(step, 0, 4);
    final day = DateTime(familyDate.year, familyDate.month, familyDate.day);
    if (correct && step == 4) {
      return const ReviewProgress(step: 4, mastered: true, nextDate: null);
    }
    return ReviewProgress(
      step: correct ? step + 1 : 0,
      mastered: false,
      nextDate: day.add(Duration(days: correct ? intervals[step] : 1)),
    );
  }
}

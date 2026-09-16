enum TaskSource { parentTemplate, longPlan, automaticWrongQuestionReview }

enum TaskStatus { scheduled, ready, inProgress, paused, completed, skipped }

class LearningTask {
  const LearningTask({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.coinReward,
    required this.xpReward,
    required this.source,
    this.status = TaskStatus.ready,
  });

  final String id;
  final String title;
  final String subtitle;
  final int coinReward;
  final int xpReward;
  final TaskSource source;
  final TaskStatus status;

  LearningTask copyWith({TaskStatus? status}) => LearningTask(
    id: id,
    title: title,
    subtitle: subtitle,
    coinReward: coinReward,
    xpReward: xpReward,
    source: source,
    status: status ?? this.status,
  );
}

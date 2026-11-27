enum TaskPriority {
  mandatory('required', '必须'),
  recommended('recommended', '推荐'),
  challenge('challenge', '挑战');

  const TaskPriority(this.value, this.label);
  final String value, label;
  static TaskPriority parse(String? value) => TaskPriority.values.firstWhere(
    (priority) => priority.value == value,
    orElse: () => TaskPriority.recommended,
  );
}

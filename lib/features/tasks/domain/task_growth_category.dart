enum TaskGrowthCategory {
  general('未分类'),
  learning('学习'),
  exploration('探索'),
  responsibility('责任');

  const TaskGrowthCategory(this.label);
  final String label;
  static TaskGrowthCategory parse(String? value) => values.firstWhere(
    (category) => category.name == value,
    orElse: () => general,
  );
}

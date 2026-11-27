class TaskRewardPreset {
  const TaskRewardPreset(
    this.label,
    this.title,
    this.minutes,
    this.coins,
    this.xp,
  );
  final String label, title;
  final int minutes, coins, xp;
  Map<String, dynamic> get defaults => {
    'title': title,
    'expected_minutes': minutes,
    'coin_reward': coins,
    'xp_reward': xp,
    'minimum_seconds': 0,
  };
}

const taskRewardPresets = {
  'study10': TaskRewardPreset('学习10分钟 · 15金币 / 12XP', '学习10分钟', 10, 15, 12),
  'study20': TaskRewardPreset('学习20分钟 · 25金币 / 20XP', '学习20分钟', 20, 25, 20),
  'reading20': TaskRewardPreset('阅读20分钟 · 25金币 / 20XP', '阅读20分钟', 20, 25, 20),
  'habit': TaskRewardPreset('生活习惯 · 10金币 / 8XP', '生活习惯练习', 10, 10, 8),
};

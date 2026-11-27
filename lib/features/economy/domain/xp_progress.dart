class XpProgress {
  const XpProgress(this.total);
  final int total;
  int get level {
    var remaining = total < 0 ? 0 : total;
    var level = 1;
    while (level < 50 && remaining >= level * 100) {
      remaining -= level * 100;
      level++;
    }
    return level;
  }

  int get floorXp => (level - 1) * level * 50;
  int get earnedInLevel => level == 50 ? 0 : total - floorXp;
  int get nextRequired => level == 50 ? 0 : level * 100;
  double get fraction =>
      level == 50 ? 1 : (earnedInLevel / nextRequired).clamp(0, 1);
}

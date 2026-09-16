enum ScheduleRecurrence { once, daily, weekly, custom }

DateTime parseScheduleDate(String value) {
  final date = DateTime.parse(value);
  if (scheduleDate(date) != value) {
    throw const FormatException('日期格式为 YYYY-MM-DD，且必须真实存在');
  }
  return date;
}

String scheduleDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

class ScheduleConfig {
  const ScheduleConfig({
    required this.title,
    required this.startsOn,
    required this.endsOn,
    required this.recurrence,
    required this.startTime,
    required this.dueTime,
    this.weekdays = const [],
    this.customDates = const [],
    this.coins = 20,
    this.xp = 20,
    this.minimumMinutes = 0,
    this.longPlan = false,
    this.minimumRate = .8,
    this.bonusCoins = 100,
    this.bonusXp = 100,
    this.stages = const [],
    this.tiers = const [],
  });
  final String title;
  final DateTime startsOn, endsOn;
  final ScheduleRecurrence recurrence;
  final String startTime, dueTime;
  final List<int> weekdays;
  final List<DateTime> customDates;
  final int coins, xp, minimumMinutes, bonusCoins, bonusXp;
  final bool longPlan;
  final double minimumRate;
  final List<Map<String, int>> stages;
  final List<Map<String, num>> tiers;

  Map<String, dynamic> toJson() {
    final timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
    if (title.trim().isEmpty ||
        endsOn.isBefore(startsOn) ||
        endsOn.difference(startsOn).inDays > 366 ||
        !timePattern.hasMatch(startTime) ||
        !timePattern.hasMatch(dueTime) ||
        dueTime.compareTo(startTime) <= 0 ||
        [coins, xp, minimumMinutes, bonusCoins, bonusXp].any((v) => v < 0)) {
      throw const FormatException('请检查名称、日期、时间和非负奖励');
    }
    if (recurrence == ScheduleRecurrence.weekly &&
        (weekdays.isEmpty || weekdays.any((d) => d < 1 || d > 7))) {
      throw const FormatException('至少选择一个星期');
    }
    if (recurrence == ScheduleRecurrence.custom &&
        (customDates.isEmpty ||
            customDates.any(
              (d) => d.isBefore(startsOn) || d.isAfter(endsOn),
            ))) {
      throw const FormatException('自定义日期必须在计划范围内');
    }
    if (longPlan &&
        (recurrence == ScheduleRecurrence.once ||
            minimumRate <= 0 ||
            minimumRate > 1)) {
      throw const FormatException('长期计划需周期重复，达标率为 1 至 100%');
    }
    if ((!longPlan && (stages.isNotEmpty || tiers.isNotEmpty)) ||
        stages.any(
          (s) =>
              (s['completed_count'] ?? 0) <= 0 ||
              (s['coins'] ?? -1) < 0 ||
              (s['xp'] ?? -1) < 0,
        ) ||
        stages.map((s) => s['completed_count']).toSet().length !=
            stages.length ||
        tiers.any(
          (t) =>
              (t['minimum_rate'] ?? 0) <= minimumRate ||
              (t['minimum_rate'] ?? 2) > 1 ||
              (t['coins'] ?? -1) < 0 ||
              (t['xp'] ?? -1) < 0,
        ) ||
        tiers.map((t) => t['minimum_rate']).toSet().length != tiers.length) {
      throw const FormatException('请检查阶段奖励和终奖档位，阈值不得重复');
    }
    return {
      'title': title.trim(),
      'starts_on': scheduleDate(startsOn),
      'ends_on': scheduleDate(endsOn),
      'recurrence': recurrence.name,
      'start_time': startTime,
      'due_time': dueTime,
      'coins': coins,
      'xp': xp,
      'minimum_seconds': minimumMinutes * 60,
      'rule': {
        'date': scheduleDate(startsOn),
        'weekdays': weekdays.toSet().toList()..sort(),
        'dates': customDates.map(scheduleDate).toSet().toList()..sort(),
      },
      'long_plan': longPlan,
      'minimum_rate': minimumRate,
      'bonus_coins': bonusCoins,
      'bonus_xp': bonusXp,
      'stages': stages,
      'tiers': tiers,
    };
  }
}

class OverviewDay {
  const OverviewDay(this.day, this.expected, this.completed);
  final String day;
  final int expected, completed;
  double? get rate => expected == 0 ? null : completed / expected;
}

class OverviewChild {
  const OverviewChild({
    required this.id,
    required this.nickname,
    required this.days,
    required this.requested,
    required this.approved,
    required this.awaitingExpiry,
    required this.pendingAwards,
    required this.pendingCoins,
  });
  final String id, nickname;
  final List<OverviewDay> days;
  final int requested, approved, awaitingExpiry, pendingAwards, pendingCoins;
  OverviewDay get today => days.last;
  int get weekExpected => days.fold(0, (total, day) => total + day.expected);
  int get weekCompleted => days.fold(0, (total, day) => total + day.completed);
}

class FamilyOverview {
  FamilyOverview.fromJson(Map<String, dynamic> data, String expectedFamily) {
    familyId = data['family_id'] as String;
    if (familyId != expectedFamily) throw const FormatException('家庭范围不匹配');
    name = data['family_name'] as String;
    timezone = data['timezone'] as String;
    today = data['today'] as String;
    generatedAt = DateTime.parse(data['generated_at'] as String);
    final date = DateTime.parse('${today}T00:00:00Z');
    final ids = <String>{};
    children = List.unmodifiable(
      (data['children'] as List).map((value) {
        final row = (value as Map).cast<String, dynamic>();
        final id = row['child_id'] as String;
        if (!ids.add(id)) throw const FormatException('孩子重复');
        final rawDays = row['days'] as List;
        if (rawDays.length != 7) throw const FormatException('日期范围不完整');
        final days = <OverviewDay>[];
        for (var i = 0; i < 7; i++) {
          final day = (rawDays[i] as Map).cast<String, dynamic>();
          final expectedDay = date
              .subtract(Duration(days: 6 - i))
              .toIso8601String()
              .substring(0, 10);
          final expected = _count(day['expected']),
              completed = _count(day['completed']);
          if (day['day'] != expectedDay || completed > expected) {
            throw const FormatException('任务统计不正确');
          }
          days.add(OverviewDay(expectedDay, expected, completed));
        }
        return OverviewChild(
          id: id,
          nickname: row['nickname'] as String,
          days: List.unmodifiable(days),
          requested: _count(row['requested']),
          approved: _count(row['approved']),
          awaitingExpiry: _count(row['awaiting_expiry']),
          pendingAwards: _count(row['pending_awards']),
          pendingCoins: _count(row['pending_coins']),
        );
      }),
    );
  }
  late final String familyId, name, timezone, today;
  late final DateTime generatedAt;
  late final List<OverviewChild> children;

  List<OverviewDay> trend(Iterable<OverviewChild> selected) => [
    for (var i = 0; i < 7; i++)
      OverviewDay(
        DateTime.parse(
          '${today}T00:00:00Z',
        ).subtract(Duration(days: 6 - i)).toIso8601String().substring(0, 10),
        selected.fold(0, (sum, child) => sum + child.days[i].expected),
        selected.fold(0, (sum, child) => sum + child.days[i].completed),
      ),
  ];

  static int _count(Object? value) {
    if (value is! int || value < 0) throw const FormatException('统计值不正确');
    return value;
  }
}

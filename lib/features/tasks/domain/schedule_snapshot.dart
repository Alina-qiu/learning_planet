class ScheduleSnapshot {
  const ScheduleSnapshot({
    required this.childId,
    required this.familyId,
    required this.fetchedAt,
    required this.familyToday,
    required this.items,
    this.offline = false,
  });
  final String childId, familyId, familyToday;
  final DateTime fetchedAt;
  final List<Map<String, dynamic>> items;
  final bool offline;

  factory ScheduleSnapshot.fromJson(
    Map<String, dynamic> data,
    String child, {
    bool offline = false,
  }) {
    if (data['schema'] != 1 ||
        data['child_id'] != child ||
        data['family_id'] is! String ||
        (data['family_id'] as String).isEmpty) {
      throw const FormatException('计划范围不匹配');
    }
    final ids = <String>{};
    final rows = (data['items'] as List).map((item) {
      final row = (item as Map).cast<String, dynamic>();
      if (row['child_id'] != child ||
          row['id'] is! String ||
          !ids.add(row['id'] as String)) {
        throw const FormatException('模板范围不正确或重复');
      }
      return row;
    }).toList();
    return ScheduleSnapshot(
      childId: child,
      familyId: data['family_id'] as String,
      fetchedAt: DateTime.parse(data['fetched_at'] as String),
      familyToday: data['family_today'] as String,
      items: List.unmodifiable(rows),
      offline: offline,
    );
  }
}

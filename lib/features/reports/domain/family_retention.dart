class FamilyRetentionDay {
  FamilyRetentionDay.fromJson(Map<String, dynamic> row)
    : offset = row['offset'] as int,
      date = row['date'] as String?,
      mature = row['mature'] as bool,
      status = row['status'] as String {
    if (![1, 7].contains(offset) ||
        !const {
          'no_task',
          'historical_unknown',
          'collection_unknown',
          'pending',
          'collecting',
          'returned',
          'not_observed',
        }.contains(status) ||
        (date == null) != (status == 'no_task') ||
        (status == 'not_observed' && !mature) ||
        (const {'pending', 'collecting', 'no_task'}.contains(status) &&
            mature)) {
      throw const FormatException('家庭回访记录无效');
    }
  }
  final int offset;
  final String? date;
  final bool mature;
  final String status;
  String get label => switch (status) {
    'no_task' => '尚未创建任务',
    'historical_unknown' => '历史记录不足',
    'collection_unknown' => '起点缺少活跃采集',
    'pending' => '尚未到观察日',
    'collecting' => '观察及离线补传中',
    'returned' => '已记录回访',
    _ => '未记录到回访',
  };
}

class FamilyRetention {
  FamilyRetention.fromJson(Map<String, dynamic> row)
    : familyId = row['family_id'] as String,
      cohortDate = row['cohort_date'] as String?,
      timezone = row['timezone'] as String?,
      days = (row['days'] as List)
          .map(
            (d) => FamilyRetentionDay.fromJson(
              Map<String, dynamic>.from(d as Map),
            ),
          )
          .toList() {
    if (row['version'] != 'retention-v1' ||
        !const {'observed', 'legacy'}.contains(row['anchor_source']) ||
        days.length != 2 ||
        days[0].offset != 1 ||
        days[1].offset != 7 ||
        (cohortDate == null) != (timezone == null)) {
      throw const FormatException('家庭回访统计无效');
    }
    for (final day in days) {
      if (cohortDate == null) {
        if (day.date != null) throw const FormatException('家庭回访日期无效');
      } else {
        final cohort = DateTime.tryParse('${cohortDate}T00:00:00Z');
        if (cohort == null ||
            cohort.toIso8601String().substring(0, 10) != cohortDate ||
            cohort
                    .add(Duration(days: day.offset))
                    .toIso8601String()
                    .substring(0, 10) !=
                day.date) {
          throw const FormatException('家庭回访日期无效');
        }
      }
    }
  }
  final String familyId;
  final String? cohortDate, timezone;
  final List<FamilyRetentionDay> days;
}

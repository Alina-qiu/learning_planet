enum ParentMessageKind { redemption, weekly }

class ParentNotificationSettings {
  const ParentNotificationSettings({
    this.enabled = false,
    this.redemptions = true,
    this.syncErrors = true,
    this.weeklyReports = true,
    this.quietStart = '21:00',
    this.quietEnd = '07:00',
    this.version = 0,
  });
  final bool enabled, redemptions, syncErrors, weeklyReports;
  final String quietStart, quietEnd;
  final int version;
  factory ParentNotificationSettings.fromJson(Map<String, dynamic> row) =>
      ParentNotificationSettings(
        enabled: row['enabled'] as bool,
        redemptions: row['redemptions'] as bool,
        syncErrors: row['sync_errors'] as bool,
        weeklyReports: row['weekly_reports'] as bool,
        quietStart: (row['quiet_start'] as String).substring(0, 5),
        quietEnd: (row['quiet_end'] as String).substring(0, 5),
        version: row['version'] as int,
      );
  Map<String, dynamic> toConfig() {
    final pattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
    if (!pattern.hasMatch(quietStart) || !pattern.hasMatch(quietEnd)) {
      throw const FormatException('安静时段请使用 HH:mm');
    }
    return {
      'enabled': enabled,
      'redemptions': redemptions,
      'sync_errors': syncErrors,
      'weekly_reports': weeklyReports,
      'quiet_start': quietStart,
      'quiet_end': quietEnd,
    };
  }
}

class ParentMessage {
  ParentMessage.fromJson(Map<String, dynamic> row)
    : key = row['notification_key'] as String,
      childId = row['child_id'] as String,
      kind = ParentMessageKind.values.byName(row['kind'] as String),
      createdAt = DateTime.parse(row['created_at'] as String),
      anchorDate = row['anchor_date'] as String?,
      readAt = row['read_at'] == null
          ? null
          : DateTime.parse(row['read_at'] as String) {
    if (kind == ParentMessageKind.weekly &&
        (anchorDate == null ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(anchorDate!))) {
      throw const FormatException('周报日期缺失');
    }
  }
  final String key, childId;
  final ParentMessageKind kind;
  final DateTime createdAt;
  final String? anchorDate;
  final DateTime? readAt;
  String get title =>
      kind == ParentMessageKind.redemption ? '有兑换申请待审批' : '上周学习周报可以查看了';
  String get detail => kind == ParentMessageKind.redemption
      ? '打开兑换记录核对申请；标为已读不会审批或扣款。'
      : '截至 $anchorDate 的完整七天，可查看任务、复习和成长记录。';
}

class ParentInbox {
  ParentInbox.fromJson(Map<String, dynamic> row)
    : familyId = row['family_id'] as String,
      timezone = row['timezone'] as String,
      settings = ParentNotificationSettings.fromJson(
        Map<String, dynamic>.from(row['settings'] as Map),
      ),
      items = List.unmodifiable(
        (row['items'] as List).map(
          (e) => ParentMessage.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
  final String familyId, timezone;
  final ParentNotificationSettings settings;
  final List<ParentMessage> items;
  int get unread => items.where((item) => item.readAt == null).length;
}

class ParentDelivery {
  ParentDelivery.fromJson(Map<String, dynamic> row)
    : offlinePolicy = row['offline_policy'] == null
          ? null
          : Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(row['offline_policy'] as Map),
            ),
      familyId = row['family_id'] as String,
      quiet = row['quiet'] as bool,
      settings = ParentNotificationSettings.fromJson(
        Map<String, dynamic>.from(row['settings'] as Map),
      ),
      items = List.unmodifiable(
        (row['items'] as List).map(
          (e) => ParentMessage.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
  final String familyId;
  final bool quiet;
  final Map<String, dynamic>? offlinePolicy;
  final ParentNotificationSettings settings;
  final List<ParentMessage> items;
}

class ParentSyncIssue {
  const ParentSyncIssue(
    this.childId, {
    required this.taskFailures,
    required this.conflicts,
    required this.images,
  });
  final String childId;
  final int taskFailures, conflicts, images;
  bool get needsAttention => taskFailures > 0 || conflicts > 0 || images > 0;
  String get summary => '待重试操作 $taskFailures · 冲突任务 $conflicts · 待处理图片 $images';
}

class ReviewReminder {
  const ReviewReminder({
    required this.revision,
    required this.enabled,
    required this.allowed,
    this.at,
    this.local,
  });
  factory ReviewReminder.fromJson(Map<String, dynamic> row) {
    final revision = row['revision'];
    if (revision is! int ||
        revision < 0 ||
        revision > 9007199254740991 ||
        row['enabled'] is! bool ||
        row['allowed'] is! bool ||
        (row['remind_local'] != null && row['remind_local'] is! String)) {
      throw const FormatException('复习提醒状态无效，请刷新');
    }
    final raw = row['remind_at'];
    final at = raw is String ? DateTime.tryParse(raw) : null;
    if (raw != null && at == null) throw const FormatException('复习提醒时间无效');
    return ReviewReminder(
      revision: revision,
      enabled: row['enabled'] as bool,
      allowed: row['allowed'] as bool,
      at: at,
      local: row['remind_local'] as String?,
    );
  }
  final int revision;
  final bool enabled, allowed;
  final DateTime? at;
  final String? local;
}

import 'package:timezone/timezone.dart' as tz;

/// Missing policies in a pre-047 cache must be refreshed, never guessed.
Map<String, Object> taskAlarmPayload(int id, Map<String, dynamic> reminder) {
  final policy = reminder['delivery_policy'];
  final at = DateTime.tryParse(reminder['remind_at'] as String? ?? '');
  final time = RegExp(r'^([01]\d|2[0-3]):[0-5]\d:[0-5]\d$');
  if (policy is! Map ||
      policy['version'] != 'task-reminder-v1' ||
      policy['timezone'] is! String ||
      at == null ||
      !time.hasMatch(policy['quiet_start'] as String? ?? '') ||
      !time.hasMatch(policy['quiet_end'] as String? ?? '')) {
    throw StateError('提醒策略需要更新，请联网刷新');
  }
  // PostgreSQL and older clients use UTC; timezone 0.11.1 uses Etc/UTC.
  final zone = policy['timezone'] == 'UTC'
      ? 'Etc/UTC'
      : policy['timezone'] as String;
  tz.getLocation(zone);
  return {
    'id': id,
    'at': at.millisecondsSinceEpoch,
    'timezone': zone,
    'quiet_start': policy['quiet_start'] as String,
    'quiet_end': policy['quiet_end'] as String,
  };
}

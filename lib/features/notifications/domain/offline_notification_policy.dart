import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'parent_notification.dart';

bool _zonesInitialized = false;
DateTime _instant(Object? value) {
  if (value is! String) throw const FormatException('提醒时间格式无效');
  final result = DateTime.tryParse(value);
  if (result == null || !result.isUtc) throw const FormatException('提醒时间缺少时区');
  return result;
}

/// Only a server-confirmed, bounded policy may be used when transport is down.
/// It contains no message bodies or read/delivery receipts.
class OfflineNotificationPolicy {
  OfflineNotificationPolicy.fromJson(Map<String, dynamic> row)
    : familyId = row['family_id'] as String,
      timezone = row['timezone'] as String,
      issuedAt = _instant(row['issued_at']),
      expiresAt = _instant(row['expires_at']),
      settings = ParentNotificationSettings.fromJson(
        Map<String, dynamic>.from(row['settings'] as Map),
      ),
      childIds = Set<String>.unmodifiable(
        (row['child_ids'] as List).cast<String>(),
      ) {
    if (row['schema'] != 1 ||
        row['purpose'] != 'local_sync_notice' ||
        familyId.isEmpty ||
        childIds.length != (row['child_ids'] as List).length ||
        childIds.any((id) => id.isEmpty) ||
        !expiresAt.isAfter(issuedAt) ||
        expiresAt.difference(issuedAt) > const Duration(days: 7) ||
        settings.version < 0) {
      throw const FormatException('离线提醒策略无效');
    }
    final times = row['settings'] as Map;
    final pattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d(:00)?$');
    if (!pattern.hasMatch(times['quiet_start'] as String) ||
        !pattern.hasMatch(times['quiet_end'] as String)) {
      throw const FormatException('安静时段无效');
    }
    settings.toConfig();
    if (!_zonesInitialized) {
      tzdata.initializeTimeZones();
      _zonesInitialized = true;
    }
    location = tz.getLocation(timezone);
  }
  final String familyId, timezone;
  final DateTime issuedAt, expiresAt;
  final ParentNotificationSettings settings;
  final Set<String> childIds;
  late final tz.Location location;
  bool quietAt(DateTime instant) {
    final local = tz.TZDateTime.from(instant, location);
    int minute(String value) =>
        int.parse(value.substring(0, 2)) * 60 +
        int.parse(value.substring(3, 5));
    final start = minute(settings.quietStart),
        end = minute(settings.quietEnd),
        now = local.hour * 60 + local.minute;
    return start == end
        ? false
        : start < end
        ? now >= start && now < end
        : now >= start || now < end;
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'purpose': 'local_sync_notice',
    'family_id': familyId,
    'timezone': timezone,
    'settings': {...settings.toConfig(), 'version': settings.version},
    'child_ids': childIds.toList(),
    'issued_at': issuedAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
  };
}

class CachedNotificationPolicy {
  CachedNotificationPolicy({
    required this.policy,
    required this.requestStartedAt,
    required this.receivedAt,
    DateTime? observedAt,
  }) : observedAt = observedAt ?? receivedAt {
    final duration = receivedAt.difference(requestStartedAt);
    if (duration.isNegative ||
        duration > const Duration(seconds: 30) ||
        this.observedAt.isBefore(receivedAt)) {
      throw const FormatException('提醒校时窗口无效');
    }
  }
  factory CachedNotificationPolicy.fromJson(Map<String, dynamic> row) =>
      CachedNotificationPolicy(
        policy: OfflineNotificationPolicy.fromJson(
          Map<String, dynamic>.from(row['policy'] as Map),
        ),
        requestStartedAt: _instant(row['request_started_at']),
        receivedAt: _instant(row['received_at']),
        observedAt: _instant(row['observed_at']),
      );
  final OfflineNotificationPolicy policy;
  final DateTime requestStartedAt, receivedAt, observedAt;

  /// Use both ends of the server-time uncertainty window. A slow request must
  /// not move a notification across a quiet boundary or extend the expiry.
  bool validAt(DateTime deviceNow) =>
      !deviceNow.isBefore(observedAt) &&
      !deviceNow.isBefore(receivedAt) &&
      latestAt(deviceNow).isBefore(policy.expiresAt);
  DateTime earliestAt(DateTime deviceNow) =>
      policy.issuedAt.add(deviceNow.difference(receivedAt));
  DateTime latestAt(DateTime deviceNow) =>
      policy.issuedAt.add(deviceNow.difference(requestStartedAt));
  bool allowsSync(String family, String child, DateTime deviceNow) =>
      validAt(deviceNow) &&
      policy.familyId == family &&
      policy.childIds.contains(child) &&
      policy.settings.enabled &&
      policy.settings.syncErrors &&
      !policy.quietAt(earliestAt(deviceNow)) &&
      !policy.quietAt(latestAt(deviceNow));
  Map<String, dynamic> toJson({DateTime? observed}) => {
    'policy': policy.toJson(),
    'request_started_at': requestStartedAt.toUtc().toIso8601String(),
    'received_at': receivedAt.toUtc().toIso8601String(),
    'observed_at': (observed ?? observedAt).toUtc().toIso8601String(),
  };
}

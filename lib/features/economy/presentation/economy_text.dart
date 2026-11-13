import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

String economySourceLabel(Object? source) =>
    const {
      'task_completion': '任务完成奖励',
      'plan_stage': '计划阶段奖励',
      'plan_completion': '计划结束奖励',
      'streak': '连续学习奖励',
      'learning_event': '学习表现奖励',
      'parent_adjustment': '家长调账',
      'coin_approval': '超额金币确认发放',
      'redemption_freeze': '兑换申请冻结',
      'redemption_spend': '兑换已兑现',
      'redemption_refund': '兑换退款',
    }[source] ??
    '其他记录';

String signedAmount(int value) => value > 0 ? '+$value' : '$value';
String ledgerChangeLabel(Map<String, dynamic> row) {
  final amount = (row['amount'] as num).toInt();
  if (row['asset_type'] == 'xp') return 'XP ${signedAmount(amount)}';
  final frozen = (row['frozen_delta'] as num?)?.toInt() ?? 0;
  return '${amount == 0 ? '可用金币不变' : '可用金币 ${signedAmount(amount)}'}'
      '${frozen == 0 ? '' : ' · 冻结 ${signedAmount(frozen)}'}';
}

bool _zonesReady = false;

class EconomyTime {
  EconomyTime(String? zone) {
    if (zone == null) return;
    if (!_zonesReady) {
      tzdata.initializeTimeZones();
      _zonesReady = true;
    }
    try {
      _location = tz.getLocation(zone);
    } on tz.LocationNotFoundException {
      /* Older cached data may not have a supported zone. */
    }
  }
  tz.Location? _location;
  String get label => _location == null ? '本机时间' : '家庭时间（${_location!.name}）';
  String format(Object? value, {String empty = '未记录'}) {
    if (value == null) return empty;
    if (value is! String) return '未记录';
    final date = DateTime.tryParse(value);
    if (date == null) return '未记录';
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return value;
    return DateFormat('yyyy-MM-dd HH:mm').format(
      _location == null ? date.toLocal() : tz.TZDateTime.from(date, _location!),
    );
  }
}

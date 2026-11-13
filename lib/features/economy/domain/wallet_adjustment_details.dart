class WalletAdjustmentDetails {
  WalletAdjustmentDetails._(this.entry, this.audit, this.timezone);
  final Map<String, dynamic> entry;
  final Map<String, dynamic>? audit;
  final String timezone;
  factory WalletAdjustmentDetails.fromJson(
    Map<String, dynamic> data, {
    required String owner,
    required String child,
    required String family,
    required String entryId,
  }) {
    final entry = data['entry'], audit = data['audit'];
    if (data['owner_id'] != owner ||
        data['child_id'] != child ||
        data['family_id'] != family ||
        data['family_timezone'] is! String ||
        entry is! Map ||
        entry['id'] != entryId ||
        entry['child_id'] != child ||
        entry['source_type'] != 'parent_adjustment' ||
        !['coin', 'xp'].contains(entry['asset_type']) ||
        entry['amount'] is! int ||
        entry['created_at'] is! String ||
        DateTime.tryParse(entry['created_at'] as String) == null) {
      throw const FormatException('调账记录范围或格式不正确');
    }
    if (audit != null) {
      if (audit is! Map ||
          audit['coins'] is! int ||
          audit['xp'] is! int ||
          audit[entry['asset_type'] == 'coin' ? 'coins' : 'xp'] !=
              entry['amount'] ||
          audit['reason'] is! String ||
          (audit['reason'] as String).length > 500 ||
          audit['created_at'] is! String ||
          DateTime.tryParse(audit['created_at'] as String) == null ||
          audit['actor'] is! Map ||
          audit['actor']['is_self'] is! bool ||
          ![
            'member',
            'former_member',
            'unavailable',
          ].contains(audit['actor']['status']) ||
          audit['actor']['email'] != null &&
              audit['actor']['email'] is! String) {
        throw const FormatException('调账说明格式不正确');
      }
    }
    return WalletAdjustmentDetails._(
      Map<String, dynamic>.from(entry),
      audit == null ? null : Map<String, dynamic>.from(audit as Map),
      data['family_timezone'] as String,
    );
  }
}

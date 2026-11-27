class EconomyPage {
  EconomyPage({
    required this.items,
    required this.nextCursor,
    required this.familyToday,
    this.fetchedAt,
    this.familyTimezone,
  });
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic>? nextCursor;
  final String familyToday;
  final String? fetchedAt;
  final String? familyTimezone;
  factory EconomyPage.fromJson(
    Map<String, dynamic> data, {
    required String owner,
    required String child,
    required String family,
    required String section,
    required bool includeInactive,
    Map<String, dynamic>? after,
  }) {
    if (data['owner_id'] != owner ||
        data['child_id'] != child ||
        data['family_id'] != family ||
        data['section'] != section ||
        data['include_inactive'] != includeInactive ||
        data['family_today'] is! String ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}$',
        ).hasMatch(data['family_today'] as String) ||
        DateTime.tryParse(
              data['family_today'] as String,
            )?.toIso8601String().substring(0, 10) !=
            data['family_today'] ||
        data['items'] is! List ||
        (data['items'] as List).length > 50) {
      throw const FormatException('列表范围或格式已变化，请刷新');
    }
    final rows = (data['items'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final ids = <String>{};
    Map<String, dynamic>? previous = after;
    for (final row in rows) {
      final id = row['id'], timestamp = row['created_at'];
      if (id is! String ||
          id.isEmpty ||
          !ids.add(id) ||
          timestamp is! String ||
          DateTime.tryParse(timestamp) == null) {
        throw const FormatException('列表记录不完整');
      }
      if (section == 'rewards'
          ? row['family_id'] != family
          : row['child_id'] != child) {
        throw const FormatException('列表记录归属不匹配');
      }
      if (previous != null) {
        final comparison = DateTime.parse(
          timestamp,
        ).compareTo(DateTime.parse(previous['created_at'] as String));
        if (comparison > 0 ||
            comparison == 0 && id.compareTo(previous['id'] as String) >= 0) {
          throw const FormatException('列表分页未前进，请刷新');
        }
      }
      previous = row;
    }
    final cursor = (data['next_cursor'] as Map?)?.cast<String, dynamic>();
    if (cursor != null &&
        (rows.isEmpty ||
            cursor['id'] != rows.last['id'] ||
            cursor['created_at'] != rows.last['created_at'])) {
      throw const FormatException('列表分页位置不正确');
    }
    return EconomyPage(
      items: List.unmodifiable(rows),
      nextCursor: cursor == null ? null : Map.unmodifiable(cursor),
      familyToday: data['family_today'] as String,
      fetchedAt: data['fetched_at'] as String?,
      familyTimezone: data['family_timezone'] as String?,
    );
  }
}

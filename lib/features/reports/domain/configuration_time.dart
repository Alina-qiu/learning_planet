class ConfigurationTime {
  ConfigurationTime.fromJson(Map<String, dynamic> row)
    : familyId = row['family_id'] as String,
      milliseconds = _count(row['milliseconds']),
      samples = _count(row['samples']),
      parents = _count(row['parents']),
      retainedFrom = DateTime.parse(row['retained_from'] as String),
      partialWindow = row['partial_window'] as bool {
    if (row['version'] != 'configuration-v1' ||
        parents > samples ||
        (samples == 0) != (parents == 0) ||
        milliseconds > samples * 30000 ||
        (samples == 0 && milliseconds != 0)) {
      throw const FormatException('配置用时统计不一致');
    }
  }
  final String familyId;
  final int milliseconds, samples, parents;
  final DateTime retainedFrom;
  final bool partialWindow;
  String get label {
    if (samples == 0) return '暂无配置计时记录';
    if (milliseconds < 1000) return '已记录不足1秒';
    final seconds = milliseconds ~/ 1000;
    return '已记录${seconds ~/ 60}分${seconds % 60}秒';
  }

  static int _count(Object? value) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value != value.round()) {
      throw const FormatException('配置用时数量无效');
    }
    return value.toInt();
  }
}
